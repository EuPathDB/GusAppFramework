package GUS::Supported::Plugin::CalculateTranslatedAASequences;

use strict;

use GUS::PluginMgr::Plugin;
use base qw(GUS::PluginMgr::Plugin);

use Bio::Tools::CodonTable;

use  GUS::Model::DoTS::TranslatedAASequence;

use GUS::Model::DoTS::NAFeature;

my $argsDeclaration =
  [

   stringArg({ name => 'extDbRlsName',
	       descr => 'External Database Release name of the transcripts to be translated',
	       constraintFunc => undef,
	       isList => 0,
	       reqd => 1,
	     }),

   stringArg({ name => 'extDbRlsVer',
	       descr => 'External Database Release version of the transcripts to be translated',
	       constraintFunc => undef,
	       isList => 0,
	       reqd => 1,
	     }),

   booleanArg({ name => 'overwrite',
		descr => 'whether to overwrite an existing translation or not; defaults to false',
		reqd => 0,
		default => 0,
	      }),

  ];


my $purposeBrief = <<PURPOSEBRIEF;
Calculates amino acid translations of CDS-defining transcripts.
PURPOSEBRIEF

my $purpose = <<PLUGIN_PURPOSE;
Calculates amino acid translations of CDS-defining transcripts.
PLUGIN_PURPOSE

my $tablesAffected =
  [
   ['DoTS.TranslatedAASequence' =>
    'Translations are deposited in the `sequence` field of DoTS.TranslatedAASequence'
   ]
  ];

my $tablesDependedOn = [];

my $howToRestart = <<PLUGIN_RESTART;
This plugin can be restarted, but unless --overwrite is set, previously calculated translations will not be overwritten.
PLUGIN_RESTART

my $failureCases = <<PLUGIN_FAILURE_CASES;
No known failure cases.
PLUGIN_FAILURE_CASES

my $notes = <<PLUGIN_NOTES;
No additional notes.
PLUGIN_NOTES

my $documentation = { purposeBrief => $purposeBrief,
		      purpose => $purpose,
		      tablesAffected => $tablesAffected,
		      tablesDependedOn => $tablesDependedOn,
		      howToRestart => $howToRestart,
		      failureCases => $failureCases,
		      notes => $notes,
		    };

sub new {

  my $class = shift;
  $class = ref $class || $class;
  my $self = {};

  bless $self, $class;

  $self->initialize({ requiredDbVersion => 3.5,
		      cvsRevision =>  '$Revision$',
		      name => ref($self),
		      argsDeclaration   => $argsDeclaration,
		      documentation     => $documentation
		    });
  return $self;
}

