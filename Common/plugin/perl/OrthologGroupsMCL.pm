package GUS::Common::Plugin::OrthologGroupsMCL;

@ISA = qw(GUS::PluginMgr::Plugin);
use strict;
use DBI;
use FileHandle; 
use GUS::Model::DoTS::AAOrthologExperiment;
use GUS::Model::DoTS::AAOrthologGroup;
use GUS::Model::DoTS::AASequenceSequenceGroup;
# ----------------------------------------------------------------------
# create and initalize new plugin instance.

sub new {
  my ($class) = @_;

  my $self = {};
  bless($self, $class);

  my $usage = 'Load orthologous sequence groups generated by OrthoMCL algorithm.  ("// on newline delimits submits)';

  my $easycsp =
    
     [

     { h => 'file of indexing between martrix elements and sequence identifiers',
       t => 'string',
       o => 'index',
     },
     { h => 'file of the matrix generated by OrthoMCL',
       t => 'string',
       o => 'matrix',
     },
     { h => 'description of the parameters used in OrthoMCL',
       t => 'string',
       o => 'description',
     },
     { h => 'source of the relevant sequences',
       t => 'string',
       o => 'seqsource',
     },
     { h => 'algorithm_invocation_ids of smililarities',
       t => 'string',
       o => 'alginvoIds',
     },
     { h => 'cutoff P value (?e?)',
       t => 'string',
       o => 'pvalue',
       d => '1e-5',
     }, 
     { h => 'cutoff percent identity',
       t => 'float',
       o => 'percent_identity',
       d => 0,
     },
     { h => 'cutoff percent match length',
       t => 'float',
       o => 'percent_match',
       d => 0,
     }, 
    ];

  $self->initialize({requiredDbVersion => {},
		     cvsRevision => '$Revision$', # cvs fills this in!
		     name => ref($self),
		     revisionNotes => 'make consistent with GUS 3.0',
		     easyCspOptions => $easycsp,
		     usage => $usage
		 });

  return $self;
}

# ----------------------------------------------------------------------
# plugin-global variables.


# ----------------------------------------------------------------------
# run method to do the work

