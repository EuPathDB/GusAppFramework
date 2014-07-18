package GUS::Supported::Plugin::InsertOntologyTermsAndRelationships;

@ISA = qw(GUS::PluginMgr::Plugin);

# ----------------------------------------------------------------------

use strict;

use GUS::PluginMgr::Plugin;
use GUS::PluginMgr::PluginUtilities;

use UNIVERSAL qw(isa);

use FileHandle;

use GUS::Model::SRes::OntologyTerm;
use GUS::Model::SRes::OntologyRelationship;

use Data::Dumper;

my $argsDeclaration =
[

 fileArg({name           => 'inFile',
	  descr          => 'A file of Representing Ontology Terms and Relationships.  Currently owl format is Supported.',
	  reqd           => 1,
	  mustExist      => 1,
	  format         => 'rdf statements',
	  constraintFunc => undef,
	  isList         => 0, 
	 }),


 stringArg({ descr => 'Name of the External Database',
	     name  => 'extDbRlsSpec',
	     isList    => 0,
	     reqd  => 1,
	     constraintFunc => undef,
	   }),

 stringArg({ descr => '',
	     name  => 'relTypeExtDbRlsSpec',
	     isList    => 0,
	     reqd  => 1,
	     constraintFunc => undef,
	   }),

];

my $purpose = <<PURPOSE;
The purpose of this plugin is to parse a an owl file (rdf; list of ontology statements) and load as Ontology Terms and Relationships.  
PURPOSE

my $purposeBrief = <<PURPOSE_BRIEF;
The purpose of this plugin is to load Ontology Terms and Relationships.
PURPOSE_BRIEF

my $notes = <<NOTES;
Only load subclassOf relations
NOTES

my $tablesAffected = <<TABLES_AFFECTED;
SRes::OntologyTerm, SRes::OntologyRelationship
TABLES_AFFECTED

my $tablesDependedOn = <<TABLES_DEPENDED_ON;
SRes.OntologyTermType, SRes::OntologyRelationShipType
TABLES_DEPENDED_ON

my $howToRestart = <<RESTART;
No Restart utilities for this plugin.
RESTART

my $failureCases = <<FAIL_CASES;
FAIL_CASES

my $documentation = { purpose          => $purpose,
		      purposeBrief     => $purposeBrief,
		      notes            => $notes,
		      tablesAffected   => $tablesAffected,
		      tablesDependedOn => $tablesDependedOn,
		      howToRestart     => $howToRestart,
		      failureCases     => $failureCases };

my $numRelationships = 0;

# ----------------------------------------------------------------------

sub new {
  my ($class) = @_;
  my $self = {};
  bless($self,$class);

  $self->initialize({ requiredDbVersion => 4.0,
		      cvsRevision       => '$Revision$',
		      name              => ref($self),
		      argsDeclaration   => $argsDeclaration,
		      documentation     => $documentation});

  return $self;
}

# ----------------------------------------------------------------------

sub getExtDbRls {$_[0]->{ext_db_rls_id}}
sub setExtDbRls {$_[0]->{ext_db_rls_id} = $_[1]}

# ----------------------------------------------------------------------

=head2 Subroutines

=over 4

=item C<run>

Main method which Reads in the Owl File,
Converts to SRes::OntologyTerm and SRes::OntologyRelationships

B<Return type:> 

 C<string> Descriptive statement of how many rows were entered

=cut

sub run {
  my ($self) = @_;

  my $file = $self->getArg('inFile');

  my $extDbRlsId = $self->getExtDbRlsId($self->getArg('extDbRlsSpec'));
  $self->setExtDbRls($extDbRlsId);

  # build classpath
  opendir(D, "$ENV{GUS_HOME}/lib/java") || $self->error("Can't open $ENV{GUS_HOME}/lib/java to find .jar files");
  my @jars;
  foreach my $file (readdir D){
    next if ($file !~ /\.jar$/);
    push(@jars, "$ENV{GUS_HOME}/lib/java/$file");
  }
  my $classpath = join(':', @jars);

  # This will create a file appending ".out" to the inFile 
  my $systemResult = system("java -classpath $classpath org.gusdb.gus.supported.OntologyVisitor $file");
  unless($systemResult / 256 == 0) {
    $self->error("Could not Parse OWL file $file");
  }

  my $systemResult = system("java -classpath $classpath org.gusdb.gus.supported.IsA_Axioms $file");
  unless($systemResult / 256 == 0) {
    $self->error("Could not Parse OWL file $file");
  }

  my $termLines = $self->readFile($file . "_terms.txt");
  my $relationshipLines = $self->readFile($file . "_isA.txt");

  my $relationshipTypes = $self->getRelationshipTypes();

  my $terms = $self->doTerms($termLines);
  $self->submitObjectList($terms);
  $self->log("Inserted ", scalar(@$terms), " SRes::OntologyTerms");

  my $relationships = $self->doRelationships($terms, $relationshipLines, $relationshipTypes);
  $self->submitObjectList($relationships);

  my $termCount = scalar(@$terms);
  my $relationshipCount = scalar(@$relationships);

  return "Inserted $termCount SRes::OntologyTerms and $relationshipCount SRes::OntologyRelationships";
}

#--------------------------------------------------------------------------------

=item C<readFile>