sub run {

  my ($self) = @_;

  my $extDbRlsName = $self->getArg("extDbRlsName");
  my $extDbRlsVer = $self->getArg("extDbRlsVer");

  my $extDbRlsId = $self->getExtDbRlsId($extDbRlsName, $extDbRlsVer);

  unless ($extDbRlsId) {
    die "No such External Database Release / Version:\n $extDbRlsName / $extDbRlsVer\n";
  }

  my $codonTable = Bio::Tools::CodonTable->new();

  my $dbh = $self->getQueryHandle();
  my $sql = <<EOSQL;
  SELECT aa_sequence_id
  FROM   DoTS.TranslatedAASequence
  WHERE  external_database_release_id = ?
EOSQL
  print STDERR "That SQL= $sql\n";
  my $sth = $dbh->prepare($sql);

  $sth->execute($extDbRlsId);

  unless ($sth->rows()) {
    warn "No TranslatedAASequences with the specified External Database Release\n";
  }

  while (my ($aaSeqId) = $sth->fetchrow()) {

    my $aaSeq = GUS::Model::DoTS::TranslatedAASequence->new({ aa_sequence_id => $aaSeqId });
    unless ($aaSeq->retrieveFromDB()) {
      die "Not sure what happened: $aaSeqId was supposed to fetch a TranslatedAASequence, but couldn't\n";
    }

    my @translatedAAFeats = $aaSeq->getChildren("DoTS::TranslatedAAFeature",
						1, 0,
						{ external_database_release_id => $extDbRlsId }
					       );
    if (@translatedAAFeats == 0) {
	warn "skipping TranslatedAASequence, source_id: " . $aaSeq->getSourceId() . "\n";
      next;
    } elsif (@translatedAAFeats > 1) {
      die "This situation not yet supported"
    }

    my $translatedAAFeat = shift @translatedAAFeats;

    my $transcript = $translatedAAFeat->getParent("DoTS::Transcript", 1);

    unless ($transcript) {
      die "TranslatedAAFeature had no parent Transcript: " . $translatedAAFeat->getSourceId() . "\n";
    }

    my $ntSeq = $transcript->getParent("DoTS::NASequence", 1);

    unless ($ntSeq) {
      die "Transcript had no associated NASequence: " . $transcript->getSourceId() . "\n";
    }

    my $taxon = $ntSeq->getParent("SRes::Taxon", 1);

    unless ($taxon) {
      die "NASequence was not associated with an organism in SRes.Taxon: " . $ntSeq->getSourceId() . "\n";
    }

    $codonTable->id($taxon->getGeneticCodeId() || 1);

    my @exons = $transcript->getChildren("DoTS::ExonFeature",
					 1, 0,
					 { external_database_release_id => $extDbRlsId }
					);

    unless (@exons) {
      die "Transcript had no exons: " . $transcript->getSourceId() . "\n";
    }

    @exons = sort { $a->getOrderNumber <=> $b->getOrderNumber } @exons;

    my $exceptions = $dbh->prepare(<<EOSQL);

  SELECT naf.na_feature_id, so.term_name
  FROM   DoTS.NAFeature naf,
         DoTS.NALocation nal,
         SRes.SequenceOntology so
  WHERE  naf.sequence_ontology_id = so.sequence_ontology_id
  AND    nal.na_feature_id = naf.na_feature_id
  AND    so.term_name in ('stop_codon_redefinition_as_selenocysteine',
		     'stop_codon_redefinition_as_pyrrolysine',
		     'plus_1_translational_frameshift',
		     'minus_1_translational_frameshift',
		     'four_bp_start_codon',
		     '4bp_start_codon',
		     'stop_codon_readthrough',
		     'CTG_start_codon'
		    )
  AND    nal.start_min BETWEEN ? AND ?
  AND    nal.is_reversed = ?
  AND    naf.na_sequence_id = ?
ORDER BY CASE WHEN nal.is_reversed = 1 THEN nal.end_max ELSE nal.start_min END

EOSQL

    my $cds;
    my $translation;

    my @exceptions;
    for my $exon (@exons) {
      my ($exonStart, $exonEnd, $exonIsReversed) = $exon->getFeatureLocation();

      my $codingStart = $exon->getCodingStart();
      my $codingEnd = $exon->getCodingEnd();

      next unless ($codingStart && $codingEnd);

      my $chunk = $exon->getFeatureSequence();

      $exceptions->execute($exonStart, $exonEnd, $exonIsReversed, $exon->getNaSequenceId());

      while (my ($exceptionId, $soTerm) = $exceptions->fetchrow()) {
	if ($soTerm eq "stop_codon_redefinition_as_selenocysteine") {
	  my $exception = GUS::Model::DoTS::NAFeature->new({ na_feature_id => $exceptionId });
	  $exception->retrieveFromDB();

	  my ($start, $end, $isReversed) = $exception->getFeatureLocation();
	  push @exceptions, [ length($cds) + 1 + $isReversed ? $codingStart - $end : $start - $codingStart,
			      length($cds) + 1 + $isReversed ? $codingStart - $start : $end - $codingStart,
			      "TGA", "U"
			    ];
	} else {
	  die "Sorry, translation expections for '$soTerm' not yet handled!\n";
        }
      }

      my $trim5 = $exonIsReversed ? $exonEnd - $codingStart : $codingStart - $exonStart;
      substr($chunk, 0, $trim5, "") if $trim5 > 0;  

      my $trim3 = $exonIsReversed ? $codingEnd - $exonStart : $exonEnd - $codingEnd;
      substr($chunk, -$trim3, $trim3, "") if $trim3 > 0;  

      $cds .= $chunk;
    }

    $translation = $codonTable->translate($cds);

    for (my $i = 0 ; $i < @exceptions ; $i++) {
      my ($start, $end, $codon, $residue) = @{$exceptions[$i]};
      warn "changing codon @{[substr($cds, $start, $end - $start)]} to $codon ($residue)\n";
      substr($cds, $start, $end - $start + 1, $codon);

      substr($translation, int(($start-1) / 3), 1, $residue);

      # adjust remaining coordinates, if necessary (e.g. 4 bp start codon)
      unless (length($codon) == ($end - $start + 1)) {
	my $delta = $end - $start + 1 - length($codon);
	for (my $j = $i+1 ; $j < @exceptions ; $j++) {
	  $exceptions[$i]->[0] += $delta;
	  $exceptions[$i]->[1] += $delta;
	}
      }
    }

    $translation =~ s/\*$//; # strip terminal stop codon, if present

    if ($translation =~ m/\*/ && !$transcript->getIsPseudo) {
      warn "Warning: translation for " . $transcript->getSourceId() . " contains stop codons:\n$translation\n";
    }
    
    $aaSeq->setSequence($translation);
    $aaSeq->submit();
    $self->undefPointerCache();
  }

  warn "Done.\n";
}

1;