sub run {
    my $self = shift;
    my $RV;

    my $fh_index = FileHandle->new('<'.$self->getCla->{'index'});
    my $fh_matrix = FileHandle->new('<'.$self->getCla->{'matrix'});
    my $algInvoIds = $self->getCla->{'alginvoIds'};
    my $percent_identity = $self->getCla->{'percent_identity'} ? $self->getCla->{'percent_identity'} : 0;
    my $percent_match = $self->getCla->{'percent_match'} ? $self->getCla->{'percent_match'} : 0;
    my $pvalue = $self->getCla->{'pvalue'} ? $self->getCla->{'pvalue'} : '1e-5';
    my ($pvalue_mant, $pvalue_exp);
    if($pvalue == 0) { 
	$pvalue_mant = 0;
	$pvalue_exp = -999999;
    }else {
	($pvalue_mant, $pvalue_exp) = split('e', $pvalue);
    }
    if ($fh_index && $fh_matrix && $algInvoIds) {
	
	$self->logAlert('COMMIT', $self->getCla->{commit} ? 'ON' : 'OFF' );

	my $dbh = $self->getQueryHandle();
	my $sth = $dbh -> prepare("select similarity_id, pvalue_mant, pvalue_exp, number_identical/total_match_length from dots.similarity where query_table_id in (83,337) and subject_table_id in (83,337) and query_id=? and subject_id=? and row_alg_invocation_id in ($algInvoIds)");
	my $verifySth = $dbh->prepare("select external_database_release_id from dots.externalaasequence where aa_sequence_id = ?");    
############################################################
    # Put loop here...remember to undefPointerCache()!
    ############################################################
	
	my %id;
	while (<$fh_index>) {

	    if($_=~/^(\d+)\s+(\d+)/) {
		$id{$1}=$2;
	    }
	}
	$fh_index -> close;
#assign experiment id

	my $orthexp = GUS::Model::DoTS::AAOrthologExperiment->new();
	$orthexp->set('subclass_view','AAOrthologExperiment');
	$orthexp->set('description', $self->getCla->{'description'});
	$orthexp->set('sequence_source', $self->getCla->{'seqsource'});
	$orthexp->set('pvalue_mant', $pvalue_mant);
	$orthexp->set('pvalue_exp', $pvalue_exp);
	$orthexp->set('percent_identity',$percent_identity);
	$orthexp->set('percent_match', $percent_match);
	$orthexp->submit();
	my $expId = $orthexp->get('aa_seq_group_experiment_id');
	
	my $count;
	my %string;
	my $key;
	while(<$fh_matrix>) {
	    chomp;
	    next unless ($_ =~ /^[\d\s]/);
	    if($_ =~/^(\d+)\s+(.+)/) {
		$key = $1;
		$string{$key} = $2;
	    }
	    else{
		$string{$key} .= $_;
	    }
	}
	my $total = scalar (keys %string);
	print STDERR "have $total keys to process\n";
	my $counter = 0;
	my $processingPlasmo = 0;
	foreach my $g (keys %string) {
	    $processingPlasmo = 0;

	    $counter++;
	    print STDERR "processing $counter key value" if ($counter % 100 == 0);
	    $string{$g} =~s/\$//;
	    my @mem = split(/\s+/, $string{$g});
	    my $n = scalar(@mem);
	    my $orthgrp = GUS::Model::DoTS::AAOrthologGroup -> new();
	    $orthgrp -> set('subclass_view','AAOrthologGroup');
	    $orthgrp -> set('number_of_members',$n);
	    $orthgrp -> set('aa_seq_group_experiment_id',$expId);
	    foreach my $m (@mem) {
		my $mem = GUS::Model::DoTS::AASequenceSequenceGroup -> new();
		$mem->set('aa_sequence_id', $id{$m});
		$orthgrp -> addChild($mem);	
	    }
	    
	    my ($maxpv,$minpv,$maxpi,$minpi,$maxl,$minl);
	    $maxpv = 0;
	    $minpv = 1;
	    $maxpi = 0;
	    $minpi = 1;
	    $maxl = 0;
	    $minl = 100000;
	    for(my $i=0;$i<scalar(@mem)-1;$i++) {
		
		for(my $j=$i+1;$j<scalar(@mem);$j++) {
		    
		    $sth->execute($id{$mem[$i]}, $id{$mem[$j]});
		    if(my($s,$pm,$pe,$pi) = $sth->fetchrow_array()) {
			 if($pm.'e'.$pe >= $maxpv) { $maxpv = $pm.'e'.$pe;}
			 if($pm.'e'.$pe <= $minpv) { $minpv = $pm.'e'.$pe;}
			 if($pi>= $maxpi) { $maxpi = $pi; }
			 if($pi<= $minpi) { $minpi = $pi; }
			 my @lens = &simspan($dbh, $s,$id{$mem[$i]},$id{$mem[$j]});
			 foreach my $len (@lens) {
			     if($len >= $maxl) { $maxl = $len; }
			     if($len <= $minl) { $minl = $len; }
			 }
		     }
		    $sth->execute($id{$mem[$j]}, $id{$mem[$i]});
		    if(my($s,$pm,$pe,$pi) = $sth->fetchrow_array()) {
			if($pm.'e'.$pe >= $maxpv) { $maxpv = $pm.'e'.$pe;}
			if($pm.'e'.$pe <= $minpv) { $minpv = $pm.'e'.$pe;}
			if($pi>= $maxpi) { $maxpi = $pi; }
			if($pi<= $minpi) { $minpi = $pi; }
			my @lens = &simspan($dbh,$s,$id{$mem[$j]},$id{$mem[$i]});
			foreach my $len (@lens) {
			    if($len >= $maxl) { $maxl = $len; }
			    if($len <= $minl) { $minl = $len; }
			}
		    }
		}
	    }
	    $orthgrp -> set('max_match_identity', sprintf("%.1f",$maxpi));
	    $orthgrp -> set('min_match_identity', sprintf("%.1f",$minpi));
	    $orthgrp -> set('max_match_length',$maxl);
	    $orthgrp -> set('min_match_length',$minl);
	    my($m, $e) = split('e', $maxpv);
	    $orthgrp -> set('max_pvalue_mant',$m);
	    $orthgrp -> set('max_pvalue_exp',$e);
	    my($m, $e) = split('e', $minpv);
	    $orthgrp -> set('min_pvalue_mant',$m);
	    $orthgrp -> set('min_pvalue_exp',$e);
	    $orthgrp->submit(); 
	    $count++;
	    $self->getSelfInv->undefPointerCache();
	}
	$fh_matrix -> close;
	
	$RV = join(' ',
		   "processed $count ortholog groups, inserted",
		   $self->getSelfInv->getTotalInserts(),
		   'and updated',
		   $self->getSelfInv->getTotalUpdates() || 0,
		   );
    }
    
    # no file.
    else {
	$RV = join(' ',
		   'valid --index <filename> --matrix <filename> --alginvoIds <algorithm_invocation_ids for similarities> must be on the commandline',
		   $self->getCla->{filename},
		   $!);
    }
    
    $self->logAlert('RESULT', $RV);
    return $RV;
}