Opens the out file and reads ALL lines into an arrayref. (Chomps off the newline chars)

B<Parameters:>

 $fn(string): full path to the .out file

B<Return Type:> 

 C<ARRAYREF> Each element is a file line

=cut

sub readFile {
  my ($self, $fn) = @_;

  open(FILE, "< $fn") or $self->error("Could Not open file $fn for reading: $!");

  my @lines;

  while(<FILE>) {
    chomp;

    push(@lines, $_);
  }
  close(FILE);

  return \@lines;
}

#--------------------------------------------------------------------------------

=item C<doTerms>

Loops through an array ref.  Each element of the array is split into 6 elements
ID      Name    Definition      Synonyms        URI     is obsolete

B<Parameters:>

 $lines(ARRAYREF): list of the file lines
 $termTypes(HASHREF): hash linking the ontology term types to their ids

B<Return Type:> 

 C<[GUS::Model::SRes::OntologyTerm]> ArrayRef of SRes.OntologyTerms

=cut

sub doTerms {
  my ($self, $lines) = @_;

  my $extDbRlsId = $self->getExtDbRls();
  my @ontologyTerms;

  foreach my $line (@$lines) {
    my @a = split(/\t/, $line);
    my $sourceId = $a[0];
    my $name = $a[1];
    my $definition = $a[2];
    my $synonyms = $a[3];
    my $uri = $a[4];
    my $isObsolete = $a[5];

    next if($isObsolete eq 'true');

    my $ontologyTerm = GUS::Model::SRes::OntologyTerm->
      new({name => $name,
           source_id => $sourceId,
           external_database_release_id => $extDbRlsId,
           uri => $uri,
           definition => $definition,
          });

    push(@ontologyTerms, $ontologyTerm);
  }

  return \@ontologyTerms;
}



#--------------------------------------------------------------------------------

=item C<doRelationships>

Loop through all the file lines and create the relationships. 

B<Parameters:>

 $terms([GUS::Model::SRes::OntologyTerm]) ArrayRef of Official Terms with definitions
 $lines(ARRAYREF): list of the relationship file lines
 $relationshipTypes(HASHREF): hash linking the ontology relationship types to their ids

B<Return Type:> 

 C<[GUS::Model::SRes::OntologyRelationship]>  ArrayRef of OntologyRelationships

=cut

sub doRelationships {
  my ($self, $terms, $lines, $relationshipTypes) = @_;

  my @relationships;
  my $count = 0;

  foreach my $line (@$lines) {
    my ($subject, $type, $object) = split(/\t/, $line);

    my $subjectTermId = $self->getTermIdFromName($terms, $subject);
    my $objectTermId = $self->getTermIdFromName($terms, $object);

    my $relationshipTypeId = $relationshipTypes->{$type};
    unless($relationshipTypeId) {
      $self->error("OntologyRelationshipType is Required at line: $line");
    }

    my $relationship = GUS::Model::SRes::OntologyRelationship->
      new({subject_term_id => $subjectTermId,
           object_term_id => $objectTermId,
           ontology_relationship_type_id => $relationshipTypeId,
          });

    push(@relationships, $relationship);

    $count++;
    if($count % 250 == 0) {
      $self->log("Inserted $count SRes::OntologyRelationships");
    }
  }

  return \@relationships;
}

#--------------------------------------------------------------------------------

=item C<getTermIdFromName>

Helper method which loops through an array of SRes::OntologyTerms and returns its id (undef if not found)

B<Parameters:>

 $terms([GUS::Model::SRes::OntologyTerm]) ArrayRef of Official Terms with definitions
 $wantedName(scalar): Term that you want

B<Return Type:> 

 C<scalar>  SRes::ontologyTerm ID

=cut

sub getTermIdFromName {
  my ($self, $terms, $wantedName) = @_;

  my $termId;

  foreach my $term (@$terms) {
    my $termName = $term->getName();

    if($termName eq $wantedName) {
      $termId = $term->getId();
    }
  }

  return $termId;
}



#--------------------------------------------------------------------------------

=item C<getRelationshipTypes>

Prepare and Execute an sql statment.  The key is the first value in the 
result, the value is the second value in the result;

B<Parameters:>

 $sql(scalar): Any sql statment can be used... Here used to map ontology[term|relationship] types to their ids

B<Return Type:> 

 C<HASHREF> 

=cut

sub getRelationshipTypes {
  my ($self, $sql) = @_;

  my %rv;

  my $extDbRlsId = $self->getExtDbRlsId($self->getArg('relTypeExtDbRlsSpec'));

  my $sql = "select name, ontology_term_id from SRes.ONTOLOGYTERM where external_database_release_id = $extDbRlsId";
  my $sh = $self->getQueryHandle()->prepare($sql);
  $sh->execute();

  while(my ($name, $id) = $sh->fetchrow_array()) {
    $rv{$name} = $id;
  }
  $sh->finish();

  return \%rv;
}

#--------------------------------------------------------------------------------

sub submitObjectList {
  my ($self, $list) = @_;

  foreach my $gusObj (@$list) {
    $gusObj->submit();
  }
}

#--------------------------------------------------------------------------------

sub undoTables {
  my ($self) = @_;

  return ('SRes.OntologyRelationship','SRes.OntologyTerm');
}

1;