sub simspan {
    my ($dbh,$sim,$id,$sid) = @_;
    my (%sub_start, %sub_length, %query_start, %query_length);
    my $sthSpan =$dbh->prepare("select similarity_span_id,subject_start,subject_end,query_start,query_end from dots.SimilaritySpan where similarity_id=?");

#    my $sthLen = $dbh->prepare("select length from AASequence where aa_sequence_id=?");
    $sthSpan->execute($sim);
    while(my (@row) = $sthSpan -> fetchrow_array()) {
	$sub_start{$row[0]}=$row[1]; 
	$sub_length{$row[0]}=$row[2]-$row[1]+1;
	$query_start{$row[0]}=$row[3];
	$query_length{$row[0]}=$row[4]-$row[3]+1;
    }

    my $match_lengths = &matchlen(\%sub_start,\%sub_length);
    my $match_lengthq = &matchlen(\%query_start,\%query_length);			
    return ($match_lengths, $match_lengthq);
#    $sthLen->execute($sid);
#    my ($lengths) = $sthLen -> fetchrow_array();
#    $sthLen->execute($id);
#    my ($lengthq) = $sthLen -> fetchrow_array();
#    if($lengths >= $lengthq) {
#	return $match_lengthq/$lengthq;
#    }else{
#	return $match_lengths/$lengths;
#    }
}

sub matchlen {
    my ($s, $l)=@_;
    my %start= %$s; my %length = %$l;
    my @starts = sort{$start{$a}<=>$start{$b}} (keys %start);
    return $length{$starts[0]} if(scalar(@starts)==1);
    my $i=1; 
    my  $match_length = $length{$starts[0]}; 
    my $pos = $length{$starts[0]} + $start{$starts[0]} ;
    while($i<scalar(@starts)) {

	if($length{$starts[$i]} + $start{$starts[$i]} <= $pos) {
	    $i++;
	    next;
	}
	if($start{$starts[$i]}> $pos) {
	    $match_length += $length{$starts[$i]};
	    $pos = $start{$starts[$i]} + $length{$starts[$i]};
	}else {
	    $match_length += $length{$starts[$i]} - ($pos - $start{$starts[$i]});
	    $pos = $start{$starts[$i]} + $length{$starts[$i]};
	}
	$i++;
    }

    return $match_length;
}


 
