#!/usr/bin/env perl

####################################################################################################
#                                                                                                  #
# galba.pl                                                                                         #
# Pipeline for de novo gene prediction with AUGUSTUS using Miniprot or GenomeThreader              #
#                                                                                                  #
# Authors: Katharina Hoff, Natalia Nenasheva, Mario Stanke                                         #
#                                                                                                  #
# Contact: katharina.hoff@uni-greifswald.de                                                        #
#                                                                                                  #
#                                                                                                  #
# This script is under the Artistic Licence                                                        #
# (http://www.opensource.org/licenses/artistic-license.php)                                        #
#                                                                                                  #
####################################################################################################

use Getopt::Long;
use File::Compare;
use File::Copy;
use File::Path qw(make_path rmtree);
use Module::Load::Conditional qw(can_load check_install requires);
use Scalar::Util::Numeric qw(isint);
use POSIX qw(floor);
use List::Util qw[min max];
use Parallel::ForkManager;
use FindBin;
use lib "$FindBin::RealBin/.";
use File::Which;                    # exports which()
use File::Which qw(which where);    # exports which() and where()

use Cwd;
use Cwd 'abs_path';

use File::Spec::Functions qw(rel2abs);
use File::Basename qw(dirname basename);
use File::Copy;

use helpMod
    qw( find checkFile formatDetector relToAbs setParInConfig addParToConfig uptodate gtf2fasta clean_abort );
use Term::ANSIColor qw(:constants);

use strict;
use warnings;

my $usage = <<'ENDUSAGE';

DESCRIPTION

galba.pl   Pipeline for for de novo gene prediction with AUGUSTUS using Miniprot
           or GenomeThreader

SYNOPSIS

galba.pl [OPTIONS] --genome=genome.fa -prot_seq=prot.fa

INPUT FILE OPTIONS

--genome=genome.fa                  fasta file with DNA sequences
--prot_seq=prot.fa                  A protein sequence file in multi-fasta
                                    format used to generate protein hints.
                                    Unless otherwise specified, galba.pl will
                                    run in "EP mode" which uses ProtHint to
                                    generate protein hints and GeneMark-EP+ to
                                    train AUGUSTUS.
--hints=hints.gff                   Alternatively to calling galba.pl with a
                                    bam or protein fasta file, it is possible to
                                    call it with a .gff file that contains
                                    introns extracted from RNA-Seq and/or
                                    protein hints (most frequently coming
                                    from ProtHint). If you wish to use the
                                    ProtHint hints, use its
                                    "prothint_augustus.gff" output file.
                                    This flag also allows the usage of hints
                                    from additional extrinsic sources for gene
                                    prediction with AUGUSTUS. To consider such
                                    additional extrinsic information, you need
                                    to use the flag --extrinsicCfgFiles to
                                    specify parameters for all sources in the
                                    hints file (including the source "E" for
                                    intron hints from RNA-Seq)
--prot_aln=prot.aln                 Alignment file generated from aligning
                                    protein sequences against the genome with
                                    either Exonerate (--prg=exonerate), or
                                    Spaln (--prg=spaln), or GenomeThreader
                                    (--prg=gth). This option can be used as
                                    an alternative to --prot_seq file or protein
                                    hints in the --hints file.
                                    To prepare alignment file, run Spaln2 with
                                    the following command:
                                    spaln -O0 ... > spalnfile
                                    To prepare alignment file, run Exonerate
                                    with the following command:
                                    exonerate --model protein2genome \
                                        --showtargetgff T ... > exfile
                                    To prepare alignment file, run
                                    GenomeThreader with the following command:
                                    gth -genomic genome.fa  -protein \
                                        protein.fa -gff3out \
                                        -skipalignmentout ... -o gthfile
                                    A valid option prg=... must be specified
                                    in combination with --prot_aln. Generating
                                    tool will not be guessed.
                                    Currently, hints from protein alignment
                                    files are only used in the prediction step
                                    with AUGUSTUS.

FREQUENTLY USED OPTIONS

--species=sname                     Species name. Existing species will not be
                                    overwritten. Uses Sp_1 etc., if no species
                                    is assigned
--AUGUSTUS_ab_initio                output ab initio predictions by AUGUSTUS
                                    in addition to predictions with hints by
                                    AUGUSTUS
--softmasking                       Softmasking option for soft masked genome
                                    files. (Disabled by default.)
--gff3                              Output in GFF3 format (default is gtf
                                    format)
--cores                             Specifies the maximum number of cores that
                                    can be used during computation. Be aware:
                                    optimize_augustus.pl will use max. 8
                                    cores; augustus will use max. nContigs in
                                    --genome=file cores.
--workingdir=/path/to/wd/           Set path to working directory. In the
                                    working directory results and temporary
                                    files are stored
--nice                              Execute all system calls within galba.pl
                                    and its submodules with bash "nice"
                                    (default nice value)

--alternatives-from-evidence=true   Output alternative transcripts based on
                                    explicit evidence from hints (default is
                                    true).
--crf                               Execute CRF training for AUGUSTUS;
                                    resulting parameters are only kept for
                                    final predictions if they show higher
                                    accuracy than HMM parameters.
--keepCrf                           keep CRF parameters even if they are not
                                    better than HMM parameters

--prg=miniprot|gth                  Specify either gth (GenomeThreader) or 
                                    miniprot; default is miniprot.
--makehub                           Create track data hub with make_hub.py 
                                    for visualizing GALBA results with the
                                    UCSC GenomeBrowser
--email                             E-mail address for creating track data hub
--version                           Print version number of galba.pl
--help                              Print this help message

CONFIGURATION OPTIONS (TOOLS CALLED BY GALBA)

--AUGUSTUS_CONFIG_PATH=/path/       Set path to config directory of AUGUSTUS
                                    (if not specified as environment
                                    variable). GALBA1 will assume that the
                                    directories ../bin and ../scripts of
                                    AUGUSTUS are located relative to the
                                    AUGUSTUS_CONFIG_PATH. If this is not the
                                    case, please specify AUGUSTUS_BIN_PATH
                                    (and AUGUSTUS_SCRIPTS_PATH if required).
                                    The galba.pl commandline argument
                                    --AUGUSTUS_CONFIG_PATH has higher priority
                                    than the environment variable with the
                                    same name.
--AUGUSTUS_BIN_PATH=/path/          Set path to the AUGUSTUS directory that
                                    contains binaries, i.e. augustus and
                                    etraining. This variable must only be set
                                    if AUGUSTUS_CONFIG_PATH does not have
                                    ../bin and ../scripts of AUGUSTUS relative
                                     to its location i.e. for global AUGUSTUS
                                    installations. GALBA1 will assume that
                                    the directory ../scripts of AUGUSTUS is
                                    located relative to the AUGUSTUS_BIN_PATH.
                                    If this is not the case, please specify
                                    --AUGUSTUS_SCRIPTS_PATH.
--AUGUSTUS_SCRIPTS_PATH=/path/      Set path to AUGUSTUS directory that
                                    contains scripts, i.e. splitMfasta.pl.
                                    This variable must only be set if
                                    AUGUSTUS_CONFIG_PATH or AUGUSTUS_BIN_PATH
                                    do not contains the ../scripts directory
                                    of AUGUSTUS relative to their location,
                                    i.e. for special cases of a global
                                    AUGUSTUS installation.
--ALIGNMENT_TOOL_PATH=/path/to/tool Set path to alignment tool
                                    (Miniprot or GenomeThreader)
                                    if not specified as environment
                                    ALIGNMENT_TOOL_PATH variable. Has higher
                                    priority than environment variable.
--DIAMOND_PATH=/path/to/diamond     Set path to diamond, this is an alternative
                                    to NCIB blast; you only need to specify one 
                                    out of DIAMOND_PATH or BLAST_PATH, not both.
                                    DIAMOND is a lot faster that BLAST and yields 
                                    highly similar results for GALBA.
--PYTHON3_PATH=/path/to             Set path to python3 executable (if not 
                                    specified as envirnonment variable and if
                                    executable is not in your $PATH).
--MAKEHUB_PATH=/path/to             Set path to make_hub.py (if option --makehub
                                    is used).
--CDBTOOLS_PATH=/path/to            cdbfasta/cdbyank are required for running
                                    fix_in_frame_stop_codon_genes.py. Usage of
                                    that script can be skipped with option 
                                    '--skip_fixing_broken_genes'.


EXPERT OPTIONS

--augustus_args="--some_arg=bla"    One or several command line arguments to
                                    be passed to AUGUSTUS, if several
                                    arguments are given, separate them by
                                    whitespace, i.e.
                                    "--first_arg=sth --second_arg=sth".
--rounds                            The number of optimization rounds used in
                                    optimize_augustus.pl (default 5)
--skipAllTraining                   Skip GeneMark-EX (training and
                                    prediction), skip AUGUSTUS training, only
                                    runs AUGUSTUS with pre-trained and already
                                    existing parameters (not recommended).
                                    Hints from input are still generated.
                                    This option automatically sets
                                    --useexisting to true.
--filterOutShort                    It may happen that a "good" training gene,
                                    i.e. one that has intron support from
                                    RNA-Seq in all introns predicted by
                                    GeneMark-EX, is in fact too short. This flag
                                    will discard such genes that have
                                    supported introns and a neighboring
                                    RNA-Seq supported intron upstream of the
                                    start codon within the range of the
                                    maximum CDS size of that gene and with a
                                    multiplicity that is at least as high as
                                    20% of the average intron multiplicity of
                                    that gene.
--skipOptimize                      Skip optimize parameter step (not
                                    recommended).
--skipGetAnnoFromFasta              Skip calling the python3 script
                                    getAnnoFastaFromJoingenes.py from the
                                    AUGUSTUS tool suite. This script requires
                                    python3, biopython and re (regular 
                                    expressions) to be installed. It produces
                                    coding sequence and protein FASTA files 
                                    from AUGUSTUS gene predictions and provides
                                    information about genes with in-frame stop 
                                    codons. If you enable this flag, these files 
                                    will not be produced and python3 and 
                                    the required modules will not be necessary
                                    for running galba.pl.
--skip_fixing_broken_genes          If you do not have python3, you can choose
                                    to skip the fixing of stop codon including
                                    genes (not recommended).
--eval=reference.gtf                Reference set to evaluate predictions
                                    against (using evaluation scripts from GaTech)
--eval_pseudo=pseudo.gff3           File with pseudogenes that will be excluded 
                                    from accuracy evaluation (may be empty file)
--flanking_DNA=n                    Size of flanking region, must only be
                                    specified if --AUGUSTUS_hints_preds is given
                                    (for UTR training in a separate galba.pl 
                                    run that builds on top of an existing run)
--verbosity=n                       0 -> run galba.pl quiet (no log)
                                    1 -> only log warnings
                                    2 -> also log configuration
                                    3 -> log all major steps
                                    4 -> very verbose, log also small steps
--downsampling_lambda=d             The distribution of introns in training
                                    gene structures generated by GeneMark-EX
                                    has a huge weight on single-exon and
                                    few-exon genes. Specifying the lambda
                                    parameter of a poisson distribution will
                                    make GALBA call a script for downsampling
                                    of training gene structures according to
                                    their number of introns distribution, i.e.
                                    genes with none or few exons will be
                                    downsampled, genes with many exons will be
                                    kept. Default value is 2. 
                                    If you want to avoid downsampling, you have 
                                    to specify 0. 
--checkSoftware                     Only check whether all required software
                                    is installed, no execution of GALBA
--nocleanup                         Skip deletion of all files that are typically not 
                                    used in an annotation project after 
                                    running galba.pl. (For tracking any 
                                    problems with a galba.pl run, you 
                                    might want to keep these files, therefore
                                    nocleanup can be activated.)


DEVELOPMENT OPTIONS (PROBABLY STILL DYSFUNCTIONAL)

--splice_sites=patterns             list of splice site patterns for UTR
                                    prediction; default: GTAG, extend like this:
                                    --splice_sites=GTAG,ATAC,...
                                    this option only affects UTR training
                                    example generation, not gene prediction
                                    by AUGUSTUS
--overwrite                         Overwrite existing files (except for
                                    species parameter files) Beware, currently
                                    not implemented properly!
--CfgFiles=file.cfg                 Specify custom extrinsic.cfg file
                                    unless you know what you are doing!
--translation_table=INT             Change translation table from non-standard
                                    to something else. 
                                    DOES NOT WORK YET BECAUSE GALBA DOESNT
                                    SWITCH TRANSLATION TABLE FOR GENEMARK-EX, YET!
--traingenes=file.gtf               instead of using Miniprot or GTH to generate
                                    traingenes, provide a gtf file.


EXAMPLE

To run with RNA-Seq

galba.pl [OPTIONS] --genome=genome.fa --species=speciesname \
    --prot_seq=proteins.fa --prg=miniprot
    
ENDUSAGE

# Declartion of global variables ###############################################

my $v = 4; # determines what is printed to log
my $version = "2.1.6";
my $rootDir;
my $logString = "";          # stores log messages produced before opening log file
$logString .= "\#**********************************************************************************\n";
$logString .= "\#                               GALBA CONFIGURATION                               \n";
$logString .= "\#**********************************************************************************\n";
$logString .= "\# GALBA CALL: ". $0 . " ". (join " ", @ARGV) . "\n";
$logString .= "\# ". (localtime) . ": galba.pl version $version\n";
my $prtStr;
my $alternatives_from_evidence = "true";
                 # output alternative transcripts based on explicit evidence
                 # from hints
my $augpath;     # path to augustus
my $augustus_cfg_path;        # augustus config path, higher priority than
                              # $AUGUSTUS_CONFIG_PATH on system
my $augustus_bin_path;        # path to augustus folder binaries folder
my $augustus_scripts_path;    # path to augustus scripts folder
my $AUGUSTUS_CONFIG_PATH;
my $AUGUSTUS_BIN_PATH;
my $AUGUSTUS_SCRIPTS_PATH;
my $PYTHON3_PATH;
my $MAKEHUB_PATH;
my $CDBTOOLS_PATH;
my $cdbtools_path;
my $makehub_path;
my $email; # for make_hub.py
my @bam;                      # bam file names
my @stranded;                 # contains +,-,+,-... corresponding to 
                              # bam files
my $checkOnly = 0;
my $bamtools_path;
my $BAMTOOLS_BIN_PATH;
my $bool_species = "true";     # false, if $species contains forbidden words
my $cmdString;    # to store shell commands
my $CPU        = 1;      # number of CPUs that can be used
my $currentDir = cwd();  # working superdirectory where program is called from
my $errorfile;           # stores current error file name
my $errorfilesDir;       # directory for error files
my @extrinsicCfgFiles;    # assigned extrinsic files
my $extrinsicCfgFile;    # file to be used for running AUGUSTUS
my $extrinsicCfgFile1;   # user supplied file 1
my $extrinsicCfgFile2;   # user supplied file 2
my $extrinsicCfgFile3;   # user supplied file 3
my $extrinsicCfgFile4;   # user supplied file 4
my @files;               # contains all files in $rootDir
my $flanking_DNA;        # length of flanking DNA, default value is
                         # min{ave. gene length/2, 10000}
my @forbidden_words;     # words/commands that are not allowed in species name
my $gb_good_size;        # number of LOCUS entries in 'train.gb'
my $genbank;             # genbank file name
my $PROTHINT_PATH;
my $prothint_path;
my $PROTHINT_REQUIRED = "prothint.py 2.6.0";   # Version of ProtHint required for this GALBA version
my $genome;              # name of sequence file
my %scaffSizes;          # length of scaffolds
my $gff3 = 0;            # create output file in GFF3 format
my $help;                # print usage
my @hints;               # input hints file names
my $hintsfile;           # hints file (all hints)
my $prot_hintsfile;      # hints file with protein hints
my $limit = 10000000;    # maximum for generic species Sp_$limit
my $logfile;             # contains used shell commands
my $optCfgFile;          # optinonal extrinsic config file for AUGUSTUS
my $annot;          # reference annotation to compare predictions to
my $annot_pseudo;   # file with pseudogenes to be excluded from accuracy measurements
my %accuracy;       # stores accuracy results of gene prediction runs
my $overwrite = 0; # overwrite existing files (except for species parameter files)
my $parameterDir;     # directory of parameter files for species
my $perlCmdString;    # stores perl commands
my $printVersion = 0; # print version number, if set
my $SAMTOOLS_PATH;
my $SAMTOOLS_PATH_OP;    # path to samtools executable
my $scriptPath = dirname($0); # path of directory where this script is located
my $skipoptimize   = 0; # skip optimize parameter step
my $skipIterativePrediction;
my $skipAllTraining = 0;    # skip all training
my $skipGetAnnoFromFasta = 0; # requires python3 & biopython
my $species;                # species name
my $soft_mask = 0;          # soft-masked flag
my $standard  = 0;          # index for standard malus/ bonus value
                            # (currently 0.1 and 1e1)
my $chunksize = 2500000;          # chunksize for running AUGUSTUS in parallel
my $stdoutfile;    # stores current standard output
my $string;        # string for storing script path
my $augustus_args; # string that stores command line arguments to be passed to
                   # augustus
my $testsize1;  # number of genes to test AUGUSTUS accuracy on after trainnig
my $testsize2;  # number of genes to test AUGUSTUS with during optimize_augustus.pl
my $useexisting
    = 0;        # use existing species config and parameter files, no changes
                # on those files
my $UTR = "off";    # UTR prediction on/off. currently not available für new
                    # species
my $addUTR = "off";
my $workDir;        # in the working directory results and temporary files are
                    # stored
my $filterOutShort; # filterOutShort option (see help)
my $augustusHintsPreds; # already existing AUGUSTUS hints prediction without UTR
my $makehub; # flag for creating track data hub

# Hint type from input hintsfile will be checked
my @allowedHints = (
    "intron",  "start",    "stop",
    "ass",     "dss",     "exonpart", "exon",
    "CDSpart", "UTRpart", "nonexonpart", "ep"
);

my $crf;     # flag that determines whether CRF training should be tried
my $keepCrf;
my $nice;    # flag that determines whether system calls should be executed
             # with bash nice (default nice value)
my ( $target_1, $target_2, $target_3, $target_4, $target_5) = 0;
                      # variables that store AUGUSTUS accuracy after different
                      # training steps
my $prg;              # variable to store protein alignment tool
my @prot_seq_files;   # variable to store protein sequence file name
my @prot_aln_files;   # variable to store protein alignment file name
my $ALIGNMENT_TOOL_PATH;
         # stores path to binary of gth, spaln or exonerate for running
         # protein alignments
my $ALIGNMENT_TOOL_PATH_OP;    # higher priority than environment variable
my $DIAMOND_PATH; # path to diamond, alternative to BLAST
my $diamond_path; # command line argument value for $DIAMOND_PATH
my $BLAST_PATH; # path to blastall and formatdb ncbi blast executable
my $blast_path; # command line argument value for $BLAST_PATH
my $python3_path; # command line argument value for $PYTHON3_PATH
my $java_path;
my $JAVA_PATH;
my $gushr_path;
my $GUSHR_PATH;
my %hintTypes;    # stores hint types occuring over all generated and supplied
                  # hints for comparison
my $rounds = 5;   # rounds used by optimize_augustus.pl
my $gth2traingenes; # Generate training genestructures for AUGUSTUS from
                    # GenomeThreader (can be used in addition to RNA-Seq
                    # generated training gene structures)
my $gthTrainGeneFile;    # gobally accessible file name variable
my $ab_initio;    # flag for output of AUGUSTUS ab initio predictions
my $foundRNASeq = 0; # stores whether any external RNA-Seq input was found
my $foundProt = 0; # stores whether any external protein input was found
my $foundProteinHint = 0; # stores whether hintsfile contains src=P
my $lambda = 2; # labmda of poisson distribution for downsampling of training genes
my @splice_cmd_line;
my @splice;
my $AUGUSTUS_hints_preds; # for UTR training only (updating existing runs)
my $cleanup = 1; # enable file and directory cleanup after successful run
# list of forbidden words for species name
my $nocleanup;
my $ttable = 1; # translation table to be used
my $gc_prob = 0.001;
my $gm_max_intergenic;
my $skip_fixing_broken_genes; # skip execution of fix_in_frame_stop_codon_genes.py
my $traingtf;
my $trainFromGth = 1;
@forbidden_words = (
    "system",    "exec",  "passthru", "run",    "fork",   "qx",
    "backticks", "chmod", "chown",    "chroot", "unlink", "do",
    "eval",      "kill",  "rm",       "mv",     "grep",   "cd",
    "top",       "cp",    "for",      "done",   "passwd", "while",
    "nice", "ln"
);

if ( @ARGV == 0 ) {
    print "$usage\n";
    exit(0);
}

GetOptions(
    'alternatives-from-evidence=s' => \$alternatives_from_evidence,
    'AUGUSTUS_CONFIG_PATH=s'       => \$augustus_cfg_path,
    'AUGUSTUS_BIN_PATH=s'          => \$augustus_bin_path,
    'AUGUSTUS_SCRIPTS_PATH=s'      => \$augustus_scripts_path,
    'ALIGNMENT_TOOL_PATH=s'        => \$ALIGNMENT_TOOL_PATH_OP,
    'DIAMOND_PATH=s'               => \$diamond_path,
    'BLAST_PATH=s'                 => \$blast_path,
    'PYTHON3_PATH=s'               => \$python3_path,
    'JAVA_PATH=s'                  => \$java_path,
    'GUSHR_PATH=s'                 => \$gushr_path,
    'CDBTOOLS_PATH=s'              => \$cdbtools_path,
    'MAKEHUB_PATH=s'               => \$makehub_path,
    'bam=s'                        => \@bam,
    'BAMTOOLS_PATH=s'              => \$bamtools_path,
    'cores=i'                      => \$CPU,
    'extrinsicCfgFiles=s'           => \@extrinsicCfgFiles,
    'PROTHINT_PATH=s'              => \$prothint_path,
    'AUGUSTUS_hints_preds=s'       => \$AUGUSTUS_hints_preds,
    'genome=s'                     => \$genome,
    'gff3'                         => \$gff3,
    'hints=s'                      => \@hints,
    'optCfgFile=s'                 => \$optCfgFile,
    'overwrite!'                   => \$overwrite,
    'SAMTOOLS_PATH=s'              => \$SAMTOOLS_PATH_OP,
    'skipOptimize!'                => \$skipoptimize,
    'skipIterativePrediction!'     => \$skipIterativePrediction,
    'skipAllTraining!'             => \$skipAllTraining,
    'skipGetAnnoFromFasta!'        => \$skipGetAnnoFromFasta,
    'species=s'                    => \$species,
    'softmasking!'                 => \$soft_mask,
    'useexisting!'                 => \$useexisting,
    'UTR=s'                        => \$UTR,
    'addUTR=s'                     => \$addUTR,
    'workingdir=s'                 => \$workDir,
    'filterOutShort!'              => \$filterOutShort,
    'crf!'                         => \$crf,
    'keepCrf!'                     => \$keepCrf,
    'nice!'                        => \$nice,
    'help!'                        => \$help,
    'prg=s'                        => \$prg,
    'prot_seq=s'                   => \@prot_seq_files,
    'prot_aln=s'                   => \@prot_aln_files,
    'augustus_args=s'              => \$augustus_args,
    'rounds=s'                     => \$rounds,
    'AUGUSTUS_ab_initio!'          => \$ab_initio,
    'eval=s'                       => \$annot,
    'eval_pseudo=s'                => \$annot_pseudo,
    'verbosity=i'                  => \$v,
    'downsampling_lambda=s'        => \$lambda,
    'splice_sites=s'               => \@splice_cmd_line,
    'flanking_DNA=i'               => \$flanking_DNA,
    'stranded=s'                   => \@stranded,
    'checkSoftware!'               => \$checkOnly,
    'nocleanup!'                   => \$nocleanup,
    'makehub!'                     => \$makehub,
    'email=s'                      => \$email,
    'version!'                     => \$printVersion,
    'translation_table=s'          => \$ttable,
    'skip_fixing_broken_genes!'    => \$skip_fixing_broken_genes,
    'gc_probability=s'             => \$gc_prob,
    'gm_max_intergenic=s'          => \$gm_max_intergenic,
    'traingenes=s'                 => \$traingtf
) or die("Error in command line arguments\n");

if ($help) {
    print $usage;
    exit(0);
}

if ($printVersion) {
    print "galba.pl version $version\n";
    exit(0);
}

if($nocleanup){
    $cleanup = 0;
}

# Define publications to be cited ##############################################
# GALBA1, GALBA2, GALBA-whole, aug-cdna, aug-hmm, diamond, blast1, blast2,
# gm-es, gm-et, gm-ep, gm-fungus, samtools, bamtools, gth, exonerate, spaln,
# spaln2, makehub
my %pubs;
$pubs{'GALBA-whole'} = "\nHoff, K. J., Lomsadze, A., Borodovsky, M., & Stanke, M. (2019). Whole-genome annotation with BRAKER. In Gene Prediction (pp. 65-95). Humana, New York, NY.\n";
$pubs{'aug-hmm'} = "\nStanke, M., Schöffmann, O., Morgenstern, B., & Waack, S. (2006). Gene prediction in eukaryotes with a generalized hidden Markov model that uses hints from external sources. BMC Bioinformatics, 7(1), 62.\n";
$pubs{'diamond'} = "\nBuchfink, B., Xie, C., & Huson, D. H. (2015). Fast and sensitive protein alignment using DIAMOND. Nature Methods, 12(1), 59.\n";
$pubs{'gth'} = "\nGremme, G. (2013). Computational gene structure prediction.\n";

# Make paths to input files absolute ###########################################

make_paths_absolute();

# Set working directory ########################################################

my $wdGiven;
# if no working directory is set, use current directory
if ( !defined $workDir ) {;

    ;
    $wdGiven = 0;
    $workDir = $currentDir;
}else {
    $wdGiven = 1;
    my $last_char = substr( $workDir, -1 );
    if ( $last_char eq "\/" ) {
        chop($workDir);
    }
    my $tmp_dir_name = abs_path($workDir);
    $workDir = $tmp_dir_name;
    if ( not( -d $workDir ) ) {
        $prtStr = "\# " . (localtime) . ": Creating directory $workDir.\n";
        $logString .= $prtStr if ( $v > 2 );
        mkdir($workDir) or die ("ERROR: in file " . __FILE__ ." at line "
            . __LINE__ ."\nFailed to create directory $workDir!\n");
    }
}

# check the write permission of $workDir #######################################
if ( !-w $workDir ) {
    $prtStr
        = "\# "
        . (localtime)
        . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
        . "Do not have write permission for $workDir.\nPlease"
        . " use command 'chmod' to reset permissions, or specify another working "
        . "directory with option --workingdir=...\n";
    $logString .= $prtStr;
    print STDERR $logString;
    exit(1);
}

# determine in which mode to run galba.pl #####################################
determineRunMode();

# configure which tools GALBA is going to run #################################
# * use command line argument if given
# * else use environment variable if present
# * else try to guess (might fail)

$prtStr
    = "\# "
    . (localtime)
    . ": Configuring of GALBA for using external tools...\n";
$logString .= $prtStr if ( $v > 2 );
set_AUGUSTUS_CONFIG_PATH();
set_AUGUSTUS_BIN_PATH();
set_AUGUSTUS_SCRIPTS_PATH();
set_PYTHON3_PATH();

if (not ($skipAllTraining)){
    set_BLAST_or_DIAMOND_PATH();
}

if (@prot_seq_files){
    set_ALIGNMENT_TOOL_PATH();
}

if ( $makehub ) {
    set_MAKEHUB_PATH();
}
if( not($skip_fixing_broken_genes)){
    set_CDBTOOLS_PATH();
}

if($checkOnly){
    $prtStr = "\# " . (localtime)
            . ": Exiting galba.pl because it had been started with "
            . "--softwareCheck option. No training or prediction or file format "
            . "check will be performed.\n";
    $logString .= $prtStr;
    print $logString;
    exit(0);
}

# check for known issues that may cause problems with galba.pl ################
check_upfront();

# check whether galba.pl options are set in a compatible way ##################
check_options();

# Starting GALBA pipeline #####################################################

$logString .= "\#**********************************************************************************\n";
$logString .= "\#                               CREATING DIRECTORY STRUCTURE                       \n";
$logString .= "\#**********************************************************************************\n";

# check whether $rootDir already exists
if ( $wdGiven == 1 ) {
    $rootDir = $workDir;
}
else {
    $rootDir = "$workDir/GALBA";
}
if ( -d "$rootDir/$species" && !$overwrite && $wdGiven == 0 ) {
    $prtStr
        = "#*********\n"
        . ": WARNING: $rootDir/$species already exists. GALBA will use"
        . " existing files, if they are newer than the input files. You can "
        . "choose another working directory with --workingdir=dir or overwrite "
        . "it with --overwrite.\n"
        . "#*********\n";
    $logString .= $prtStr if ( $v > 0 );
}

# create $rootDir
if ( !-d $rootDir ) {
    $prtStr = "\# "
        . (localtime)
        . ": create working directory $rootDir.\n"
        . "mkdir $rootDir\n";
    make_path($rootDir) or die("ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nFailed to create direcotry $rootDir!\n");
    $logString .= $prtStr if ( $v > 2 );
}


$parameterDir  = "$rootDir/species";
my $otherfilesDir = "$rootDir";
$errorfilesDir = "$rootDir/errors";

$logfile = "$otherfilesDir/GALBA.log";

# create directory $otherfilesDir
if ( !-d $otherfilesDir ) {
    $prtStr = "\# "
        . (localtime)
        . ": create working directory $otherfilesDir.\n"
        . "mkdir $otherfilesDir\n";
    $logString .= $prtStr if ( $v > 2 );
    make_path($otherfilesDir) or die("ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nFailed to create directory $otherfilesDir!\n");
}

# make paths to reference annotation files absolute if they were given
if(defined($annot)){
    $annot = rel2abs($annot);
}
if(defined($annot_pseudo)){
    $annot_pseudo = rel2abs($annot_pseudo);
}

# convert possible relative path to provided AUGUSTUS file to absolute path
if( defined( $AUGUSTUS_hints_preds )) {
    $AUGUSTUS_hints_preds = rel2abs($AUGUSTUS_hints_preds);
}

# make path to traingenes file absolute it it wasn't already
if(defined($traingtf)){
    $traingtf = rel2abs($traingtf);
}

# open log file
$prtStr = "\# "
        . (localtime)
        . ": Log information is stored in file $logfile\n";
print STDOUT $prtStr;

open( LOG, ">" . $logfile ) or die("ERROR in file " . __FILE__ ." at line "
    . __LINE__ ."\nCannot open file $logfile!\n");
print LOG $logString;

# open cite file
print LOG "\# "
        . (localtime)
        . ": creating file that contains citations for this GALBA run at "
        . "$otherfilesDir/what-to-cite.txt...\n" if ($v > 2);
open( CITE, ">", "$otherfilesDir/what-to-cite.txt") or die("ERROR in file " . __FILE__ ." at line "
    . __LINE__ ."\n$otherfilesDir/what-to-cite.txt!\n");
print CITE "When publishing results of this GALBA run, please cite the following sources:\n";
print CITE "------------------------------------------------------------------------------\n";
print CITE $pubs{'GALBA-whole'}; $pubs{'GALBA-whole'} = "";


# set gthTrainGenes file
if ( $gth2traingenes ) {
    $gthTrainGeneFile = "$otherfilesDir/gthTrainGenes.gtf";
}

# create parameter directory
if ( !-d $parameterDir ) {
    make_path($parameterDir) or die("ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nFailed to create direcotry $parameterDir!\n");
    print LOG "\# "
        . (localtime)
        . ": create working directory $parameterDir\n"
        . "mkdir $parameterDir\n" if ($v > 2);
}

# create error file directory
if ( !-d $errorfilesDir ) {
    make_path($errorfilesDir)or die("ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nFailed to create direcotry $errorfilesDir!\n");
    print LOG "\# "
        . (localtime)
        . ": create working directory $errorfilesDir\n"
        . "mkdir $errorfilesDir\n" if ($v > 2);
}

# need to do this check after $errorfilesDir has been set:
if (not($skipGetAnnoFromFasta) || $makehub){
    check_biopython();
}

print LOG "\# "
    . (localtime)
    . ": changing into working directory $rootDir\n"
    . "cd $rootDir\n" if ($v > 2);

chdir $rootDir or die("ERROR in file " . __FILE__ ." at line ".
    __LINE__ ."\nCould not change into directory $rootDir.\n");

if ( $skipAllTraining == 0 && not ( defined($AUGUSTUS_hints_preds) ) ) {
    # create new species parameter files; we do this FIRST, before anything else,
    # because if you start several processes in parallel, you might otherwise end
    # up with those processes using the same species directory!
    new_species();
} else {
    if( defined($AUGUSTUS_hints_preds) && $addUTR eq "off") {  
        # if no training will be executed, check whether species parameter files exist
        my $specPath
            = "$AUGUSTUS_CONFIG_PATH/species/$species/$species" . "_";
        my @confFiles = (
            "exon_probs.pbl",   "igenic_probs.pbl",
            "intron_probs.pbl",
            "parameters.cfg",   "weightmatrix.txt"
        );

        foreach (@confFiles) {
            if ( not( -e "$specPath" . "$_" ) ) {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                    . "Config file $specPath"
                    . "$_ for species $species "
                    . "does not exist!\n";
                print LOG $prtStr;
                print STDERR $prtStr;
                exit(1);
            }
        }
        if ( $UTR eq "on" && !$AUGUSTUS_hints_preds && !$skipAllTraining ) {
            @confFiles = ( "metapars.utr.cfg", "utr_probs.pbl" );
            foreach (@confFiles) {
                if ( not( -e "$specPath" . "$_" ) ) {
                    $prtStr
                        = "\# "
                        . (localtime)
                        . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                        . "Config file $specPath"
                        . "$_ for species $species "
                        . "does not exist!\n";
                    print LOG $prtStr;
                    print STDERR $prtStr;
                    exit(1);
                }
            }
        }elsif( $UTR eq "on" && not(defined($skipAllTraining))) {
            if( not ( -e $specPath . "metapars.utr.cfg" ) ) {
                $prtStr = "\# "
                        . (localtime)
                        . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                        . "Config file $specPath"
                        . "metapars.utr.cfg for species $species "
                        . "does not exist!\n";
                print LOG $prtStr;
                print STDERR $prtStr;
                exit(1);
            }
        }elsif( $UTR eq "on" && $skipAllTraining==1 ) {
            if( not ( -e $specPath . "utr_probs.pbl" ) ) {
                $prtStr = "\# "
                        . (localtime)
                        . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                        . "Config file $specPath"
                        . "utr_probs.pbl for species $species "
                        . "does not exist!\n";
                print LOG $prtStr;
                print STDERR $prtStr;
                exit(1);
            }
        }
    }
}

 # check fasta headers
check_fasta_headers($genome, 1);
if (@prot_seq_files) {
    my @tmp_prot_seq;
    foreach (@prot_seq_files) {
        push(@tmp_prot_seq, $_);
        check_fasta_headers($_, 0);
    }
    @prot_seq_files = @tmp_prot_seq;
}

# count scaffold sizes and check whether the assembly is not too fragmented for
#  parallel execution of AUGUSTUS
open (GENOME, "<", "$otherfilesDir/genome.fa") or clean_abort(
    "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting, "ERROR in file "
    . __FILE__ ." at line ". __LINE__
    ."\nCould not open file $otherfilesDir/genome.fa");
my $gLocus;
while( <GENOME> ){
    chomp;
    if(m/^>(.*)/){
        $gLocus = $1;
    }else{
        if(not(defined($scaffSizes{$gLocus}))){
            $scaffSizes{$gLocus} = length ($_);
        }else{
            $scaffSizes{$gLocus} += length ($_);
        }
    }
}
close (GENOME) or clean_abort(
    "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting, "ERROR in file "
    . __FILE__ ." at line ". __LINE__
    . "\nCould not close file $otherfilesDir/genome.fa");
my @nScaffs = keys %scaffSizes;
my $totalScaffSize = 0;
foreach( values %scaffSizes) {
    $totalScaffSize += $_;
}
# unsure what is an appropriate limit, because it depends on the kernel and
# on the stack size. Use 30000 just to be sure. This will result in ~90000 files in the
# augustus_tmp folder.
if ( (scalar(@nScaffs) > 30000) && ($CPU > 1) ) {
    $prtStr = "#*********\n"
            . "# WARNING: in file " . __FILE__ ." at line ". __LINE__ ."\n"
            . "file $genome contains a highly fragmented assembly ("
            . scalar(@nScaffs)." scaffolds). This may lead "
            . "to problems when running AUGUSTUS via GALBA in parallelized "
            . "mode. You set --cores=$CPU. You should run galba.pl in linear "
            . "mode on such genomes, though (--cores=1).\n"
            . "#*********\n";
    print STDOUT $prtStr;
    print LOG $prtStr;
}elsif( (($totalScaffSize / $chunksize) > 30000) && ($CPU > 1) ){
    $prtStr = "#*********\n"
            . "# WARNING: in file " . __FILE__ ." at line ". __LINE__ ."\n"
            . "file $genome contains contains $totalScaffSize bases. "
            . "This may lead "
            . "to problems when running AUGUSTUS via GALBA in parallelized "
            . "mode. You set --cores=$CPU. There is a variable \$chunksize in "
            . "galba.pl. Default value is currently $chunksize. You can adapt "
            . "this to a higher number. The total base content / chunksize * 3 "
            . "should not exceed the number of possible arguments for commands "
            . "like ls *, cp *, etc. on your system.\n"
            . "#*********\n";
    print STDOUT $prtStr;
    print LOG $prtStr;
}

print LOG "\#**********************************************************************************\n"
        . "\#                               PROCESSING HINTS                                   \n"
        . "\#**********************************************************************************\n";

# make hints from protein data

if( @prot_seq_files or @prot_aln_files 
    && not ( defined($AUGUSTUS_hints_preds) ) ){
    make_prot_hints(); # not ProtHint, but old pipeline for generating protein hints!
}

# add other user supplied hints
if (@hints && not (defined($AUGUSTUS_hints_preds))) {
    add_other_hints();
}

if ( $skipAllTraining == 0 && not ( defined($AUGUSTUS_hints_preds) ) ) {
    print LOG "\#**********************************************************************************\n"
            . "\#                               TRAIN AUGUSTUS                                     \n"
            . "\#**********************************************************************************\n";
    # train AUGUSTUS
    training_augustus();
}


if( not ( defined( $AUGUSTUS_hints_preds ) ) ){
    print LOG "\#**********************************************************************************\n"
            . "\#                               PREDICTING GENES WITH AUGUSTUS (NO UTRS)           \n"
            . "\#**********************************************************************************\n";
    augustus("off");    # run augustus without UTR
    merge_transcript_sets("off");
}

if ( $gff3 != 0) {
    all_preds_gtf2gff3();
}

if( $annot ) {
    evaluate();
}

if ( $makehub ) {
    print LOG "\#**********************************************************************************\n"
            . "\#                               GENERATING TRACK DATA HUB                          \n"
            . "\#**********************************************************************************\n";
    make_hub();
}

clean_up();         # delete all empty files
print LOG "\#**********************************************************************************\n"
        . "\#                               GALBA RUN FINISHED                                \n"
        . "\#**********************************************************************************\n";

close(CITE) or die("ERROR in file " . __FILE__ ." at line ". __LINE__
    ."\nCould not close file $otherfilesDir/what-to-cite.txt!\n");

close(LOG) or die("ERROR in file " . __FILE__ ." at line ". __LINE__
    ."\nCould not close log file $logfile!\n");


############### sub functions ##################################################

####################### make_paths_absolute ####################################
# make paths to all input files absolute
################################################################################

sub make_paths_absolute {

    # make genome path absolute
    if (defined($genome)) {
        $genome = rel2abs($genome);
    }

    # make bam paths absolute
    if (@bam) {
        @bam = split( /[\s,]/, join( ',', @bam ) );
        for ( my $i = 0; $i < scalar(@bam); $i++ ) {
            $bam[$i] = rel2abs( $bam[$i] );
        }
    }

    # make hints paths absolute
    if (@hints) {
        @hints = split( /[\s,]/, join( ',', @hints ) );
        for ( my $i = 0; $i < scalar(@hints); $i++ ) {
            $hints[$i] = rel2abs( $hints[$i] );
        }
    }

    # make extrinsic file paths absolute
    if (@extrinsicCfgFiles) {
        @extrinsicCfgFiles = split( /[\s,]/, join( ',', @extrinsicCfgFiles ) );
        for ( my $i = 0; $i < scalar(@extrinsicCfgFiles); $i++ ) {
            $extrinsicCfgFiles[$i] = rel2abs ($extrinsicCfgFiles[$i]);
        }
    }

    # make prot seq file paths absolut
    if (@prot_seq_files) {
        @prot_seq_files = split( /[\s,]/, join( ',', @prot_seq_files ) );
        for ( my $i = 0; $i < scalar(@prot_seq_files); $i++ ) {
            $prot_seq_files[$i] = rel2abs( $prot_seq_files[$i] );
        }
    }

    # make prot aln paths absolute
    if (@prot_aln_files) {
        @prot_aln_files = split( /[\s,]/, join( ',', @prot_aln_files ) );
        for ( my $i = 0; $i < scalar(@prot_aln_files); $i++ ) {
            $prot_aln_files[$i] = rel2abs( $prot_aln_files[$i] );
        }
    }

}

####################### set_AUGUSTUS_CONFIG_PATH ###############################
# * set path to AUGUSTUS_CONFIG_PATH
# * this directory contains a folder species and a folder config for running
#   AUGUSTUS
# * ../bin is usually the location of augustus binaries
# * ../scripts is usually the location of augustus scripts
################################################################################

sub set_AUGUSTUS_CONFIG_PATH {

    # get path from ENV (if available)
    if ( defined( $ENV{'AUGUSTUS_CONFIG_PATH'} ) && not(defined($augustus_cfg_path)) ) {
        if ( -e $ENV{'AUGUSTUS_CONFIG_PATH'} ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": Found environment variable \$AUGUSTUS_CONFIG_PATH. "
                . "Setting \$AUGUSTUS_CONFIG_PATH to "
                . $ENV{'AUGUSTUS_CONFIG_PATH'}."\n";
            $logString .= $prtStr if ($v > 1);
            $AUGUSTUS_CONFIG_PATH = $ENV{'AUGUSTUS_CONFIG_PATH'};
        }
    }
    elsif(not(defined($augustus_cfg_path))) {
        $prtStr
            = "\# "
            . (localtime)
            . ": Did not find environment variable \$AUGUSTUS_CONFIG_PATH "
            . "(either variable does not exist, or the path given in variable "
            . "does not exist). Will try to set this variable in a different "
            . "way, later.\n";
        $logString .= $prtStr if ($v > 1);
    }

    # get path from GALBA (if available, overwrite ENV retrieved)
    if ( defined($augustus_cfg_path) ) {
        my $last_char = substr( $augustus_cfg_path, -1 );
        if ( $last_char eq "\/" ) {
            chop($augustus_cfg_path);
        }
        if ( -d $augustus_cfg_path ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": Command line flag --AUGUSTUS_CONFIG_PATH was provided."
                . " Setting \$AUGUSTUS_CONFIG_PATH in galba.pl to "
                . "$augustus_cfg_path.\n";
            $logString .= $prtStr if ($v > 1);
            $AUGUSTUS_CONFIG_PATH = $augustus_cfg_path;
        }
        else {
            $prtStr
                = "#*********\n"
                . ": WARNING: Command line flag --AUGUSTUS_CONFIG_PATH "
                . "was provided. The given path $augustus_cfg_path is not a "
                . "directory. Cannot use this as variable "
                . "\$AUGUSTUS_CONFIG_PATH in galba.pl!\n"
                . "#*********\n";
            $logString .= $prtStr if ($v > 0);
        }
    }

    # if no AUGUSTUS config given, try to guess from the "augustus" executable
    if ( not( defined $AUGUSTUS_CONFIG_PATH )
        or length($AUGUSTUS_CONFIG_PATH) == 0 )
    {
        my $epath = which 'augustus';
        if(defined($epath)){
            $AUGUSTUS_CONFIG_PATH = dirname( abs_path($epath) ) . "/../config";
            $augustus_cfg_path    = $AUGUSTUS_CONFIG_PATH;
        }else{
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "Tried to find augustus binary with which but failed.\n";
            $logString .= $prtStr;
        }
        if ( not( -d $AUGUSTUS_CONFIG_PATH ) ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "Tried guessing \$AUGUSTUS_CONFIG_PATH from "
                . "system augustus path, but $AUGUSTUS_CONFIG_PATH is not a "
                . "directory.\n";
            $logString .= $prtStr;
        }
    }
    my $aug_conf_err;
    $aug_conf_err
        .= "There are 3 alternative ways to set this variable for galba.pl:\n"
        . "   a) provide command-line argument "
        . "--AUGUSTUS_CONFIG_PATH=/your/path\n"
        . "   b) use an existing environment variable \$AUGUSTUS_CONFIG_PATH\n"
        . "      for setting the environment variable, run\n"
        . "           export AUGUSTUS_CONFIG_PATH=/your/path\n"
        . "      in your shell. You may append this to your .bashrc or\n"
        . "      .profile file in order to make the variable available to all\n"
        . "      your bash sessions.\n"
        . "   c) galba.pl can try guessing the location of\n"
        . "      \$AUGUSTUS_CONFIG_PATH from an augustus executable that is\n"
        . "      available in your \$PATH variable.\n"
        . "      If you try to rely on this option, you can check by typing\n"
        . "           which augustus\n"
        . "      in your shell, whether there is an augustus executable in\n"
        . "      your \$PATH\n"
        . "      Be aware: the \$AUGUSTUS_CONFIG_PATH must be writable for\n"
        . "                galba.pl because galba.pl is a pipeline that\n"
        . "                optimizes parameters that reside in that\n"
        . "                directory. This might be problematic in case you\n"
        . "                are using a system-wide installed augustus \n"
        . "                installation that resides in a directory that is\n"
        . "                not writable to you as a user.\n";

    # Give user installation instructions
    if ( not( defined $AUGUSTUS_CONFIG_PATH )
        or length($AUGUSTUS_CONFIG_PATH) == 0 )
    {
        $prtStr
            = "\# "
            . (localtime)
            . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
            . "\$AUGUSTUS_CONFIG_PATH is not defined!\n";
        $logString .= $prtStr;
        $logString .= $aug_conf_err if ($v > 0);
        print STDERR $logString;
        exit(1);
    }
    elsif ( not( -w "$AUGUSTUS_CONFIG_PATH/species" ) )
    {    # check whether config path is writable
        $prtStr
            = "\# "
            . (localtime)
            . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
            . "AUGUSTUS_CONFIG_PATH/species (in this case ";
        $prtStr .= "$AUGUSTUS_CONFIG_PATH/$species) is not writeable.\n";
        $logString .= $prtStr;
        $logString .= $aug_conf_err if ($v > 0);
        print STDERR $logString;
        exit(1);
    }

}

####################### set_AUGUSTUS_BIN_PATH ##################################
# * usually AUGUSTUS_CONFIG_PATH/../bin but may differ on some systems
################################################################################

sub set_AUGUSTUS_BIN_PATH {

    # get path from ENV (if available)
    if ( defined( $ENV{'AUGUSTUS_BIN_PATH'} ) && not (defined($augustus_bin_path) ) ) {
        if ( -e $ENV{'AUGUSTUS_BIN_PATH'} ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": Found environment variable \$AUGUSTUS_BIN_PATH. Setting "
                . "\$AUGUSTUS_BIN_PATH to ". $ENV{'AUGUSTUS_BIN_PATH'}."\n";
            $logString .= $prtStr if ($v > 1);
            $AUGUSTUS_BIN_PATH = $ENV{'AUGUSTUS_BIN_PATH'};
        }
    }
    elsif (not (defined($augustus_bin_path))) {
        $prtStr
            = "\# "
            . (localtime)
            . ": Did not find environment variable \$AUGUSTUS_BIN_PATH "
            . "(either variable does not exist, or the path given in variable "
            . "does not exist). Will try to set this variable in a different "
            . "way, later.\n";
        $logString .= $prtStr if ($v > 1);
    }

    # get path from GALBA (if available, overwrite ENV retrieved)
    if ( defined($augustus_bin_path) ) {
        my $last_char = substr( $augustus_bin_path, -1 );
        if ( $last_char eq "\/" ) {
            chop($augustus_bin_path);
        }
        if ( -d $augustus_bin_path ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": Setting \$AUGUSTUS_BIN_PATH to command line argument ";
            $prtStr .= "--AUGUSTUS_BIN_PATH value $augustus_bin_path.\n";
            $logString .= $prtStr if ($v > 1);
            $AUGUSTUS_BIN_PATH = $augustus_bin_path;
        }
        else {
            $prtStr
                = "#*********\n"
                . "# WARNING: Command line argument --AUGUSTUS_BIN_PATH was "
                . "supplied but value $augustus_bin_path is not a directory. "
                . "Will not set \$AUGUSTUS_BIN_PATH to $augustus_bin_path!\n"
                . "#*********\n";
            $logString .= $prtStr if ($v > 1);
        }
    }

    # if both failed, try to guess
    if ( not( defined($AUGUSTUS_BIN_PATH) )
        || length($AUGUSTUS_BIN_PATH) == 0 )
    {
        $prtStr
            = "\# "
            . (localtime)
            . ": Trying to guess \$AUGUSTUS_BIN_PATH from "
            . "\$AUGUSTUS_CONFIG_PATH.\n";
        $logString .= $prtStr if ($v > 1);
        if ( -d "$AUGUSTUS_CONFIG_PATH/../bin" ) {
            $prtStr
                = "\# " . (localtime) . ": Setting \$AUGUSTUS_BIN_PATH to "
                . "$AUGUSTUS_CONFIG_PATH/../bin\n";
            $logString .= $prtStr if ($v > 1);
            $AUGUSTUS_BIN_PATH = "$AUGUSTUS_CONFIG_PATH/../bin";
        }
        else {
            $prtStr
                = "#*********\n"
                . "# WARNING: Guessing the location of "
                . "\$AUGUSTUS_BIN_PATH failed. $AUGUSTUS_CONFIG_PATH/../bin is "
                . "not a directory!\n"
                . "#*********\n";
            $logString .= $prtStr if ($v > 0);
        }
    }

    if ( not( defined($AUGUSTUS_BIN_PATH) ) ) {
        my $aug_bin_err;
        $aug_bin_err
            .= "There are 3 alternative ways to set this variable for\n"
            .  "galba.pl:\n"
            . "   a) provide command-line argument \n"
            . "      --AUGUSTUS_BIN_PATH=/your/path\n"
            . "   b) use an existing environment variable \$AUGUSTUS_BIN_PATH\n"
            . "      for setting the environment variable, run\n"
            . "           export AUGUSTUS_BIN_PATH=/your/path\n"
            . "      in your shell. You may append this to your .bashrc or\n"
            . "      .profile file in order to make the variable available to\n"
            . "      all your bash sessions.\n"
            . "   c) galba.pl can try guessing the location of \n"
            . "      \$AUGUSTUS_BIN_PATH from the location of \n"
            . "      \$AUGUSTUS_CONFIG_PATH (in this case\n"
            . "      $AUGUSTUS_CONFIG_PATH/../bin\n";
        $prtStr = "\# " . (localtime) . ": ERROR: in file " . __FILE__
            . " at line ". __LINE__ . "\n" . "\$AUGUSTUS_BIN_PATH not set!\n";
        $logString .= $prtStr;
        $logString .= $aug_bin_err if ($v > 0);
        print STDERR $logString;
        exit(1);
    }
}

####################### set_AUGUSTUS_SCRIPTS_PATH ##############################
# * usually AUGUSTUS_CONFIG_PATH/../scripts but may differ on some systems
################################################################################

sub set_AUGUSTUS_SCRIPTS_PATH {

    # first try to get path from ENV
    if ( defined( $ENV{'AUGUSTUS_SCRIPTS_PATH'} ) && not(defined($augustus_scripts_path)) ) {
        if ( -e $ENV{'AUGUSTUS_SCRIPTS_PATH'} ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": Found environment variable \$AUGUSTUS_SCRIPTS_PATH. "
                . "Setting \$AUGUSTUS_SCRIPTS_PATH to "
                . $ENV{'AUGUSTUS_SCRIPTS_PATH'} ."\n";
            $logString .= $prtStr if ($v > 1);
            $AUGUSTUS_SCRIPTS_PATH = $ENV{'AUGUSTUS_SCRIPTS_PATH'};
        }
    }
    elsif(not(defined($augustus_scripts_path))) {
        $prtStr
            = "\# "
            . (localtime)
            . ": Did not find environment variable \$AUGUSTUS_SCRIPTS_PATH "
            . "(either variable does not exist, or the path given in variable "
            . "does not exist). Will try to set this variable in a different "
            . "way, later.\n";
        $logString .= $prtStr if ($v > 1);
    }

    # then try to get path from GALBA
    if ( defined($augustus_scripts_path) ) {
        my $last_char = substr( $augustus_scripts_path, -1 );
        if ( $last_char eq "\/" ) {
            chop($augustus_scripts_path);
        }
        if ( -d $augustus_scripts_path ) {
            $AUGUSTUS_SCRIPTS_PATH = $augustus_scripts_path;
            $prtStr
                = "\# "
                . (localtime)
                . ": Setting \$AUGUSTUS_SCRIPTS_PATH to command line "
                . "argument --AUGUSTUS_SCRIPTS_PATH value "
                . "$augustus_scripts_path.\n";
            $logString .= $prtStr if ($v > 1);
        }
        else {
            $prtStr
                = "#*********\n"
                . "# WARNING: Command line argument --AUGUSTUS_SCRIPTS_PATH "
                . "was supplied but value $augustus_scripts_path is not a "
                . "directory. Will not set \$AUGUSTUS_SCRIPTS_PATH to "
                . "$augustus_scripts_path!\n"
                . "#*********\n";
            $logString .= $prtStr if ($v > 0);
        }
    }

    # otherwise try to guess
    if ( not( defined($AUGUSTUS_SCRIPTS_PATH) )
        || length($AUGUSTUS_SCRIPTS_PATH) == 0 )
    {
        $prtStr
            = "\# "
            . (localtime)
            . ": Trying to guess \$AUGUSTUS_SCRIPTS_PATH from "
            . "\$AUGUSTUS_CONFIG_PATH.\n";
        $logString .= $prtStr if ($v > 1);
        if ( -d "$AUGUSTUS_CONFIG_PATH/../scripts" ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": Setting \$AUGUSTUS_SCRIPTS_PATH to "
                . "$AUGUSTUS_CONFIG_PATH/../scripts\n";
            $logString .= $prtStr if ($v > 1);
            $AUGUSTUS_SCRIPTS_PATH = "$AUGUSTUS_CONFIG_PATH/../scripts";
        }
        else {
            $prtStr
                = "#*********\n"
                . "# WARNING: Guessing the location of "
                . "\$AUGUSTUS_SCRIPTS_PATH failed. "
                . "$AUGUSTUS_CONFIG_PATH/../scripts is not a "
                . "directory!\n"
                . "#*********\n";
            $logString .= $prtStr if ($v > 0);
        }
    }
    if ( not( defined($AUGUSTUS_SCRIPTS_PATH) ) ) {
        my $aug_scr_err;
        $aug_scr_err
            .= "There are 3 alternative ways to set this variable for\n"
            . " galba.pl:\n"
            . "   a) provide command-line argument \n"
            . "      --AUGUSTUS_SCRIPTS_PATH=/your/path\n"
            . "   b) use an existing environment variable \n"
            . "      \$AUGUSTUS_SCRIPTS_PATH for setting the environment \n"
            . "      variable, run\n"
            . "           export AUGUSTUS_SCRIPTS_PATH=/your/path\n"
            . "      in your shell. You may append this to your .bashrc or\n"
            . "      .profile file in order to make the variable available to\n"
            . "      all your bash sessions.\n"
            . "   c) galba.pl can try guessing the location of\n"
            . "      \$AUGUSTUS_SCRIPTS_PATH from the location of\n"
            . "      \$AUGUSTUS_CONFIG_PATH (in this case \n"
            . "      $AUGUSTUS_CONFIG_PATH/../scripts\n";
        $prtStr
            = "\# "
            . (localtime)
            . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
            . "\$AUGUSTUS_SCRIPTS_PATH not set!\n";
        $logString .= $prtStr;
        $logString .= $aug_scr_err if ($v > 1);
        print STDERR $logString;
        exit(1);
    }
}

####################### set_BAMTOOLS_PATH ######################################
# * set path to bamtools
################################################################################

sub set_BAMTOOLS_PATH {

    # try to get path from ENV
    if ( defined( $ENV{'BAMTOOLS_PATH'} ) && not(defined($bamtools_path))) {
        if ( -e $ENV{'BAMTOOLS_PATH'} ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": Found environment variable \$BAMTOOLS_PATH. Setting "
                . "\$BAMTOOLS_PATH to ".$ENV{'BAMTOOLS_PATH'}."\n";
            $logString .= $prtStr if ($v > 1);
            $BAMTOOLS_BIN_PATH = $ENV{'BAMTOOLS_PATH'};
        }
    }
    elsif(not(defined($bamtools_path))) {
        $prtStr
            = "\# "
            . (localtime)
            . ": Did not find environment variable \$BAMTOOLS_PATH "
            . "(either variable does not exist, or the path given in "
            . "variable does not exist). Will try to set this variable in a "
            . "different way, later.\n";
        $logString .= $prtStr if ($v > 1);
    }

    # try to get path from GALBA
    if ( defined($bamtools_path) ) {
        my $last_char = substr( $bamtools_path, -1 );
        if ( $last_char eq "\/" ) {
            chop($bamtools_path);
        }
        if ( -d $bamtools_path ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": Setting \$BAMTOOLS_BIN_PATH to command line argument "
                . "--BAMTOOLS_PATH value $bamtools_path.\n";
            $logString .= $prtStr if ($v > 1);
            $BAMTOOLS_BIN_PATH = $bamtools_path;
        }
        else {
            $prtStr
                = "#*********\n"
                . "# WARNING: Command line argument --BAMTOOLS_PATH was "
                . "supplied but value $bamtools_path is not a directory. Will "
                . "not set \$BAMTOOLS_BIN_PATH to $bamtools_path!\n"
                . "#*********\n";
            $logString .= $prtStr if ($v > 0);
        }
    }

    # try to guess
    if ( not( defined($BAMTOOLS_BIN_PATH) )
        || length($BAMTOOLS_BIN_PATH) == 0 )
    {
        $prtStr
            = "\# "
            . (localtime)
            . ": Trying to guess \$BAMTOOLS_BIN_PATH from location of bamtools"
            . " executable that is available in your \$PATH\n";
        $logString .= $prtStr if ($v > 1);
        my $epath = which 'bamtools';
        if(defined($epath)){
            if ( -d dirname($epath) ) {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": Setting \$BAMTOOLS_BIN_PATH to "
                    . dirname($epath) . "\n";
                $logString .= $prtStr if ($v > 1);
                $BAMTOOLS_BIN_PATH = dirname($epath);
            }
        }
        else {
            $prtStr
                = "#*********\n"
                . "WARNING: Guessing the location of \$BAMTOOLS_BIN_PATH "
                . "failed.\n"
                . "#*********\n";
            $logString .= $prtStr if ($v > 0);
        }
    }

    if ( not( defined($BAMTOOLS_BIN_PATH) ) ) {
        my $bamtools_err;
        $bamtools_err
            .= "There are 3 alternative ways to set this variable for\n"
            . " galba.pl:\n"
            . "   a) provide command-line argument --BAMTOOLS_PATH=/your/path\n"
            . "   b) use an existing environment variable \$BAMTOOLS_PATH\n"
            . "      for setting the environment variable, run\n"
            . "           export BAMTOOLS_PATH=/your/path\n"
            . "      in your shell. You may append this to your .bashrc or\n"
            . "      .profile file in order to make the variable available to\n"
            . "      all your bash sessions.\n"
            . "   c) galba.pl can try guessing the location of\n"
            . "      \$BAMTOOLS_BIN_PATH from the location of a bamtools\n"
            . "      executable that is available in your \$PATH variable.\n"
            . "      If you try to rely on this option, you can check by\n"
            . "      typing\n"
            . "           which bamtools\n"
            . "      in your shell, whether there is a bamtools executable in\n"
            . "      your \$PATH\n";
        $prtStr
            = "\# " . (localtime) . " ERROR: in file " . __FILE__ ." at line "
            . __LINE__ . "\n" . "\$BAMTOOLS_BIN_PATH not set!\n";
        $logString .= $prtStr;
        $logString .= $bamtools_err if ($v > 1);
        print STDERR $logString;
        exit(1);
    }
}

####################### set_ALIGNMENT_TOOL_PATH ################################
# * set path to protein alignment tool (Miniprot or GenomeThreader)
################################################################################

sub set_ALIGNMENT_TOOL_PATH {
    if (@prot_seq_files) {

        # try go get from ENV
        if ( defined( $ENV{'ALIGNMENT_TOOL_PATH'} ) && not (defined( $ALIGNMENT_TOOL_PATH_OP ) ) ) {
            if ( -e $ENV{'ALIGNMENT_TOOL_PATH'} ) {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": Found environment variable \$ALIGNMENT_TOOL_PATH. "
                    . "Setting \$ALIGNMENT_TOOL_PATH to "
                    . $ENV{'ALIGNMENT_TOOL_PATH'}."\n";
                $logString .= $prtStr if ($v > 1);
                $ALIGNMENT_TOOL_PATH = $ENV{'ALIGNMENT_TOOL_PATH'};
            }
        }
        elsif(not(defined($ALIGNMENT_TOOL_PATH_OP))) {
            $prtStr
                = "\# "
                . (localtime)
                . ": Did not find environment variable \$ALIGNMENT_TOOL_PATH "
                . "(either variable does not exist, or the path given in "
                . "variable does not exist). Will try to set this variable in "
                . "a different way, later.\n";
            $logString .= $prtStr if ($v > 1);
        }

        # try to get from GALBA
        if ( defined($ALIGNMENT_TOOL_PATH_OP) ) {
            my $last_char = substr( $ALIGNMENT_TOOL_PATH_OP, -1 );
            if ( $last_char eq "\/" ) {
                chop($ALIGNMENT_TOOL_PATH_OP);
            }
            if ( -d $ALIGNMENT_TOOL_PATH_OP ) {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": Setting \$ALIGNMENT_TOOL_PATH to command line "
                    . "argument --ALIGNMENT_TOOL_PATH value "
                    . "$ALIGNMENT_TOOL_PATH_OP.\n";
                $logString .= $prtStr if ($v > 1);
                $ALIGNMENT_TOOL_PATH = $ALIGNMENT_TOOL_PATH_OP;
            }
        }
        if ( not( defined($ALIGNMENT_TOOL_PATH) ) || length($ALIGNMENT_TOOL_PATH) == 0 ) {
            if ( defined($prg) ) {
                if ( $prg eq "gth" ) {
                    $prtStr
                        = "\# "
                        . (localtime)
                        . ": Trying to guess \$ALIGNMENT_TOOL_PATH from "
                        . "location of GenomeThreader executable in your "
                        . "\$PATH\n";
                    $logString .= $prtStr if ($v > 1);
                    my $epath = which 'gth';
                    if( defined($epath) ) {
                        if ( -d dirname($epath) ) {
                            $prtStr
                                = "\# "
                                . (localtime)
                                . ": Setting \$ALIGNMENT_TOOL_PATH to "
                                . dirname($epath) . "\n";
                            $logString .= $prtStr if ($v > 1);
                            $ALIGNMENT_TOOL_PATH = dirname($epath);
                        }
                    }
                    else {
                        $prtStr = "#*********\n"
                                . "# WARNING: Guessing the location of "
                                . "\$ALIGNMENT_TOOL_PATH failed / GALBA failed to guess the "
                                . "location of alignment tool with "
                                . "\"which gth\"!\n"
                                . "#*********\n";
                        $logString .= $prtStr if ($v > 0);
                    }
                } elsif ( $prg eq "exonerate" ) {
                    $prtStr
                        = "\# "
                        . (localtime)
                        . ": Trying to guess \$ALIGNMENT_TOOL_PATH from "
                        . "location of Exonerate executable in your \$PATH\n";
                    $logString .= $prtStr if ($v > 1);
                    my $epath = which 'exonerate';
                    if(defined($epath)){
                        if ( -d dirname($epath) ) {
                            $prtStr
                                = "\# "
                                . (localtime)
                                . ": Setting \$ALIGNMENT_TOOL_PATH to "
                                . dirname($epath) . "\n";
                            $logString .= $prtStr if ($v > 1);
                            $ALIGNMENT_TOOL_PATH = dirname($epath);
                        }
                    }
                    else {
                        $prtStr = "#*********\n"
                                . "# WARNING: Guessing the location of "
                                . "\$ALIGNMENT_TOOL_PATH failed / GALBA failed to guess the "
                                . "location of alignment tool with "
                                . "\"which exonerate\"!\n"
                                . "#*********\n";
                        $logString .= $prtStr if ($v > 0);
                    }
                } elsif ( $prg eq "spaln" ) {
                    $prtStr
                        = "\# "
                        . (localtime)
                        . ": Trying to guess \$ALIGNMENT_TOOL_PATH "
                        . "from location of Spaln executable in your \$PATH\n";
                    $logString .= $prtStr if ($v > 1);
                    my $epath = which 'spaln';
                    if(defined($epath)){
                        if ( -d dirname($epath) ) {
                            $prtStr
                                = "\# "
                                . (localtime)
                                . ": Setting \$ALIGNMENT_TOOL_PATH to "
                                . dirname($epath) . "\n";
                            $logString .= $prtStr if ($v > 1);
                            $ALIGNMENT_TOOL_PATH = dirname($epath);
                        }
                    }
                    else {
                        $prtStr = "#*********\n"
                                . "# WARNING: Guessing the location of "
                                . "\$ALIGNMENT_TOOL_PATH failed / GALBA failed to "
                                . "guess the location of alignment tool with "
                                . "\"which spaln\"!\n"
                                . "#*********\n";
                        $logString .= $prtStr if ($v > 0);
                    }
                }
            }
        }

        if ( not( defined($ALIGNMENT_TOOL_PATH) ) ) {
            my $aln_err_str;
            $aln_err_str
                .= "There are 3 alternative ways to set this variable for\n"
                . " galba.pl:\n"
                . "   a) provide command-line argument\n"
                . "      --ALIGNMENT_TOOL_PATH=/your/path\n"
                . "   b) use an existing environment variable\n"
                . "      \$ALIGNMENT_TOOL_PATH for setting the environment\n"
                . "      variable, run\n"
                . "           export ALIGNMENT_TOOL_PATH=/your/path\n"
                . "      in your shell. You may append this to your .bashrc\n"
                . "      or .profile file in order to make the variable\n"
                . "      available to all your bash sessions.\n"
                . "   c) galba.pl can try guessing the location of\n"
                . "      \$ALIGNMENT_TOOL_PATH from the location an alignment\n"
                . "      tool executable (corresponding to the alignment tool\n"
                . "      given by command line argument --prg=yourTool (in\n"
                . "      this case $prg) that is available in your \$PATH\n"
                . "      variable.\n"
                . "      If you try to rely on this option, you can check by\n"
                . "      typing\n"
                . "           which gth\n"
                . "               or\n"
                . "           which exonerate\n"
                . "               or\n"
                . "           which spaln\n"
                . "      in your shell, whether there is an alignment tool\n"
                . "      executable in your \$PATH\n";
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "\$ALIGNMENT_TOOL_PATH not set!\n";
            $logString .= $prtStr;
            $logString .= $aln_err_str if ($v > 1);
            print STDERR $logString;
            exit(1);
        }
    }
}

####################### set_BLAST_or_DIAMOND_PATH ##############################
# * set path to diamond (preferred) or to blastp and formatdb
################################################################################

sub set_BLAST_or_DIAMOND_PATH {
    # first try to set DIAMOND_PATH because that is much faster

    if(not(defined($blast_path))){ # unless blast_path is given explicitely on command line
        # try to get path from ENV
        if ( defined( $ENV{'DIAMOND_PATH'} ) && not (defined($diamond_path)) ) {
            if ( -e $ENV{'DIAMOND_PATH'} ) {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": Found environment variable \$DIAMOND_PATH. Setting "
                    . "\$DIAMOND_PATH to ".$ENV{'DIAMOND_PATH'}."\n";
                $logString .= $prtStr if ($v > 1);
                $DIAMOND_PATH = $ENV{'DIAMOND_PATH'};
            }
        }
        elsif(not(defined($diamond_path))) {
            $prtStr
                = "\# "
                . (localtime)
                . ": Did not find environment variable \$DIAMOND_PATH\n";
            $logString .= $prtStr if ($v > 1);
        }

        # try to get path from command line
        if ( defined($diamond_path) ) {
            my $last_char = substr( $diamond_path, -1 );
            if ( $last_char eq "\/" ) {
                chop($diamond_path);
            }
            if ( -d $diamond_path ) {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": Setting \$DIAMOND_PATH to command line argument "
                    . "--DIAMOND_PATH value $diamond_path.\n";
                $logString .= $prtStr if ($v > 1);
                $DIAMOND_PATH = $diamond_path;
            }
            else {
                $prtStr = "#*********\n"
                        . "# WARNING: Command line argument --DIAMOND_PATH was "
                        . "supplied but value $diamond_path is not a directory. Will not "
                        . "set \$DIAMOND_PATH to $diamond_path!\n"
                        . "#*********\n";
                $logString .= $prtStr if ($v > 0);
            }
        }

        # try to guess
        if ( not( defined($DIAMOND_PATH) )
            || length($DIAMOND_PATH) == 0 )
        {
            $prtStr
                = "\# "
                . (localtime)
                . ": Trying to guess \$DIAMOND_PATH from location of diamond"
                . " executable that is available in your \$PATH\n";
            $logString .= $prtStr if ($v > 1);
            my $epath = which 'diamond';
            if(defined($epath)){
                if ( -d dirname($epath) ) {
                    $prtStr
                        = "\# "
                        . (localtime)
                        . ": Setting \$DIAMOND_PATH to "
                        . dirname($epath) . "\n";
                    $logString .= $prtStr if ($v > 1);
                    $DIAMOND_PATH = dirname($epath);
                }
            }
            else {
                $prtStr = "#*********\n"
                        . "# WARNING: Guessing the location of \$DIAMOND_PATH "
                        . "failed / GALBA failed "
                        . " to detect a diamond binary with \"which diamond\"!\n"
                        . "#*********\n";
                $logString .= $prtStr if ($v > 0);
            }
        }
    }

    if(not(defined($DIAMOND_PATH))){
        # try to get path from ENV
        if ( defined( $ENV{'BLAST_PATH'} ) && not (defined($blast_path)) ) {
            if ( -e $ENV{'BLAST_PATH'} ) {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": Found environment variable \$BLAST_PATH. Setting "
                    . "\$BLAST_PATH to ".$ENV{'BLAST_PATH'}."\n";
                $logString .= $prtStr if ($v > 1);
                $BLAST_PATH = $ENV{'BLAST_PATH'};
            }
        }
        elsif(not(defined($blast_path))) {
            $prtStr
                = "\# "
                . (localtime)
                . ": Did not find environment variable \$BLAST_PATH\n";
            $logString .= $prtStr if ($v > 1);
        }
    }

    # try to get path from command line, overrule $DIAMOND_PATH
    if ( defined($blast_path) ) {
        my $last_char = substr( $blast_path, -1 );
        if ( $last_char eq "\/" ) {
            chop($blast_path);
        }
        if ( -d $blast_path ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": Setting \$BLAST_PATH to command line argument "
                . "--BLAST_PATH value $blast_path.\n";
            $logString .= $prtStr if ($v > 1);
            $BLAST_PATH = $blast_path;
        }
        else {
            $prtStr = "#*********\n"
                    . ": WARNING: Command line argument --BLAST_PATH was "
                    . "supplied but value $blast_path is not a directory. Will not "
                    . "set \$BLAST_PATH to $blast_path!\n"
                    . "#*********\n";
            $logString .= $prtStr if ($v > 0);
        }
    }

    # try to guess
    if(not(defined($DIAMOND_PATH))){
        if ( not( defined($BLAST_PATH) )
            || length($BLAST_PATH) == 0 )
        {
            $prtStr
                = "\# "
                . (localtime)
                . ": Trying to guess \$BLAST_PATH from location of blastp"
                . " executable that is available in your \$PATH\n";
            $logString .= $prtStr if ($v > 1);
            my $epath = which 'blastp';
            if(defined($epath)){
                if ( -d dirname($epath) ) {
                    $prtStr
                        = "\# "
                        . (localtime)
                        . ": Setting \$BLAST_PATH to "
                        . dirname($epath) . "\n";
                    $logString .= $prtStr if ($v > 1);
                    $BLAST_PATH = dirname($epath);
                }
            }
            else {
                $prtStr = "#*********\n"
                        . "# WARNING: Guessing the location of \$BLAST_PATH "
                        . "failed / GALBA failed to "
                        . " detect BLAST with \"which blastp\"!\n"
                        . "#*********\n";
                $logString .= $prtStr if ($v > 0);
            }
        }
    }

    if ( not( defined($BLAST_PATH) ) && not ( defined($DIAMOND_PATH)) ) {
        my $blast_err;
        $blast_err .= "aa2nonred.pl can be exectued either with DIAMOND\n"
                   .  "or with BLAST (much slower than DIAMOND). We recommend\n"
                   .  "using DIAMOND.\n"
                   .  "There are 6 different ways to set one of the required\n"
                   .  "variables \$DIAMOND_PATH or \$BLAST_PATH. Please be\n"
                   .  "aware that you need to set only one of them, not both!\n"
                   .  "   a) provide command-line argument\n"
                   .  "      --DIAMOND_PATH=/your/path\n"
                   .  "   b) use an existing environment variable\n"
                   . "       \$DIAMOND_PATH\n"
                   .  "      for setting the environment variable, run\n"
                   .  "           export DIAMOND_PATH=/your/path\n"
                   .  "      in your shell. You may append this to your "
                   .  ".bashrc or .profile file in\n"
                   .  "      order to make the variable available to all your\n"
                   .  "      bash sessions.\n"
                   .  "   c) aa2nonred.pl can try guessing the location of\n"
                   .  "      \$DIAMOND_PATH from the location of a diamond\n"
                   .  "      executable that is available in your \$PATH\n"
                   .  "      variable. If you try to rely on this option, you\n"
                   . "       can check by typing\n"
                   .  "           which diamond\n"
                   .  "      in your shell, whether there is a diamond\n"
                   .  "      executable in your \$PATH\n"
                   .  "   d) provide command-line argument\n"
                   .  "      --BLAST_PATH=/your/path\n"
                   .  "      This will enforce the usage of BLAST in case you"
                   .  "      have installed both BLAST and DIAMOND\n"
                   .  "   e) use an existing environment variable\n"
                   . "       \$BLAST_PATH\n"
                   .  "      for setting the environment variable, run\n"
                   .  "           export BLAST_PATH=/your/path\n"
                   .  "      in your shell. You may append this to your "
                   .  ".bashrc or .profile file in\n"
                   .  "      order to make the variable available to all your\n"
                   .  "      bash sessions.\n"
                   .  "      GALBA will only check for this variable if it was\n"
                   .  "      previously unable to set a \$DIAMOND_PATH.\n"
                   .  "   f) aa2nonred.pl can try guessing the location of\n"
                   .  "      \$BLAST_PATH from the location of a blastp\n"
                   .  "      executable that is available in your \$PATH\n"
                   .  "      variable. If you try to rely on this option, you\n"
                   .  "      can check by typing\n"
                   .  "           which blastp\n"
                   .  "      in your shell, whether there is a blastp\n"
                   .  "      executable in your \$PATH\n"
                   .  "      GALBA will only try this if it did not find diamond.\n";
        $prtStr = "\# " . (localtime) . " ERROR: in file " . __FILE__
            . " at line ". __LINE__ . "\n" . "\$BLAST_PATH not set!\n";
        $logString .= $prtStr;
        $logString .= $blast_err if ($v > 1);
        print STDERR $logString;
        exit(1);
    }

    if(defined($DIAMOND_PATH) and not(defined($blast_path))){
        if ( not ( -x "$DIAMOND_PATH/diamond" ) ) {
            $prtStr = "\# " . (localtime) . " ERROR: in file " . __FILE__
                ." at line ". __LINE__ ."\n"
                . "$DIAMOND_PATH/diamond is not an executable file!\n";
            $logString .= $prtStr;
            print STDERR $logString;
            exit(1);
        }
    }else{
        if ( not ( -x "$BLAST_PATH/blastp" ) ) {
            $prtStr = "\# " . (localtime) . " ERROR: in file " . __FILE__
                ." at line ". __LINE__ ."\n"
                . "$BLAST_PATH/blastp is not an executable file!\n";
            $logString .= $prtStr;
            print STDERR $logString;
            exit(1);
        }elsif( not ( -x "$BLAST_PATH/makeblastdb" ) ){
            $prtStr = "\# " . (localtime) . " ERROR: in file " . __FILE__
                . " at line ". __LINE__ ."\n"
                . "$BLAST_PATH/makeblastdb is not an executable file!\n";
            $logString .= $prtStr;
            print STDERR $logString;
            exit(1);
        }
    }
}

####################### check_biopython ########################################
# check whether biopython and python module re are available
# (for getAnnoFastaFromJoingenes.py)
################################################################################

sub check_biopython{
    my $missingPython3Module = 0;
    $errorfile = $errorfilesDir."/find_python3_re.err";
    $cmdString = "$PYTHON3_PATH/python3 -c \'import re\' 1> /dev/null 2> "
               . "$errorfile";
    if (system($cmdString) != 0) {
        $prtStr = "#*********\n"
                . "# WARNING: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "Could not find python3 module re:\n";
        open(PYERR, "<", $errorfile) or die ("\# " . (localtime) 
            . " ERROR: in file " . __FILE__
            ." at line ". __LINE__ ."\n"
            . "Could not open file $errorfile!\n");
        while(<PYERR>){
            $prtStr .= $_;
        }
        close(PYERR) or die ("\# " . (localtime) . " ERROR: in file " 
            . __FILE__
            ." at line ". __LINE__ ."\n"
            . "Could not close file $errorfile!\n");
        $prtStr .= "#*********\n";
        $missingPython3Module = 1;
        print LOG $prtStr;
        print STDERR $prtStr;
    }
    $errorfile = $errorfilesDir."/find_python3_biopython.err";
    $cmdString = "$PYTHON3_PATH/python3 -c \'from Bio.Seq import Seq\' 1> /dev/null "
               . "2> $errorfile";
    if (system($cmdString) != 0) {
        $prtStr = "#*********\n"
                . "# WARNING: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "Could not find python3 module biopython:\n";
        open(PYERR, "<", $errorfile) or die ("\# " . (localtime) 
            . " ERROR: in file " . __FILE__
            ." at line ". __LINE__ ."\n"
            . "Could not open file $errorfile!\n");
        while(<PYERR>){
            $prtStr .= $_;
        }
        close(PYERR) or die ("\# " . (localtime) . " ERROR: in file " 
            . __FILE__
            ." at line ". __LINE__ ."\n"
            . "Could not close file $errorfile!\n");
        $prtStr .= "#*********\n";
        print LOG $prtStr;
        print STDERR $prtStr;
        $missingPython3Module = 1;
    }
    if($missingPython3Module == 1) {
        $prtStr = "";
        if (!$skipGetAnnoFromFasta) {
            $prtStr = "\# "
                . (localtime)
                . ": ERROR: GALBA requires the python modules re and "
                . "biopython, at least one of these modules was not found. "
                . "Please install re and biopython or run GALBA with the "
                . "--skipGetAnnoFromFasta option to skip parts of GALBA "
                . "which depend on these modules. See the option's description "
                . "for more details.\n";
        }
        if($makehub) {
            $prtStr .= "\# "
                . (localtime)
                . ": ERROR: MakeHub requires the python modules re and "
                . "biopython, at least one of these modules was not found. "
                . "Please install re and biopython or run GALBA without "
                . "the --makehub option.\n";
        }
        print LOG $prtStr;
        print STDERR $prtStr;
        exit(1);
    }
}

####################### set_PYTHON3_PATH #######################################
# * set path to python3
################################################################################

sub set_PYTHON3_PATH {
    # try to get path from ENV
    if ( defined( $ENV{'PYTHON3_PATH'} ) && not (defined($python3_path)) ) {
        if ( -e $ENV{'PYTHON3_PATH'} ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": Found environment variable \$PYTHON3_PATH. Setting "
                . "\$PYTHON3_PATH to ".$ENV{'PYTHON3_PATH'}."\n";
            $logString .= $prtStr if ($v > 1);
            $PYTHON3_PATH = $ENV{'PYTHON3_PATH'};
        }
    }
    elsif(not(defined($python3_path))) {
        $prtStr
            = "\# "
            . (localtime)
            . ": Did not find environment variable \$PYTHON3_PATH\n";
        $logString .= $prtStr if ($v > 1);
    }

    # try to get path from command line
    if ( defined($python3_path) ) {
        my $last_char = substr( $python3_path, -1 );
        if ( $last_char eq "\/" ) {
            chop($python3_path);
        }
        if ( -d $python3_path ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": Setting \$PYTHON3_PATH to command line argument "
                . "--PYTHON3_PATH value $python3_path.\n";
            $logString .= $prtStr if ($v > 1);
            $PYTHON3_PATH = $python3_path;
        }
        else {
            $prtStr = "#*********\n"
                    . "# WARNING: Command line argument --PYTHON3_PATH was "
                    . "supplied but value $python3_path is not a directory. Will not "
                    . "set \$PYTHON3_PATH to $python3_path!\n"
                    . "#*********\n";
            $logString .= $prtStr if ($v > 0);
        }
    }

    # try to guess
    if ( not( defined($PYTHON3_PATH) )
        || length($PYTHON3_PATH) == 0 )
    {
        $prtStr
            = "\# "
            . (localtime)
            . ": Trying to guess \$PYTHON3_PATH from location of python3"
            . " executable that is available in your \$PATH\n";
        $logString .= $prtStr if ($v > 1);
        my $epath = which 'python3';
        if(defined($epath)){
            if ( -d dirname($epath) ) {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": Setting \$PYTHON3_PATH to "
                    . dirname($epath) . "\n";
                $logString .= $prtStr if ($v > 1);
                $PYTHON3_PATH = dirname($epath);
            }
        }
        else {
            $prtStr = "#*********\n"
                    . "# WARNING: Guessing the location of \$PYTHON3_PATH "
                    . "failed / GALBA failed "
                    . "to detect python3 with \"which python3\"!\n"
                    . "#*********\n";
            $logString .= $prtStr if ($v > 0);
        }
    }

    if ( not( defined($PYTHON3_PATH) ) ) {
        my $python_err;
        $python_err .= "Python3 was not found. You have 3 different options\n"
                    .  "to provide a path to python3 to galba.pl:\n"
                    .  "   a) provide command-line argument\n"
                    .  "          --PYTHON3_PATH=/your/path\n"
                    .  "   b) use an existing environment variable\n"
                    .  "          \$PYTHON3_PATH\n"
                    .  "      for setting the environment variable, run\n"
                    .  "          export PYTHON3_PATH=/your/path\n"
                    .  "      in your shell. You may append this to your\n"
                    .  "      .bashrc or .profile file in order to make the\n"
                    .  "      variable available to all your bash sessions.\n"
                    .  "   c) galba.pl can try guessing the location of\n"
                    .  "      \$PYTHON3_PATH from the location of a python3\n"
                    .  "      executable that is available in your \$PATH\n"
                    .  "      variable. If you try to rely on this option, you\n"
                    .  "      can check by typing\n"
                    .  "          which python3\n"
                    .  "      in your shell, whether there is a python3\n"
                    .  "      executable in your \$PATH\n";
        $prtStr = "\# " . (localtime) . " ERROR: in file " . __FILE__
            . " at line ". __LINE__ . "\n" . "\$PYTHON3_PATH not set!\n";
        $logString .= $prtStr;
        $logString .= $python_err if ($v > 1);
        print STDERR $logString;
        exit(1);
    }
    if ( not ( -x "$PYTHON3_PATH/python3" ) ) {
        $prtStr = "\# " . (localtime) . " ERROR: in file " . __FILE__
            ." at line ". __LINE__ ."\n"
            . "$PYTHON3_PATH/python3 is not an executable file!\n";
        $logString .= $prtStr;
        print STDERR $logString;
        exit(1);
    }
}

####################### set_CDBTOOLS_PATH #######################################
# * set path to cdbfasta/cdbyank
################################################################################

sub set_CDBTOOLS_PATH {
    # try to get path from ENV
    if ( defined( $ENV{'CDBTOOLS_PATH'} ) && not (defined($cdbtools_path)) ) {
        if ( -e $ENV{'CDBTOOLS_PATH'} ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": Found environment variable \$CDBTOOLS_PATH. Setting "
                . "\$CDBTOOLS_PATH to ".$ENV{'CDBTOOLS_PATH'}."\n";
            $logString .= $prtStr if ($v > 1);
            $CDBTOOLS_PATH = $ENV{'CDBTOOLS_PATH'};
        }
    }elsif(not(defined($cdbtools_path))) {
        $prtStr
            = "\# "
            . (localtime)
            . ": Did not find environment variable \$CDBTOOLS_PATH\n";
        $logString .= $prtStr if ($v > 1);
    }

    # try to get path from command line
    if ( defined($cdbtools_path) ) {
        my $last_char = substr( $cdbtools_path, -1 );
        if ( $last_char eq "\/" ) {
            chop($cdbtools_path);
        }
        if ( -d $cdbtools_path ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": Setting \$CDBTOOLS_PATH to command line argument "
                . "--CDBTOOLS_PATH value $cdbtools_path.\n";
            $logString .= $prtStr if ($v > 1);
            $CDBTOOLS_PATH = $cdbtools_path;
        }
        else {
            $prtStr = "#*********\n"
                    . "# WARNING: Command line argument --CDBTOOLS_PATH was "
                    . "supplied but value $cdbtools_path is not a directory. Will not "
                    . "set \$CDBTOOLS_PATH to $cdbtools_path!\n"
                    . "#*********\n";
            $logString .= $prtStr if ($v > 0);
        }
    }

    # try to guess
    if ( not( defined($CDBTOOLS_PATH) )
        || length($CDBTOOLS_PATH) == 0 )
    {
        $prtStr
            = "\# "
            . (localtime)
            . ": Trying to guess \$CDBTOOLS_PATH from location of cdbfasta"
            . " executable that is available in your \$PATH\n";
        $logString .= $prtStr if ($v > 1);
        my $epath = which 'cdbfasta';
        if(defined($epath)){
            if ( -d dirname($epath) ) {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": Setting \$CDBTOOLS_PATH to "
                    . dirname($epath) . "\n";
                $logString .= $prtStr if ($v > 1);
                $CDBTOOLS_PATH = dirname($epath);
            }
        }
        else {
            $prtStr = "#*********\n"
                    . "# WARNING: Guessing the location of \$CDBTOOLS_PATH "
                    . "failed / GALBA failed "
                    . "to detect cdbfasta with \"which cdbfasta\"!\n"
                    . "#*********\n";
            $logString .= $prtStr if ($v > 0);
        }
    }

    if ( not( defined($CDBTOOLS_PATH) ) ) {
        my $cdbtools_err;
        $cdbtools_err .= "cdbfasta and cdbyank are required for fixing AUGUSTUS "
                    .  "genes with in frame stop codons using the script "
                    .  "fix_in_frame_stop_codon_genes.py.\n"
                    .  "You can skip execution of fix_in_frame_stop_codon_genes.py\n"
                    .  "with the galba.pl by providing the command line flag\n"
                    .  "--skip_fixing_broken_genes.\n"
                    .  "If you don't want to skip it, you have 3 different "
                    .  "options to provide a path to cdbfasta/cdbyank to galba.pl:\n"
                    .  "   a) provide command-line argument\n"
                    .  "      --CDBTOOLS_PATH=/your/path\n"
                    .  "   b) use an existing environment variable\n"
                    . "       \$CDBTOOLS_PATH\n"
                    .  "      for setting the environment variable, run\n"
                    .  "           export CDBTOOLS_PATH=/your/path\n"
                    .  "      in your shell. You may append this to your "
                    .  ".bashrc or .profile file in\n"
                    .  "      order to make the variable available to all your\n"
                    .  "      bash sessions.\n"
                    .  "   c) galba.pl can try guessing the "
                    .  "      \$CDBTOOLS_PATH from the location of a cdbfasta\n"
                    .  "      executable that is available in your \$PATH\n"
                    .  "      variable. If you try to rely on this option, you\n"
                    . "       can check by typing\n"
                    .  "           which cdbfasta\n"
                    .  "      in your shell, whether there is a cdbfasta\n"
                    .  "      executable in your \$PATH\n";
        $prtStr = "\# " . (localtime) . " ERROR: in file " . __FILE__
            . " at line ". __LINE__ . "\n" . "\$CDBTOOLS_PATH not set!\n";
        $logString .= $prtStr;
        $logString .= $cdbtools_err if ($v > 1);
        print STDERR $logString;
        exit(1);
    }
    if ( not ( -x "$CDBTOOLS_PATH/cdbfasta" ) ) {
        $prtStr = "\# " . (localtime) . " ERROR: in file " . __FILE__
            ." at line ". __LINE__ ."\n"
            . "$CDBTOOLS_PATH/cdbfasta is not an executable file!\n";
        $logString .= $prtStr;
        print STDERR $logString;
        exit(1);
    }elsif ( not ( -x "$CDBTOOLS_PATH/cdbyank" ) ) {
        $prtStr = "\# " . (localtime) . " ERROR: in file " . __FILE__
            ." at line ". __LINE__ ."\n"
            . "$CDBTOOLS_PATH/cdbyank is not an executable file!\n";
        $logString .= $prtStr;
        print STDERR $logString;
        exit(1);
    }
}


####################### set_MAKEHUB_PATH #######################################
# * set path to make_hub.py
################################################################################

sub set_MAKEHUB_PATH {
    # try to get path from ENV
    if ( defined( $ENV{'MAKEHUB_PATH'} ) && not (defined($makehub_path)) ) {
        if ( -e $ENV{'MAKEHUB_PATH'} ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": Found environment variable \$MAKEHUB_PATH. Setting "
                . "\$MAKEHUB_PATH to ".$ENV{'MAKEHUB_PATH'}."\n";
            $logString .= $prtStr if ($v > 1);
            $MAKEHUB_PATH = $ENV{'MAKEHUB_PATH'};
        }
    }elsif(not(defined($makehub_path))) {
        $prtStr
            = "\# "
            . (localtime)
            . ": Did not find environment variable \$MAKEHUB_PATH\n";
        $logString .= $prtStr if ($v > 1);
    }

    # try to get path from command line
    if ( defined($makehub_path) ) {
        my $last_char = substr( $makehub_path, -1 );
        if ( $last_char eq "\/" ) {
            chop($makehub_path);
        }
        if ( -d $makehub_path ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": Setting \$MAKEHUB_PATH to command line argument "
                . "--MAKEHUB_PATH value $makehub_path.\n";
            $logString .= $prtStr if ($v > 1);
            $MAKEHUB_PATH = $makehub_path;
        }
        else {
            $prtStr = "#*********\n"
                    . "# WARNING: Command line argument --MAKEHUB_PATH was "
                    . "supplied but value $makehub_path is not a directory. Will not "
                    . "set \$MAKEHUB_PATH to $makehub_path!\n"
                    . "#*********\n";
            $logString .= $prtStr if ($v > 0);
        }
    }

    # try to guess
    if ( not( defined($MAKEHUB_PATH) )
        || length($MAKEHUB_PATH) == 0 )
    {
        $prtStr
            = "\# "
            . (localtime)
            . ": Trying to guess \$MAKEHUB_PATH from location of make_hub.py"
            . " executable that is available in your \$PATH\n";
        $logString .= $prtStr if ($v > 1);
        my $epath = which 'make_hub.py';
        if(defined($epath)){
            if ( -d dirname($epath) ) {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": Setting \$MAKEHUB_PATH to "
                    . dirname($epath) . "\n";
                $logString .= $prtStr if ($v > 1);
                $MAKEHUB_PATH = dirname($epath);
            }
        }
        else {
            $prtStr = "#*********\n"
                    . "# WARNING: Guessing the location of \$MAKEHUB_PATH "
                    . "failed / GALBA failed "
                    . "to detect make_hub.py with \"which make_hub.py\"!\n"
                    . "#*********\n";
            $logString .= $prtStr if ($v > 0);
        }
    }

    if ( not( defined($MAKEHUB_PATH) ) ) {
        my $makehub_err;
        $makehub_err .= "make_hub.py is required for generating track data\n"
                    .  "hubs for visualizing gene predictions with the UCSC\n"
                    .  "Genome Browser. You can skip execution of make_hub.py\n"
                    .  "with the galba.pl by not providing the command line flag\n"
                    .  "--makehub.\n"
                    .  "If you don't want to skip it, you have 3 different "
                    .  "options to provide a path to make_hub.py to galba.pl:\n"
                    .  "   a) provide command-line argument\n"
                    .  "      --MAKEHUB_PATH=/your/path\n"
                    .  "   b) use an existing environment variable\n"
                    . "       \$MAKEHUB_PATH\n"
                    .  "      for setting the environment variable, run\n"
                    .  "           export MAKEHUB_PATH=/your/path\n"
                    .  "      in your shell. You may append this to your "
                    .  ".bashrc or .profile file in\n"
                    .  "      order to make the variable available to all your\n"
                    .  "      bash sessions.\n"
                    .  "   c) galba.pl can try guessing the location of\n"
                    .  "      \$MAKEHUB_PATH from the location of a make_hub.py\n"
                    .  "      executable that is available in your \$PATH\n"
                    .  "      variable. If you try to rely on this option, you\n"
                    . "       can check by typing\n"
                    .  "           which make_hub.py\n"
                    .  "      in your shell, whether there is a make_hub.py\n"
                    .  "      executable in your \$PATH\n";
        $prtStr = "\# " . (localtime) . " ERROR: in file " . __FILE__
            . " at line ". __LINE__ . "\n" . "\$MAKEHUB_PATH not set!\n";
        $logString .= $prtStr;
        $logString .= $makehub_err if ($v > 1);
        print STDERR $logString;
        exit(1);
    }
    if ( not ( -x "$MAKEHUB_PATH/make_hub.py" ) ) {
        $prtStr = "\# " . (localtime) . " ERROR: in file " . __FILE__
            ." at line ". __LINE__ ."\n"
            . "$MAKEHUB_PATH/make_hub.py is not an executable file!\n";
        $logString .= $prtStr;
        print STDERR $logString;
        exit(1);
    }
}

####################### check_upfront ##########################################
# * check for scripts, perl modules, executables, extrinsic config files
################################################################################

sub check_upfront {

    # check whether required perl modules are installed
    my $pmodule;
    my @module_list = (
        "YAML",           "Hash::Merge",
        "MCE::Mutex", "Parallel::ForkManager",
        "Scalar::Util::Numeric", "Getopt::Long",
        "File::Compare", "File::Path", "Module::Load::Conditional",
        "Scalar::Util::Numeric", "POSIX", "List::Util",
        "FindBin", "File::Which", "Cwd", "File::Spec::Functions",
        "File::Basename", "File::Copy", "Term::ANSIColor",
        "strict", "warnings",
        "Math::Utils"
    );

    foreach my $module (@module_list) {
        $pmodule = check_install( module => $module );
        if ( !$pmodule ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "Perl module '$module' is required but not installed yet.\n";
            $logString .= $prtStr;
            print STDERR $logString;
            exit(1);
        }
    }

    # check for augustus executable
    $augpath = "$AUGUSTUS_BIN_PATH/augustus";
    if ( system("$augpath > /dev/null 2> /dev/null") != 0 ) {
        if ( !-f $augpath ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "augustus executable not found at $augpath.\n";
            $logString .= $prtStr;
        }
        else {
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "$augpath not executable on this machine.\n";
            $logString .= $prtStr;
        }
        print STDERR $logString;
        exit(1);
    }

    # check for joingenes executable
    $augpath = "$AUGUSTUS_BIN_PATH/joingenes";
    if ( not (-x $augpath ) or not (-e $augpath ) ) {
        if ( !-f $augpath ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "joingenes executable not found at $augpath. Please compile "
                . "joingenes (augustus/auxprogs/joingenes)!\n";
            $logString .= $prtStr;
        }
        elsif(! -x $augpath){
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "$augpath not executable on this machine.  Please compile "
                . "joingenes (augustus/auxprogs/joingenes)!n";
            $logString .= $prtStr;
        }
        print STDERR $logString;
        exit(1);
    }

    # check for etraining executable
    my $etrainpath;
    $etrainpath = "$AUGUSTUS_BIN_PATH/etraining";
    if ( system("$etrainpath > /dev/null 2> /dev/null") != 0 ) {
        if ( !-f $etrainpath ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "etraining executable not found at $etrainpath.\n";
            $logString .= $prtStr;
        }
        else {
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "$etrainpath not executable on this machine.\n";
            $logString .= $prtStr;
        }
        print STDERR $logString;
        exit(1);
    }

    if(@prot_aln_files) {
        $foundProt++;
    }

    # check for alignment executable and in case of SPALN for environment variables
    my $prot_aligner;
    if (@prot_seq_files && defined($prg)) {
        if ( $prg eq 'gth' ) {
            $prot_aligner = "$ALIGNMENT_TOOL_PATH/gth";
            if ( !-f $prot_aligner ) {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                    . "GenomeThreader executable not found at $prot_aligner.\n";
                $logString .= $prtStr;
                print STDERR $logString;
                exit(1);
            }
            elsif ( !-x $prot_aligner ) {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                    . "$prot_aligner not executable on this machine.\n";
                $logString .= $prtStr;
                print STDERR $logString;
                exit(1);
            }
        }
        elsif ( $prg eq 'spaln' ) {
            $prot_aligner = "$ALIGNMENT_TOOL_PATH/spaln";
            if ( !-f $prot_aligner ) {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                    . "Spaln executable not found at $prot_aligner.\n";
                $logString .= $prtStr;
                print STDERR $logString;
                exit(1);
            }
            elsif ( !-x $prot_aligner ) {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                    . "$prot_aligner not executable on this machine.\n";
                $logString .= $prtStr;
                print STDERR $logString;
                exit(1);
            }

            # check whether spaln environment variables are configured
            if ( !$ENV{'ALN_DBS'} or !$ENV{'ALN_TAB'} ) {
                if ( !$ENV{'ALN_DBS'} ) {
                    $prtStr
                        = "\# "
                        . (localtime)
                        . ": ERROR: in file " . __FILE__ ." at line "
                        . __LINE__ . "\n"
                        . "The environment variable ALN_DBS for spaln is not "
                        . "defined. Please export an environment variable "
                        . "with: 'export ALN_DBS=/path/to/spaln/seqdb'\n";
                    $logString .= $prtStr;
                }
                if ( !$ENV{'ALN_TAB'} ) {
                    $prtStr
                        = "\# "
                        . (localtime)
                        . ": ERROR: in file " . __FILE__ ." at line "
                        . __LINE__ ."\n" . "The environment variable ALN_TAB "
                        . "for spaln is not defined. Please export an "
                        . "environment variable with: "
                        . "'export ALN_TAB=/path/to/spaln/table'\n";
                    $logString .= $prtStr;
                }
                print STDERR $logString;
                exit(1);
            }
        }
        elsif ( $prg eq 'exonerate' ) {
            $prot_aligner = "$ALIGNMENT_TOOL_PATH/exonerate";
            if ( !-f $prot_aligner ) {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                    . "Exonerate executable not found at $prot_aligner.\n";
                $logString .= $prtStr;
                print STDERR $logString;
                exit(1);
            }
            elsif ( !-x $prot_aligner ) {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                    . "$prot_aligner not executable on this machine.\n";
                $logString .= $prtStr;
                print STDERR $logString;
                exit(1);
            }
        }
    }

    # check whether the necessary perl scripts exist and can be found
    find(
        "gff2gbSmallDNA.pl",    $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    if($lambda){
        find(
        "downsample_traingenes.pl",    $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    }
    find(
        "new_species.pl",       $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    find(
        "filterGenesIn_mRNAname.pl", $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH,      $AUGUSTUS_CONFIG_PATH
    );
    find(
        "filterGenes.pl", $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH,      $AUGUSTUS_CONFIG_PATH
    );
    find(
        "filterGenesIn.pl", $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH,      $AUGUSTUS_CONFIG_PATH
    );
    find(
        "join_mult_hints.pl",   $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    find(
        "aa2nonred.pl", $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH,      $AUGUSTUS_CONFIG_PATH
    );
    find(
        "randomSplit.pl",       $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    find(
        "optimize_augustus.pl", $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    find(
        "join_aug_pred.pl",     $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    find(
        "getAnnoFastaFromJoingenes.py", $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
      );
    if($UTR eq "on"){
        find(
            "bamToWig.py", $AUGUSTUS_BIN_PATH,
            $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
        );
    }
    find(
        "gtf2gff.pl",           $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    find(
        "startAlign.pl",        $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    find(
        "align2hints.pl",       $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    find(
        "splitMfasta.pl",       $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    find(
        "createAugustusJoblist.pl",       $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    find(
        "gtf2gff.pl",       $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    find(
        "fix_joingenes_gtf.pl",       $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    find(
        "merge_transcript_sets.pl", $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    if(not($skip_fixing_broken_genes)){
        find(
            "fix_in_frame_stop_codon_genes.py", $AUGUSTUS_BIN_PATH,
            $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
        );
    }
    if(defined($annot)){
        find(
            "compare_intervals_exact.pl", $AUGUSTUS_BIN_PATH,
            $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
        );
        find(
            "compute_accuracies.sh", $AUGUSTUS_BIN_PATH,
            $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
        );
    }

    # check whether all extrinsic cfg files are available
    find_ex_cfg ("cfg/gth.cfg");

    # check whether provided translation table is compatible
    # GALBA has only been implemented to alter to nuclear code
    # tables, instead of table 1 ...\
    if(not($ttable eq 1)){
        if(not($ttable =~ m/^(6|10|12|25|26|27|28|29|30|31)$/)){
            $prtStr = "\# "
                    . (localtime)
                    . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                    . "GALBA is only compatible with translation tables " 
                  . "1, 6, 10, 12, 25, 26, 27, 28, 29, 30, 31. You "
                  . "specified table " + $ttable + ".\n";
                $logString .= $prtStr;
                print STDERR $logString;
                exit(1);
        }
    }
    # check for bamToWig.py required UCSC tools
    if( $UTR eq "on" ){
        if ( system("which twoBitInfo > /dev/null") != 0 ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": WARNING: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "twoBitInfo not installed. "
                . "It is available at http://hgdownload.soe.ucsc.edu/admin/exe "
                . "and should be added to your \$PATH. bamToWig.py will "
                . "automatically download this tool to the working directory but "
                . "permanent global installation is recommended.\n";
            $logString .= $prtStr;
            print STDERR $logString;
        }
        if ( system("which faToTwoBit > /dev/null") != 0 ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": WARNING: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "faToTwoBit not installed. "
                . "It is available at http://hgdownload.soe.ucsc.edu/admin/exe "
                . "and should be added to your \$PATH. bamToWig.py will "
                . "automatically download this tool to the working directory but "
                . "permanent global installation is recommended.\n";
            $logString .= $prtStr;
            print STDERR $logString;
        }
    }
}

####################### find_ex_cfg ############################################
# * find extrinsic config file
################################################################################

sub find_ex_cfg {
    my $thisCfg = shift;
    $string = find( $thisCfg, $AUGUSTUS_BIN_PATH, $AUGUSTUS_SCRIPTS_PATH,
        $AUGUSTUS_CONFIG_PATH );
    if ( not ( -e $string ) ) {
        $prtStr
            = "\# "
            . (localtime)
            . " ERROR: tried to find GALBA's extrinsic.cfg file $thisCfg "
            . "$string but this file does not seem to exist.\n";
        $logString .= $prtStr;
        print STDERR $logString;
        exit(1);
    }
}

####################### check_gff ##############################################
# * check that user provided hints file is in valid gff format
# * check that hints file only contains supported hint types (extrinsic.cfg)
#   compatibility
################################################################################

sub check_gff {
    my $gfffile = shift;
    $prtStr
        = "\# "
        . (localtime)
        . ": Checking if input file $gfffile is in gff format\n";
    $logString .= $prtStr if ($v > 2);
    open( GFF, $gfffile ) or die ( "ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nCannot open file: $gfffile\n" );
    my $printedAllowedHints = 0;
    my %foundFeatures;

    my $gffC = 0;
    while (<GFF>) {
        $gffC++;
        my @gff_line = split( /\t/, $_ );
        if ( scalar(@gff_line) != 9 ) {
            $prtStr
                = "\# "
                . (localtime)
                . " ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "File $gfffile is not in gff format at line $gffC!\n";
            $logString .= $prtStr;
            print STDERR $logString;
            close(GFF) or die("ERROR in file " . __FILE__ ." at line "
                . __LINE__ ."\nCould not close gff file $gfffile!\n");
            exit(1);
        }
        else {
            if (   !isint( $gff_line[3] )
                || !isint( $gff_line[4] )
                || $gff_line[5] =~ m/[^\d\.]/g
                || $gff_line[6] !~ m/[\+\-\.]/
                || length( $gff_line[6] ) != 1
                || $gff_line[7] !~ m/[0-2\.]{1}/
                || length( $gff_line[7] ) != 1 )
            {
                $prtStr
                    = "\# "
                    . (localtime)
                    . " ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                    . "File $gfffile is not in gff format!\n";
                $logString .= $prtStr;
                print STDERR $logString;
                close(GFF) or die("ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nCould not close gff file $gfffile!\n");
                exit(1);
            }
        }

        # if no extrinsic.cfg is specified, parameters in galba.pl written
        # extrinsic.cfg correspond to hints in @allowedHints, only; other
        # hints will be treated with neutral malus/bonus. Issue corresponding
        # warning.
        if ( not( defined($extrinsicCfgFile) ) ) {
            my $isAllowed = 0;
            foreach (@allowedHints) {
                if ( $gff_line[2] eq $_ ) {
                    $isAllowed = 1;
                }
            }
            if ( $isAllowed != 1 ) {
                if ( not( defined( $foundFeatures{ $gff_line[2] } ) ) ) {
                    $prtStr = "#*********\n"
                            . "# WARNING: File $gfffile contains hints of a feature "
                            . "type $gff_line[2] that is currently not supported "
                            . "by GALBA. Features of this type will be treated "
                            . "with neutral bonus/malus in the extrinsic.cfg file "
                            . "that will be used for running AUGUSTUS.\n"
                            . "#*********\n";
                    $logString .= $prtStr if ( $v > 0 );
                    $foundFeatures{ $gff_line[2] } = 1;
                }
                if ( $printedAllowedHints == 0 ) {
                    $prtStr = "Currently allowed hint types:\n";
                    $logString .= $prtStr if ( $v > 0 );
                    foreach (@allowedHints) {
                        $prtStr = $_ . "\n";
                        $logString .= $prtStr if ( $v > 0 );
                    }
                    $printedAllowedHints = 1;
                }
            }
        }
    }
    close(GFF) or die("ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nCould not close gff file $gfffile!\n");
}

####################### check_options ##########################################
# * check that command line options are set, correctly
################################################################################

sub check_options {

    # Set implicit options:
    if ($skipAllTraining) {
        $useexisting = 1;
    }

    if ($trainFromGth) {
        $gth2traingenes = 1;
    }

    if ($skipAllTraining) {
        $skipoptimize = 1;
    }

    if (   $alternatives_from_evidence ne "true"
        && $alternatives_from_evidence ne "false" )
    {
        $prtStr
            = "\# "
            . (localtime)
            . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
            . "\"$alternatives_from_evidence\" is not a valid option for "
            . "--alternatives-from-evidence. Please use either 'true' or "
            . "'false'.\n";
        print STDERR $prtStr;
        $logString .= $prtStr;
        exit(1);
    }

    my $cpus_available = `getconf _NPROCESSORS_ONLN`;

    if ( $cpus_available < $CPU ) {
        $prtStr = "#*********\n" 
                . "# WARNING: Your system does not have $CPU cores available, "
                . "only $cpus_available. GALBA will use the $cpus_available "
                . " available instead of the chosen $CPU.\n"
                . "#*********\n";
        $logString .= $prtStr if ($v > 0);
    }

    # check whether hints files exists
    if (@hints) {
        for ( my $i = 0; $i < scalar(@hints); $i++ ) {
            if ( !-e "$hints[$i]" ) {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": ERROR: in file " . __FILE__ ." at line ". __LINE__
                    ."\nHints file $hints[$i] does not exist.\n";
                $logString .= $prtStr;
                print STDERR $logString;
                exit(1);
            }
            check_gff( $hints[$i] );
        }
    }

    # check whether a valid set of input files is provided
    if (!$foundProt && !$skipAllTraining) {
            $prtStr = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "# In addition to a genome file, galba.pl requires at "
                . "least one of the following files/flags as input:\n"
                . "    --hints=file.hints\n"
                . "    --prot_seq=file.fa\n"
                . "    --prot_aln=file.aln\n";
            $logString .= $prtStr;
            print STDERR $logString;
            exit(1);
    }

    # check whether species is specified
    if ( defined($species) ) {
        if ( $species =~ /[\s]/ ) {
            $prtStr = "#*********\n"
                ."# WARNING: Species name contains invalid white space "
                . "characters. Will replace white spaces with underline "
                . "character '_'.\n"
                . "#*********\n";
            $logString .= $prtStr if ($v > 0);
            $species =~ s/\s/\_/g;
        }
        foreach my $word (@forbidden_words) {
            if ( $species eq $word ) {
                $prtStr = "#*********\n"
                        . "# WARNING: $species is not allowed as a species name.\n"
                        . "#*********\n";
                $logString .= $prtStr if ($v > 0);
                $bool_species = "false";
            }
        }
    }

    # use standard name when no name is assigned or when it contains invalid parts
    if ( !defined($species) || $bool_species eq "false" ) {
        my $no = 1;
        $species = "Sp_$no";
        while ( $no <= $limit ) {
            $species = "Sp_$no";
            if ( ( !-d "$AUGUSTUS_CONFIG_PATH/species/$species" ) ) {
                last;
            }
            else {
                $no++;
            }
        }
        if ( $no > $limit ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "There are already $limit species folders under "
                . "$AUGUSTUS_CONFIG_PATH/species/ of type 'Sp_$limit'. "
                . "Please delete or move some of those folders or assign a "
                . "valid species identifier with --species=name.\n";
            $logString .= $prtStr;
            print STDERR $logString;
            exit(1);
        }
        if ( $bool_species eq "false" ) {
            $prtStr = "\# " . (localtime) . ": Program will use $species instead.\n";
            $logString .= $prtStr if ($v > 0);
        }
        else {
            $prtStr
                = "#*********\n"
                . "# IMPORTANT INFORMATION: no species for identifying the AUGUSTUS "
                . " parameter set that will arise from this GALBA run was set. GALBA "
                . "will create an AUGUSTUS parameter set with name $species. "
                . "This parameter set can be used for future GALBA/AUGUSTUS prediction "
                . "runs for the same species. It is usually not necessary to retrain "
                . "AUGUSTUS with novel extrinsic data if a high quality parameter "
                . "set already exists.\n"
                . "#*********\n";
            $logString .= $prtStr if ($v > 0);
        }
    }

    # check species directory
    if ( -d "$AUGUSTUS_CONFIG_PATH/species/$species" && !$useexisting ) {
        $prtStr
            = "\# "
            . (localtime)
            . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
            . "$AUGUSTUS_CONFIG_PATH/species/$species already exists. "
            . "Choose another species name, delete this directory or use the "
            . "existing species with the option --useexisting. Be aware that "
            . "existing parameters will then be overwritten during training.\n";
        $logString .= $prtStr;
        print STDERR $logString;
        exit(1);
    }

    if ( !-d "$AUGUSTUS_CONFIG_PATH/species/$species" && $useexisting ) {
        $prtStr = "#*********\n"
                . "# WARNING: $AUGUSTUS_CONFIG_PATH/species/$species does not "
                . "exist. GALBA will create the necessary files for species "
                . "$species.\n"
                . "#*********\n";
        $logString .= $prtStr if($v > 0);
        $useexisting = 0;
    }


    # set extrinsic.cfg files if provided
    if (@extrinsicCfgFiles) {
        my $exLimit;
        $exLimit = 1;
        if( scalar(@extrinsicCfgFiles) < ($exLimit+1) ) {
            for(my $i = 0; $i < scalar(@extrinsicCfgFiles); $i++ ) {
                if(-f $extrinsicCfgFiles[$i]) {
                    if($i == 0) {
                        $extrinsicCfgFile1 = $extrinsicCfgFiles[$i];
                    }elsif($i==1){
                        $extrinsicCfgFile2 = $extrinsicCfgFiles[$i];
                    }elsif($i==2){
                        $extrinsicCfgFile3 = $extrinsicCfgFiles[$i];
                    }elsif($i==3){
                        $extrinsicCfgFile4 = $extrinsicCfgFiles[$i];
                    }
                }else{
                    $prtStr = "\# " . (localtime)
                            . ": ERROR: specified extrinsic.cfg file "
                            . "$extrinsicCfgFiles[$i] does not exist!\n";
                    $logString .= $prtStr;
                    print STDERR $logString;
                    exit(1);
                }
            }
        }else{
            $prtStr = "\# "
                . (localtime)
                . ": ERROR: too many extrinsic.cfg files provided!\n";
                $logString .= $prtStr;
                print STDERR $logString;
                exit(1);
        }
    }

    # check whether genome file is set
    if ( !defined($genome) ) {
        $prtStr
            = "\# " . (localtime) . ": ERROR: in file " . __FILE__
            ." at line ". __LINE__ ."\nNo genome file was specified.\n";
        $logString .= $prtStr;
        print STDERR $logString;
        exit(1);
    }

    # check whether protein sequence file is given
    if (@prot_seq_files) {
        for ( my $i = 0; $i < scalar(@prot_seq_files); $i++ ) {
            if ( !-f $prot_seq_files[$i] ) {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                    . "protein sequence file $prot_seq_files[$i] does "
                    . "not exist.\n";
                $logString .= $prtStr;
                print STDERR $logString;
                exit(1);
            }
        }

        if ( !defined($prg)) {
            $prtStr = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "# No alignment tool was specified for aligning protein "
                . "sequences against genome.\n";
            $logString .= $prtStr;
            print STDERR $logString;
            exit(1);
        }
    }

    # check whether reference annotation file exists
    if ($annot) {
        if ( not( -e $annot ) ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "Reference annotation file $annot does not exist. Cannot "
                . "evaluate prediction accuracy!\n";
            $logString .= $prtStr;
            print STDERR $logString;
            exit(1);
        }
    }

    # check whether protein alignment file is given
    if (@prot_aln_files) {
        for ( my $i = 0; $i < scalar(@prot_aln_files); $i++ ) {
            if ( !-f $prot_aln_files[$i] ) {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": ERROR: in file " . __FILE__ ." at line ". __LINE__
                    ."\nprotein alignment file $prot_aln_files[$i] does"
                    . " not exist.\n";
            $logString .= $prtStr;
            print STDERR $logString;
                exit(1);
            }
        }
        if ( !defined($prg) ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "if protein alignment file is specified, you must "
                . "specify the source tool that was used to create that "
                . "alignment file, i.e. --prg=gth for GenomeThreader.\n";
            $logString .= $prtStr;
            print STDERR $logString;
            exit(1);
        }
    }

    # check whether a valid alignment program is given
    if ( defined($prg) ) {
        if (    not( $prg =~ m/gth/ )
            and not( $prg =~ m/miniprot/ ))
        {
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "# An alignment tool other than gth and miniprot "
                . "has been specified with option --prg=$prg.\n";
            $logString .= $prtStr;
            print STDERR $logString;
            exit(1);
        }
        if ( (!@prot_seq_files and !@prot_aln_files) and not($skipAllTraining) ) {
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "a protein alignment tool ($prg) has been given, "
                . "but neither a protein sequence file, nor a protein "
                . "alignment file generated by such a tool have been "
                . "specified.\n";
            $logString .= $prtStr;
            print STDERR $logString;
            exit(1);
        }
    }

    # check whether trainFromGth option is valid
    if ( defined($gth2traingenes) && not( $prg eq "gth" ) ) {
        $prtStr
            = "\# "
            . (localtime)
            . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
            . "Option --gth2traingenes can only be specified with "
            . "option --prg=gth!\n";
        $logString .= $prtStr;
        print STDERR $logString;
        exit(1);
    } elsif ( defined($trainFromGth) && not( $prg eq "gth" ) ) {
        $prtStr
            = "\# "
            . (localtime)
            . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
            . "Option --trainFromGth can only be specified with "
            . "option --prg=gth!\n";
        $logString .= $prtStr;
        print STDERR $logString;
        exit(1);
    }

    if ( !-f "$genome" ) {
        $prtStr
            = "\# "
            . (localtime)
            . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
            . "Genome file $genome does not exist.\n";
        $logString .= $prtStr;
        print STDERR $logString;
        exit(1);
    }

    if (!$skip_fixing_broken_genes && $skipGetAnnoFromFasta) {
        $prtStr
            = "\# "
            . (localtime)
            . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
            . "# GALBA needs to run the getAnnoFastaFromJoingenes.py script "
            . "to fix genes with in-frame stop codons. If you wish to use the "
            . "--skipGetAnnoFromFasta option, turn off the fixing of stop "
            . "codon including genes with the --skip_fixing_broken_genes "
            . "option.\n";
        $logString .= $prtStr;
        print STDERR $logString;
        exit(1);
    }

    if ($makehub && not($email)){
        $prtStr
            = "\# "
            . (localtime)
            . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
            . "If --makehub option is used, --email argument value must be provided.\n";
        $logString .= $prtStr;
        print STDERR $logString;
        exit(1);
    } elsif (not($makehub) && $email) {
        $prtStr = "#*********\n"
                . "# WARNING: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "If --email option will only take effect in combination with --makehub option.\n"
                . "#*********\n";
        $logString .= $prtStr;
        print STDOUT $logString;
    }
}

####################### check_fasta_headers ####################################
# * check fasta headers (long and complex headers may cause problems)
# * tries to fix genome fasta files
# * only warns about portein fasta files
################################################################################

sub check_fasta_headers {
    my $fastaFile                = shift;
    my $genome_true              = shift;
    my $someThingWrongWithHeader = 0;
    my $spaces                   = 0;
    my $orSign                   = 0;
    my $emptyC                   = 0;
    my $wrongNL                  = 0;
    my $prot                     = 0;
    my $dna                      = 0;
    my $scaffName;
    my $mapFile = "$otherfilesDir/genome_header.map";
    my $stdStr = "This may later on cause problems! The pipeline will create "
               . "a new file without spaces or \"|\" characters and a "
               . "genome_header.map file to look up the old and new headers. This "
               . "message will be suppressed from now on!\n";

    print LOG "\# " . (localtime) . ": check_fasta_headers(): Checking "
                    . "fasta headers of file "
                    . "$fastaFile\n" if ($v > 2);
    open( FASTA, "<", $fastaFile )
        or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
            $useexisting, "ERROR in file " . __FILE__ ." at line "
            . __LINE__ ."\nCould not open fasta file $fastaFile!\n");
    if( $genome_true == 1 ){
        open( OUTPUT, ">", "$otherfilesDir/genome.fa" )
            or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                $useexisting, "ERROR in file " . __FILE__ ." at line "
                . __LINE__
                . "\nCould not open fasta file $otherfilesDir/genome.fa!\n");
        open( MAP, ">", $mapFile )
            or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                $useexisting, "ERROR in file " . __FILE__ ." at line "
                . __LINE__ ."\nCould not open map file $mapFile.\n");
    }
    while (<FASTA>) {

        # check newline character
        if ( not( $_ =~ m/\n$/ ) ) {
            if ( $wrongNL < 1 ) {
                print LOG "#*********\n"
                    . "# WARNING: something seems to be wrong with the "
                    . "newline character! This is likely to cause problems "
                    . "with the galba.pl pipeline! Please adapt your file "
                    . "to UTF8! This warning will be supressed from now "
                    . "on!\n"
                    . "#*********\n" if ($v > 0);
                $wrongNL++;
            }
        }
        chomp;

        # look for whitespaces in fasta file
        if ( $_ =~ m/\s/ ) {
            if ( $spaces == 0 ) {
                $prtStr = "#*********\n"
                        . "# WARNING: Detected whitespace in fasta header of "
                        . "file $fastaFile. " . $stdStr
                        . "#*********\n";
                print LOG $prtStr if ($v > 2);
                print STDERR $prtStr;
                $spaces++;
            }
        }

        # look for | in fasta file
        if ( $_ =~ m/\|/ ) {
            if ( $orSign == 0 ) {
                $prtStr = "#*********\n"
                        . "# WARNING: Detected | in fasta header of file "
                        . "$fastaFile. " . $stdStr
                        . "#*********\n";
                print LOG $prtStr if ($v > 2);
                print STDERR $prtStr;
                $orSign++;
            }
        }

        # look for special characters in headers
        if ( ( $_ !~ m/[>a-zA-Z0-9]/ ) && ( $_ =~ m/^>/ ) ) {
            if ( $someThingWrongWithHeader == 0 ) {
                $prtStr = "#*********\n"
                        . " WARNING: Fasta headers in file $fastaFile seem to "
                        . "contain non-letter and non-number characters. That "
                        . "means they may contain some kind of special "
                        . "characters. "
                        . $stdStr
                        . "#*********\n";
                print LOG $prtStr if ($v > 2);
                print STDERR $prtStr;
                $someThingWrongWithHeader++;
            }
        }
        if ( ($_ =~ m/^>/) && ($genome_true == 1) ) {
            $scaffName = $_;
            $scaffName =~ s/^>//;
            # replace | and whitespaces by _
            my $oldHeader = $scaffName;
            $scaffName =~ s/\s/_/g;
            $scaffName =~ s/\|/_/g;
            print OUTPUT ">$scaffName\n";
            print MAP "$scaffName\t$oldHeader\n";
        }
        else {
            if ( length($_) > 0 ) {
                if($genome_true == 1){
                    print OUTPUT "$_\n";
                }
                if ( $_ !~ m/[ATGCNatgcn]/ ) {
                    if ( $dna == 0 ) {
                        print LOG "\# "
                            . (localtime)
                            . ": Assuming that this is not a DNA fasta "
                            . "file because other characters than A, T, G, "
                            . "C, N, a, t, g, c, n were contained. If this "
                            . "is supposed to be a DNA fasta file, check "
                            . "the content of your file! If this is "
                            . "supposed to be a protein fasta file, please "
                            . "ignore this message!\n" if ($v > 3);
                        $dna++;
                    }
                }
                if ( $_
                    !~ m/[AaRrNnDdCcEeQqGgHhIiLlKkMmFfPpSsTtWwYyVvBbZzJjOoUuXx]/
                    )
                {
                    if ( $prot == 0 ) {
                        print LOG "\# "
                            . (localtime)
                            . ": Assuming that this is not a protein fasta "
                            . "file because other characters than "
                            . "AaRrNnDdCcEeQqGgHhIiLlKkMmFfPpSsTtWwYyVvBbZzJjOoUuXx "
                            . "were contained. If this is supposed to be "
                            . "DNA fasta file, please ignore this "
                            . "message.\n" if ($v > 3);
                        $prot++;
                    }
                }
            }
            else {
                if ( $emptyC < 1 ) {
                    print LOG "#*********\n"
                        . " WARNING: empty line was removed! This warning "
                        . "will be supressed from now on!\n"
                        . "#*********\n" if ($v > 3);
                }
                $emptyC++;
            }
        }
    }
    close(FASTA) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line " . __LINE__
        ."\nCould not close fasta file $fastaFile!\n");
    if ($genome_true == 1){
        close(OUTPUT)
            or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                $useexisting, "ERROR in file " . __FILE__ ." at line "
                . __LINE__ ."\nCould not close output fasta file "
                . "$otherfilesDir/genome.fa!\n");
        close(MAP) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
            $useexisting, "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nCould not close map file $mapFile!\n");
        $genome = "$otherfilesDir/genome.fa";
    }
}

####################### make_prot_hints ########################################
# * run protein to genome alignment (gth or miniprot)
# * convert alignments to hints (calls aln2hints)
# * converts GenomeThreader alignments to hints (calls gth2gtf)
################################################################################

sub make_prot_hints {
    print LOG "\# " . (localtime) . ": Making protein hints\n" if ($v > 2);
    my $prot_hints;
    my $prot_hints_file_temp = "$otherfilesDir/prot_hintsfile.temp.gff";
    $prot_hintsfile = "$otherfilesDir/prot_hintsfile.gff";
    my $alignment_outfile = "$otherfilesDir/protein_alignment_$prg.gff3";

    # change to working directory
    $cmdString = "cd $otherfilesDir";
    print LOG "\# " . (localtime) . ": Changing to $otherfilesDir\n" if ($v > 3);
    print LOG "$cmdString\n" if ($v > 3);
    chdir $otherfilesDir or clean_abort(
        "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
        "ERROR in file " . __FILE__ ." at line ". __LINE__
        ."\nFailed to execute $cmdString!\n");

    # from fasta files
    if ( @prot_seq_files ) {
        $string = find(
            "startAlign.pl",        $AUGUSTUS_BIN_PATH,
            $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH);
        $errorfile = "$errorfilesDir/startAlign.stderr";
        $logfile   = "$otherfilesDir/startAlign.stdout";
        for ( my $i = 0; $i < scalar(@prot_seq_files); $i++ ) {
            if ( !uptodate( [ $prot_seq_files[$i] ], [$prot_hintsfile] )
                || $overwrite )
            {
                $perlCmdString = "";
                if ($nice) {
                    $perlCmdString .= "nice ";
                }
                $perlCmdString
                    .= "perl $string --genome=$genome --prot=$prot_seq_files[$i] --ALIGNMENT_TOOL_PATH=$ALIGNMENT_TOOL_PATH ";
                if ( $prg eq "gth" ) {
                    $perlCmdString .= "--prg=gth ";
                    print LOG "\# "
                        . (localtime)
                        . ": running Genome Threader to produce protein to "
                        . "genome alignments\n"  if ($v > 3);
                    print CITE $pubs{'gth'}; $pubs{'gth'} = "";
                }
                elsif ( $prg eq "exonerate" ) {
                    $perlCmdString .= "--prg=exonerate ";
                    print LOG "\# "
                        . (localtime)
                        . ": running Exonerate to produce protein to "
                        . "genome alignments\n" if ($v > 3);
                    print CITE $pubs{'exonerate'}; $pubs{'exonerate'} = "";
                }
                elsif ( $prg eq "spaln" ) {
                    $perlCmdString .= "--prg=spaln ";
                    print LOG "\# "
                        . (localtime)
                        . ": running Spaln to produce protein to "
                        . "genome alignments\n" if ($v > 3);
                    print CITE $pubs{'spaln'}; $pubs{'spaln'} = "";
                    print CITE $pubs{'spaln2'}; $pubs{'spaln2'} = "";
                }
                if ( $CPU > 1 ) {
                    $perlCmdString .= "--CPU=$CPU ";
                }
                if ($nice) {
                    $perlCmdString .= "--nice ";
                }
                $perlCmdString .= ">> $logfile 2>>$errorfile";
                print LOG "$perlCmdString\n" if ($v > 3);
                system("$perlCmdString") == 0
                    or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                     $useexisting, "ERROR in file " . __FILE__ ." at line "
                     . __LINE__ ."\nfailed to execute: $perlCmdString!\n");
                print LOG "\# "
                    . (localtime)
                    . ": Alignments from file $prot_seq_files[$i] created.\n" if ($v > 3);
                if ( -s "$otherfilesDir/align_$prg/$prg.concat.aln" ) {
                    $cmdString
                        = "cat $otherfilesDir/align_$prg/$prg.concat.aln >> $alignment_outfile";
                    print LOG "\# "
                        . (localtime)
                        . ": concatenating alignment file to $alignment_outfile\n" if ($v > 3);
                    print LOG "$cmdString\n" if ($v > 3);
                    system("$cmdString") == 0
                        or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                            $useexisting, "ERROR in file " . __FILE__
                            . " at line ". __LINE__
                            . "\nFailed to execute $cmdString!\n");
                }
                else {
                    print LOG "\# " . (localtime) . ": alignment file "
                        . "$otherfilesDir/align_$prg/$prg.concat.aln in round $i "
                        . "was empty.\n" if ($v > 3);
                }
                print LOG "\# "
                    . (localtime)
                    . ": moving startAlign output files\n" if ($v > 3);
                $cmdString = "mv $otherfilesDir/align_$prg $otherfilesDir/align_$prg$i";
                print LOG "$cmdString\n" if ($v > 3);
                system("$cmdString") == 0
                    or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                        $useexisting, "ERROR in file " . __FILE__ ." at line "
                        . __LINE__ ."\nFailed to execute: $cmdString!\n");
            }
            else {
                $prtStr
                    = "\# "
                    . (localtime)
                    . ": Skipping running alignment tool "
                    . "because files $prot_seq_files[$i] and $prot_hintsfile "
                    . "were up to date.\n";
                print LOG $prtStr if ($v > 3);
            }
        }
    }

    # convert pipeline created protein alignments to protein hints
    if ( @prot_seq_files && -e $alignment_outfile ) {
        if ( !uptodate( [$alignment_outfile], [$prot_hintsfile] )
            || $overwrite )
        {
            if ( -s $alignment_outfile ) {
                aln2hints( $alignment_outfile, $prot_hints_file_temp );
            }
            else {
                print LOG "\# "
                    . (localtime)
                    . ": Alignment out file $alignment_outfile with "
                    . "protein alignments is empty. Not producing any hints "
                    . "from protein input sequences.\n" if ($v > 3);
            }
        }
    }

    # convert command line specified protein alignments to protein hints
    if ( @prot_aln_files ) {
        for ( my $i = 0; $i < scalar(@prot_aln_files); $i++ ) {
            if ( !uptodate( [ $prot_aln_files[$i] ], [$prot_hintsfile] )
                || $overwrite )
            {
                aln2hints( $prot_aln_files[$i], $prot_hints_file_temp );
            }
            else {
                print LOG "\# "
                    . (localtime)
                    . ": Skipped converting alignment file "
                    . "$prot_aln_files[$i] to hints because it was up to date "
                    . "with $prot_hintsfile\n" if ($v > 3);
            }
        }
    }

    # appending protein hints to $hintsfile (combined with RNA_Seq if available)
    if ( -f $prot_hints_file_temp || $overwrite ) {
        if ( !uptodate( [$prot_hints_file_temp], [$prot_hintsfile] )
            || $overwrite )
        {
            join_mult_hints( $prot_hints_file_temp, "prot" );
            print LOG "\# "
                . (localtime)
                . ": moving $prot_hints_file_temp to $prot_hintsfile\n" if ($v > 3);
            $cmdString = "mv $prot_hints_file_temp $prot_hintsfile";
            print LOG "$cmdString\n" if ($v > 3);
            system($cmdString) == 0
                or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nFailed to execute: $cmdString!\n");
            print LOG "Deleting $prot_hints_file_temp\n" if ($v > 3);
            unlink($prot_hints_file_temp);
            print LOG "\# "
                . (localtime)
                . ": joining protein and RNA-Seq hints files -> appending "
                . "$prot_hintsfile to $hintsfile\n" if ($v > 3);
            $cmdString = "cat $prot_hintsfile >> $hintsfile";
            print LOG "$cmdString\n" if ($v > 3);
            system($cmdString) == 0
                or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nFailed to execute: $cmdString!\n");
            print LOG "\# " . (localtime) . ": Deleting $prot_hintsfile\n" if ($v > 3);
            unlink($prot_hintsfile);
            my $toBeSortedHintsFile = "$otherfilesDir/hintsfile.tmp.gff";
            print LOG "\# "
                . (localtime)
                . ": Moving $hintsfile to $toBeSortedHintsFile to enable "
                . "sorting\n" if ($v > 3);
            $cmdString = "mv $hintsfile $toBeSortedHintsFile";
            print LOG "$cmdString\n" if ($v > 3);
            system($cmdString) == 0
                or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nFailed to execute: $cmdString!\n");
            print LOG "\# "
                . (localtime)
                . ": Sorting hints file $hintsfile\n" if ($v > 3);
            $cmdString
                = "cat $toBeSortedHintsFile | sort -n -k 4,4 | sort -s -n -k 5,5 | sort -s -n -k 3,3 | sort -s -k 1,1 > $hintsfile";
            print LOG "$cmdString\n" if ($v > 3);
            system($cmdString) == 0
                or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nFailed to execute: $cmdString!\n");
            print LOG "\# "
                . (localtime)
                . ": Deleting file $toBeSortedHintsFile\n" if ($v > 3);
            print LOG "rm $toBeSortedHintsFile\n" if ($v > 3);
            unlink($toBeSortedHintsFile);
        }
    }
    if ( -z $prot_hintsfile ) {
        $prtStr
            = "\# "
            . (localtime)
            . " ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
            . "The hints file is empty. There were no protein "
            . "alignments.\n";
        print LOG $prtStr;
        clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
            $prtStr);
    }
    if ($gth2traingenes) {
        if (@prot_aln_files) {
            foreach (@prot_aln_files) {
                $cmdString = "cat $_ >> $alignment_outfile";
                print LOG "\# "
                    . (localtime)
                    . ": Concatenating protein alignment input file $_ to "
                    . "$alignment_outfile\n" if ($v > 3);
                print LOG "$cmdString\n" if ($v > 3);
                system($cmdString) == 0
                    or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                        $useexisting, "ERROR in file " . __FILE__ ." at line "
                        . __LINE__ ."\nFailed to execute: $cmdString!\n");
            }
        }
        gth2gtf( $alignment_outfile, $gthTrainGeneFile );
    }
}

####################### aln2hints ##############################################
# * converts protein alignments to hints
################################################################################

sub aln2hints {
    my $aln_file = shift;
    print LOG "\# " . (localtime)
        . ": Converting alignments from file $aln_file to hints\n" if ($v > 2);
    if ( !( -z $aln_file ) ) {
        my $out_file_name
            = "$otherfilesDir/prot_hintsfile.aln2hints.temp.gff";
        my $final_out_file = shift;
        print LOG "\# "
            . (localtime)
            . ": Converting protein alignment file $aln_file to hints for "
            . "AUGUSTUS\n" if ($v > 3);
        $perlCmdString = "perl ";
        if ($nice) {
            $perlCmdString .= "nice ";
        }
        $string = find(
            "align2hints.pl",       $AUGUSTUS_BIN_PATH,
            $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
        );
        $perlCmdString .= "$string --in=$aln_file --out=$out_file_name ";
        if ( $prg eq "spaln" ) {
            $perlCmdString .= "--prg=spaln";
        }
        elsif ( $prg eq "gth" ) {
            $perlCmdString .= "--prg=gth --priority=5";
        }
        elsif ( $prg eq "exonerate" ) {
            $perlCmdString
                .= "--prg=exonerate --genome_file=$genome --priority=3";
        }
        print LOG "$perlCmdString\n" if ($v > 3);
        system("$perlCmdString") == 0
            or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                $useexisting, "ERROR in file " . __FILE__ ." at line "
                . __LINE__ ."\nFailed to execute: $perlCmdString\n");
        $cmdString = "cat $out_file_name >> $final_out_file";
        print LOG "\# "
            . (localtime)
            . ": concatenating protein hints from $out_file_name to "
            . "$final_out_file\n" if ($v > 3);
        print LOG $cmdString . "\n" if ($v > 3);
        system("$cmdString") == 0 or clean_abort(
            "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
            "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nFailed to execute: $cmdString\n");
    }
    else {
        print LOG "#*********\n"
                . "# WARNING: Alignment file $aln_file was empty!\n"
                . "#*********\n" if ($v > 0);
    }
}

####################### gth2gtf ################################################
# * converts GenomeThreader alignments to gtf for training AUGUSTUS
################################################################################

sub gth2gtf {
    my $align = shift;
    print LOG "\# " . (localtime) . ": Converting GenomeThreader file $align "
    . "to gtf format\n" if ($v > 2);
    my $out   = shift;    # writes to $gthTrainGeneFile
    open( GTH,    "<", $align ) or clean_abort(
        "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
        "ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nCould not open file $align!\n");
    open( GTHGTF, ">", $out )   or clean_abort(
        "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
        "ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nCould not open file $out!\n");
    my $geneId;

    # GTH may output alternative transcripts; we don't want to have any
    # alternatives in training gene set, only print the first of any occuring
    # alternatives
    my %seen;
    while (<GTH>) {
        chomp;
        my @gtfLine = split(/\t/);
        if (m/\tgene\t/) {
            my @idCol = split( /=/, $gtfLine[8] );
            $geneId = $idCol[1];
        }
        elsif (m/\tCDS\t/) {
            my @gtfLineLastCol      = split( /;/, $gtfLine[8] );
            my @gtfLineLastColField = split( /=/, $gtfLineLastCol[1] );
            if (not( defined( $seen{ "$gtfLine[0]" . "_" . $geneId . "_" } ) )
                )
            {
                $seen{ "$gtfLine[0]" . "_" . $geneId . "_" }
                    = "$gtfLine[0]" . "_"
                    . $geneId . "_"
                    . $gtfLineLastColField[1];
            }
            if ( $seen{ "$gtfLine[0]" . "_" . $geneId . "_" } eq "$gtfLine[0]"
                . "_"
                . $geneId . "_"
                . $gtfLineLastColField[1] )
            {
                print GTHGTF "$gtfLine[0]\t$gtfLine[1]\t$gtfLine[2]\t"
                            . "$gtfLine[3]\t$gtfLine[4]\t$gtfLine[5]\t"
                            . "$gtfLine[6]\t$gtfLine[7]\tgene_id \""
                            . "$gtfLine[0]_g_" .$geneId . "_"
                            . $gtfLineLastColField[1] . "\"; transcript_id "
                            . "\"$gtfLine[0]_t" . "_" . $geneId . "_"
                            . $gtfLineLastColField[1] . "\";\n";
                print GTHGTF "$gtfLine[0]\t$gtfLine[1]\texon\t$gtfLine[3]\t"
                            . "$gtfLine[4]\t$gtfLine[5]\t$gtfLine[6]\t"
                            . "$gtfLine[7]\tgene_id \"$gtfLine[0]_g" . "_"
                            . $geneId . "_"
                            . $gtfLineLastColField[1] . "\"; transcript_id \""
                            . "$gtfLine[0]_t" . "_" . $geneId . "_"
                            . $gtfLineLastColField[1] . "\";\n";
            }
        }
    }
    close(GTHGTF) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nCould not close file $out!\n");
    close(GTH)    or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nCould not close file $align!\n");
}

####################### add_other_hints ########################################
# * add command line supplied hints to hints file
################################################################################

sub add_other_hints {
    print LOG "\# " . (localtime)
        . ": Adding other user provided hints to hintsfile\n" if ($v > 2);
    if (@hints) {
        # have "uptodate" issues at this point, removed it... maybe fix later
        for ( my $i = 0; $i < scalar(@hints); $i++ ) {
            # replace Intron by intron
            my $replacedHintsFile = "$otherfilesDir/replaced_hints_$i.gff";
            open (OTHER, "<", $hints[$i]) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nCould not open file $hints[$i]!\n");
            open (REPLACED, ">", $replacedHintsFile) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nCould not open file $replacedHintsFile!\n");
            while(<OTHER>) {
                $_ =~ s/\tIntron\t/\tintron\t/;
                print REPLACED $_;
            }
            close (OTHER) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nCould not close file $hints[$i]!\n");
            close (REPLACED) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nCould not close file $replacedHintsFile!\n");
            # find Strand, set multiplicity for GeneMark
            my $filteredHintsFile = "$otherfilesDir/filtered_hints_$i.gff";
            $string = find(
                "filterIntronsFindStrand.pl", $AUGUSTUS_BIN_PATH,
                $AUGUSTUS_SCRIPTS_PATH,       $AUGUSTUS_CONFIG_PATH
            );
            $errorfile = "$errorfilesDir/filterIntronsFindStrand_userHints_$i.stderr";
            $perlCmdString = "";
            if ($nice) {
                $perlCmdString .= "nice ";
            }
            $perlCmdString .= "perl $string $genome $replacedHintsFile --score 1> $filteredHintsFile 2>$errorfile";
            print LOG "\# "
                . (localtime)
                . ": filter introns, find strand and change score to \'mult\' "
                . "entry\n" if ($v > 3);
            print LOG "$perlCmdString\n" if ($v > 3);
            system("$perlCmdString") == 0
                or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nfailed to execute: $perlCmdString!\n");
            $cmdString = "";
            if ($nice) {
                $cmdString .= "nice ";
            }
            $cmdString .= "cat $filteredHintsFile >> $hintsfile";
            print LOG "\# "
                . (localtime)
                . ": adding hints from file $filteredHintsFile to $hintsfile\n" if ($v > 3);
            print LOG "$cmdString\n" if ($v > 3);
            system("$cmdString") == 0
                or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nFailed to execute: $cmdString!\n");
            print LOG "\# "
                . (localtime)
                . ": deleting file $filteredHintsFile\n" if ($v > 3);
            unlink ( $filteredHintsFile ) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nFailed to delete file $filteredHintsFile!\n");
            print LOG "\# "
                . (localtime)
                . ": deleting file $replacedHintsFile\n" if ($v > 3);
            unlink ( $replacedHintsFile ) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nFailed to delete file $replacedHintsFile!\n");;
        }
        join_mult_hints( $hintsfile, "all" );
    }
}

####################### join_mult_hints ########################################
# * joins hints that are identical (from the same source)
# * hints with src=C and grp= tags are not joined
################################################################################

sub join_mult_hints {
    my $hints_file_temp = shift;
    my $type            = shift;    # rnaseq or prot or whatever will follow
    print LOG "\# " . (localtime) . ": Checking for hints of src=C and with grp "
        . "tags that should not be joined according to multiplicity\n" if ($v > 2);
    my $to_be_merged = $otherfilesDir."/tmp_merge_hints.gff";
    my $not_to_be_merged = $otherfilesDir."/tmp_no_merge_hints.gff";
    open(HINTS, "<", $hints_file_temp) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nFailed to open file $hints_file_temp for reading!\n");
    open(MERG, ">", $to_be_merged) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nFailed to open file $to_be_merged for writing!\n");
    open(NOME, ">", $not_to_be_merged) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nFailed to open file $not_to_be_merged for writing!\n");
    while(<HINTS>){
        if($_ =~ m/src=C/ && (($_ =~ m/grp=/) || $_ =~ m/group=/)){
            print NOME $_;
        }else{
            print MERG $_;
        }
    }
    close(MERG) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nFailed to close file $to_be_merged!\n");
    close(NOME) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nFailed to close file $not_to_be_merged!\n");
    close(HINTS) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
        $useexisting, "ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nFailed to open file $hints_file_temp for reading!\n");
    if(-z $to_be_merged){
        unlink($to_be_merged);
        $cmdString = "mv $not_to_be_merged $hints_file_temp";
        print LOG "$cmdString\n" if ($v > 3);
        system($cmdString) == 0 or clean_abort(
            "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
            "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nFailed to execute: $cmdString\n");
        return;
    }else{
        print LOG "\# " . (localtime) . ": Joining hints that are identical "
            . "(& from the same source) into multiplicity hints (input file "
            . "$to_be_merged)\n" if ($v > 2);        
        my $hintsfile_temp_sort = "$otherfilesDir/hints.$type.temp.sort.gff";
        $cmdString = "";
        if ($nice) {
            $cmdString .= "nice ";
        }
        $cmdString .= "cat $to_be_merged | sort -n -k 4,4 | sort -s -n -k 5,5 | sort -s -n -k 3,3 | sort -s -k 1,1 >$hintsfile_temp_sort";
        print LOG "\# " . (localtime) . ": sort hints of type $type\n" if ($v > 3);
        print LOG "$cmdString\n" if ($v > 3);
        system("$cmdString") == 0 or clean_abort(
           "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
            "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nFailed to execute: $cmdString!\n");
        $string = find(
            "join_mult_hints.pl",   $AUGUSTUS_BIN_PATH,
            $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
        );
        $errorfile     = "$errorfilesDir/join_mult_hints.$type.stderr";
        $perlCmdString = "";
        if ($nice) {
            $perlCmdString .= "nice ";
        }
        $perlCmdString .= "perl $string <$hintsfile_temp_sort >$to_be_merged 2>$errorfile";
        print LOG "\# " . (localtime) . ": join multiple hints\n" if ($v > 3);
        print LOG "$perlCmdString\n" if ($v > 3);
        system("$perlCmdString") == 0
            or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                $useexisting, "ERROR in file " . __FILE__ ." at line ". __LINE__
                . "\nFailed to execute: $perlCmdString\n");
        unlink($hintsfile_temp_sort);
    }
    if( -z $not_to_be_merged ) {
        $cmdString = "mv $to_be_merged $hints_file_temp";
        print LOG "$cmdString\n" if ($v > 3);
        system($cmdString) == 0 or clean_abort(
            "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
            "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nFailed to execute: $cmdString\n");
    }else{
        $cmdString = 'cat '.$to_be_merged.' '.$not_to_be_merged.' > '.$hints_file_temp;
        print LOG "$cmdString\n" if ($v > 3);
        system($cmdString) == 0 or clean_abort(
            "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
            "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nFailed to execute: $cmdString\n");
    }
}

####################### check_hints ############################################
# * check whether hints file contains hints from RNA-Seq (returns 1)
# * check whether hints file contains hints from proteins ($foundProt++)
################################################################################

sub check_hints {
    $prtStr = "\# ". (localtime)
            . ": Checking whether hints from RNA-Seq and/or proteins are "
            . "present in hintsfile\n";
    $logString .= $prtStr if ($v > 2);
    my $thisHintsFile = shift;
    my @areb2h        = `cut -f 9 $thisHintsFile | grep src=E`;
    my $ret           = 0;
    if ( scalar( @areb2h ) > 0 ) {
        $ret = 1;
    }
    my @areP = `cut -f 9 $thisHintsFile | grep src=P`;
    if( scalar( @areP ) > 0 ) {
        $foundProt++;
        $foundProteinHint++;
    }
    return $ret;
}

####################### new_species ############################################
# * create a new species parameter folder in AUGUSTUS_CONFIG_PATH/species
#   for AUGUSTUS
################################################################################

sub new_species {
    print LOG "\# " . (localtime) . ": Creating parameter template files for "
                    . "AUGUSTUS with new_species.pl\n" if ($v > 2);
    $augpath = "$AUGUSTUS_CONFIG_PATH/species/$species";
    if ((   !uptodate(
                [ $augpath . "/$species\_metapars.cfg" ],
                [   $augpath . "/$species\_parameters.cfg",
                    $augpath . "/$species\_exon_probs.pbl"
                ]
            )
            && !$useexisting
        )
        || !-d "$AUGUSTUS_CONFIG_PATH/species/$species"
        )
    {
        if ( -d "$AUGUSTUS_CONFIG_PATH/species" ) {
            if ( -w "$AUGUSTUS_CONFIG_PATH/species" ) {
                $string = find(
                    "new_species.pl",       $AUGUSTUS_BIN_PATH,
                    $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
                );
                $errorfile     = "$errorfilesDir/new_species.stderr";
                $perlCmdString = "";
                if ($nice) {
                    $perlCmdString .= "nice ";
                }
                $perlCmdString .= "perl $string --species=$species "
                               .  "--AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH "
                               .  "1> /dev/null 2>$errorfile";
                print LOG "\# "
                    . (localtime)
                    . ": new_species.pl will create parameter files for "
                    . "species $species in "
                    . "$AUGUSTUS_CONFIG_PATH/species/$species\n" if ($v > 3);
                print LOG "$perlCmdString\n" if ($v > 3);
                system("$perlCmdString") == 0 or die(
                    "ERROR in file " . __FILE__ ." at line ". __LINE__
                    . "\nFailed to create new species with new_species.pl, "
                    . "check write permissions in "
                    . "$AUGUSTUS_CONFIG_PATH/species directory! "
                    . "Command was $perlCmdString\n");
                if(not($ttable == 1)){
                    print LOG "\# "
                        . (localtime)
                        . ": setting translation_table to $ttable in file "
                        . "$AUGUSTUS_CONFIG_PATH/species/$species/$species\_parameters.cfg\n" if ($v > 3);
                    addParToConfig($AUGUSTUS_CONFIG_PATH
                                   . "/species/$species/$species\_parameters.cfg",
                                     "translation_table", "$ttable");
                    if($ttable =~ m/^(10|25|30|31)$/){
                        print LOG "\# " . (localtime)
                                  . ": Setting frequency of stop codon opalprob (TGA) to 0\n" if ($v > 3);
                        setParInConfig($AUGUSTUS_CONFIG_PATH . "/species/$species/$species\_parameters.cfg",
                                       "/Constant/opalprob", 0);
                    }elsif($ttable =~ m/^(6|27|29)$/){
                        print LOG "\# " . (localtime)
                                  . ": Setting frequencies of stop codons ochreprob (TAA) and amberprob (TAG) to 0\n" if ($v > 3);
                        setParInConfig($AUGUSTUS_CONFIG_PATH . "/species/$species/$species\_parameters.cfg",
                            "/Constant/ochreprob", 0);
                        setParInConfig($AUGUSTUS_CONFIG_PATH . "/species/$species/$species\_parameters.cfg",
                            "/Constant/amberprob", 0);
                    }
                }

            } else {
                $prtStr = "\# "
                        . (localtime)
                        . ": ERROR: in file " . __FILE__ ." at line ". __LINE__
                        . "\nDirectory $AUGUSTUS_CONFIG_PATH/species is not "
                        . "writable! You must make the directory "
                        . "AUGUSTUS_CONFIG_PATH/species writable or specify "
                        . "another AUGUSTUS_CONFIG_PATH!\n";
                print LOG $prtStr;
                print STDERR $prtStr;
                exit(1);
            }
        } else {
            $prtStr = "\# "
                    . (localtime)
                    . ": ERROR: in file " . __FILE__ ." at line ". __LINE__
                    ."\nDirectory $AUGUSTUS_CONFIG_PATH/species does not "
                    . "exist. Please check that AUGUSTUS_CONFIG_PATH is set, "
                    . "correctly!\n";
            print LOG $prtStr;
            print STDERR $prtStr;
            exit(1);
        }
    }
}

####################### training_augustus #######################################
# * train AUGUSTUS on the basis of generated training gene structures
# * in case of GeneMark training genes, flanking regions exclude parts that
#   were predicted as coding by GeneMark, even if the coding parts in potential
#   flanking regions did not qualify as evidence supported training genes
# * above is not the case for GenomeThreader training genes
# * if both GeneMark-ET and GenomeThreader genes are given, overlap on genomic
#   level is determined; GeneMark-ET genes are given preference (i.e. those
#   GenomeThreader genes will be deleted)
# * gtf is converted to genbank format for etraining
# * gene structures that produce etraining errors are deleted
# * CDS in training gene structures are BLASTed against themselves and redundant
#   gene structures are deleted
# * training genes are split into three sets:
#   a) for assessing accuracy of training (never used for training)
#   b) for etraining & optimize_augustus.pl
#   c) for testing during optimize_augustus.pl (also used for etraining, then)
# * UTR training is not included in this function
################################################################################

sub training_augustus {
    print LOG "\# " . (localtime) . ": training AUGUSTUS\n" if ($v > 2);
    if ( !$useexisting ) {
        my $gthGtf = $gthTrainGeneFile;
        my $trainGenesGtf = "$otherfilesDir/traingenes.gtf";
        my $trainGb1 = "$otherfilesDir/train.gb";
        my $trainGb2 = "$otherfilesDir/train.f.gb";
        my $trainGb3 = "$otherfilesDir/train.ff.gb";
        my $trainGb4 = "$otherfilesDir/train.fff.gb";
        my $goodLstFile = "$otherfilesDir/good_genes.lst";
        my $t_b_t = 0; # to be tested gene set size, used to determine
                       # stop codon setting and to compute k for cores>8

        # set contents of trainGenesGtf file
       if ( $trainFromGth ) {
            # create softlink from gth.gtf to traingenes.gtf
             # make gth gb final
            print LOG "\#  "
                . (localtime)
                . ": creating softlink from $gthGtf to $trainGenesGtf.\n"
                if ($v > 3);
            $cmdString = "ln -s $gthGtf $trainGenesGtf";
            print LOG "$cmdString\n" if ($v > 3);
            system($cmdString) == 0
                or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nfailed to execute: $cmdString!\n");
        } elsif ( defined($traingtf) ){
            print LOG "\# "
                . (localtime)
                . ": creating softlink from $traingtf to $trainGenesGtf.\n"
                if ($v > 3);
            $cmdString = "ln -s $traingtf $trainGenesGtf";
            print LOG "$cmdString\n" if ($v > 3);
            system($cmdString) == 0
                or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nfailed to execute: $cmdString!\n");
        }else {
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "unknown training gene generation scenario!\n";
            print STDERR $prtStr;
            clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
                $prtStr);
        }

        # convert gtf to gb
        gtf2gb ($trainGenesGtf, $trainGb1);

        # count how many genes are in trainGb1
        my $nLociGb1 = count_genes_in_gb_file($trainGb1);
        if( $nLociGb1 == 0){
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "Training gene file in genbank format $trainGb1 does not "
                . "contain any training genes. Possible known causes: "
                . "this may be caused by usage of too distant protein "
                . "sequences; if you think this is the cause for your problems, "
                . "consider running BRAKER; "
                . "(b) complex FASTA headers in the genome file, "
                . "for example, a user reported that headers of the style "
                . "\'>NODE_1_length_397140_cov_125.503112 kraken:taxid|87257\'"
                . " caused our script for gtf to gb conversion to crash, while "
                . "a simple FASTA header such as \'>NODE_1\' worked fine; if "
                . "you think this is the cause for your problems, consider "
                . "simplifying the FASTA headers.\n";
            print STDERR $prtStr;
                clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
                    $prtStr);
        }

        # all genes in train.gtf are "good" genes
        $goodLstFile = $trainGenesGtf;

        if ( $gth2traingenes ) {
            print LOG "\#  "
                . (localtime)
                . ": concatenating good GenomeThreader training genes to "
                . "$goodLstFile.\n" if ($v > 3);
            # get all remaining gth genes
            open (GOODLST, ">>", $goodLstFile) or clean_abort(
                "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
                "ERROR in file " . __FILE__ ." at line ". __LINE__
                . "\nCould not open file $goodLstFile!\n" );
            open ( GTHGOOD, "<", $trainGenesGtf ) or clean_abort(
                "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
                "ERROR in file " . __FILE__ ." at line ". __LINE__
                . "\nCould not open file $trainGenesGtf!\n" );
            while ( <GTHGOOD> ) {
                if ( $_ =~ m/\tgth\t/ ) {
                    print GOODLST $_;
                }
            }
           close ( GTHGOOD ) or clean_abort(
            "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
            "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nCould not close file $trainGenesGtf!\n" );
           close (GOODLST) or clean_abort(
            "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
            "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nCould not close file $goodLstFile!\n" );
        }

        # check whether goodLstFile has any content
        open (GOODLST, "<", $goodLstFile) or clean_abort(
             "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
             "ERROR in file " . __FILE__ ." at line ". __LINE__
             . "\nCould not open file $goodLstFile!\n" );
        while(<GOODLST>){};
        my $nGoodGenes = $.;
        close (GOODLST) or clean_abort(
            "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
            "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nCould not close file $goodLstFile!\n" );
        if($nGoodGenes < 1){
            $prtStr = "\# "
                . (localtime)
                . " ERROR: file $goodLstFile contains no good training genes."
                . " This means that with RNA-Seq data, there was insufficient"
                . " coverage of introns; or with protein data, there was "
                . "insufficient support from protein alignments/GaTech protein"
                . " mapping pipeline hints; or without any evidence, there "
                . " were only very short genes. In most cases, you will see "
                . " this happening if GALBA was executed with some kind of "
                . " extrinsic evidence (either/or RNA-Seq/protein). You can then "
                . " try to re-run GALBA without any evidence for training "
                . " and later use the such trained AUGUSTUS parameters for a "
                . " GALBA run without any training and the available evidence."
                . " Accuracy of training without any evidence is lower than with "
                . " good evidence.\n";
            print LOG $prtStr;
            print STDERR $prtStr;
            clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
            $   useexisting, "ERROR in file " . __FILE__ ." at line ". __LINE__
                . "\nNo genes for training in file $goodLstFile!\n");
        }

        # filter good genes from trainGb1 into trainGb2
        $string = find(
                "filterGenesIn_mRNAname.pl",       $AUGUSTUS_BIN_PATH,
                $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
            );
        $errorfile     = "$errorfilesDir/filterGenesIn_mRNAname.stderr";
        $perlCmdString = "";
        if ($nice) {
            $perlCmdString .= "nice ";
        }
        $perlCmdString
            .= "perl $string $goodLstFile $trainGb1 > $trainGb2 2>$errorfile";
        print LOG "\# "
            . (localtime)
            . ": Filtering train.gb for \"good\" mRNAs:\n" if ($v > 3);
        print LOG "$perlCmdString\n" if ($v > 3);
        system("$perlCmdString") == 0
            or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
            $useexisting, "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nFailed to execute: $perlCmdString\n");

        # count how many genes are in trainGb2
        my $nLociGb2 = count_genes_in_gb_file($trainGb2);
        if( $nLociGb2 == 0){
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "# Training gene file in genbank format $trainGb2 does not "
                . "contain any training genes. Possible known causes:\n"
                . "# (a) The AUGUSTUS script filterGenesIn_mRNAname.pl is not "
                . "up-to-date with this version of GALBA. To solve this issue, "
                . "either get the latest AUGUSTUS from its master branch with\n"
                . "    git clone git\@github.com:Gaius-Augustus/Augustus.git\n"
                . "or download the latest version of filterGenesIn_mRNAname.pl from "
                . "https://github.com/Gaius-Augustus/Augustus/blob/master/scripts/filterGenesIn_mRNAname.pl "
                . "and replace the old script in your AUGUSTUS installation folder.\n"
                . "# (b) No training genes were generated by GenomeThreader or Miniprot "
                . "If you think this is the cause for your problem, "
                . "consider running BRAKER.\n";
            print LOG $prtStr;
            print STDERR $prtStr;
                clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
                    $prtStr);
        }

        # filter out genes that lead to etraining errors
        $augpath    = "$AUGUSTUS_BIN_PATH/etraining";
        $errorfile  = "$errorfilesDir/gbFilterEtraining.stderr";
        $stdoutfile = "$otherfilesDir/gbFilterEtraining.stdout";
        $cmdString  = "";
        if ($nice) {
            $cmdString .= "nice ";
        }
        # species is irrelevant!
        $cmdString .= "$augpath --species=$species --AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH $trainGb2 1> $stdoutfile 2>$errorfile";
        print LOG "\# "
            . (localtime)
            . ": Running etraining to catch gene structure inconsistencies:\n"
            if ($v > 3);
        print LOG "$cmdString\n" if ($v > 3);
        system("$cmdString") == 0
            or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                $useexisting, "ERROR in file " . __FILE__ ." at line "
                . __LINE__ ."\nFailed to execute: $cmdString\n");
        open( ERRS, "<", $errorfile )
            or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                $useexisting, "ERROR in file " . __FILE__ ." at line "
                . __LINE__ . "\nCould not open file $errorfile!\n");
        open( BADS, ">", "$otherfilesDir/etrain.bad.lst" )
            or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                $useexisting, "ERROR in file " . __FILE__ ." at line "
                . __LINE__
                ."\nCould not open file $otherfilesDir/etrain.bad.lst!\n");
        while (<ERRS>) {
            if (m/n sequence (\S+):.*/) {
                print BADS "$1\n";
            }
        }
        close(BADS)
            or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                $useexisting, "ERROR in file " . __FILE__ ." at line "
                . __LINE__
                ."\nCould not close file $otherfilesDir/etrain.bad.lst!\n");
        close(ERRS) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
            $useexisting, "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nCould not close file $errorfile!\n");
        $string = find(
            "filterGenes.pl",       $AUGUSTUS_BIN_PATH,
            $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
        );
        $errorfile     = "$errorfilesDir/etrainFilterGenes.stderr";
        $perlCmdString = "";
        if ($nice) {
            $perlCmdString .= "nice ";
        }
        $perlCmdString
            .= "perl $string $otherfilesDir/etrain.bad.lst $trainGb2 1> $trainGb3 2>$errorfile";
        print LOG "\# "
            . (localtime)
            . ": Filtering $trainGb2 file to remove inconsistent gene structures...\n" if ($v > 3);
        print LOG "$perlCmdString\n" if ($v > 3);
        system("$perlCmdString") == 0
            or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                $useexisting, "ERROR in file " . __FILE__ ." at line "
                . __LINE__ ."\nFailed to execute: $perlCmdString\n");

        # count how many genes are in trainGb3
        my $nLociGb3 = count_genes_in_gb_file($trainGb3);
        if( $nLociGb3 == 0){
            $prtStr
                = "\# "
                . (localtime)
                . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "Training gene file in genbank format $trainGb3 does not "
                . "contain any training genes. At this stage, we performed a "
                . "filtering step that discarded all genes that lead to etraining "
                . "errors. If you lost all training genes, now, that means you "
                . "probably have an extremely fragmented assembly where all training "
                . "genes are incomplete, or similar.\n";
            print STDERR $prtStr;
                clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
                    $prtStr);
        }

        # reduce gene set size if >8000. We introduce this step because
        # sometimes, there is a such a huge number of putative training genes
        # that optimize_augustus.pl runs into a memory access problem 
        # (not understood why exactly, yet, but it is a parallelization issue)
        # also, BLASTing a very high number of genes takes way too long
        # might want to reconsider the threshold (8000?)
        if($nLociGb3 > 8000){
            print LOG "\# "
                . (localtime)
                . ": Reducing number of training genes by random selection to 8000.\n";
            $string = find(
                "randomSplit.pl",       $AUGUSTUS_BIN_PATH,
                $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
            );
            $errorfile = "$errorfilesDir/randomSplit_8000.stderr";
            $perlCmdString = "";
            if ($nice) {
                $perlCmdString .= "nice ";
            }
            $perlCmdString .= "perl $string $trainGb3 8000 2>$errorfile";
            print LOG "$perlCmdString\n" if ($v > 3);
            system("$perlCmdString") == 0
                or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nFailed to execute: $perlCmdString\n");
            $cmdString = "";
            if ($nice) {
                $cmdString .= "nice ";
            }
            $cmdString .= "mv $trainGb3.test $trainGb3";
            print LOG "$cmdString\n" if ($v > 3);
            system("$cmdString") == 0
                or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nFailed to execute: $cmdString\n");
        }

        # find those training genes in gtf that are still in gb
        open (TRAINGB3, "<", $trainGb3) or clean_abort(
            "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
            "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nCould not open file $trainGb3!\n" );
        my %txInGb3;
        my $txLocus;;
        while( <TRAINGB3> ) {
            if ( $_ =~ m/LOCUS\s+(\S+)\s/ ) {
                $txLocus = $1;
            }elsif ( $_ =~ m/\/gene=\"(\S+)\"/ ) {
                $txInGb3{$1} = $txLocus;
            }
        }
        close (TRAINGB3) or clean_abort(
            "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
            "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nCould not close file $trainGb3!\n" );

        # filter in those genes that are good
        open (GTF, "<", $trainGenesGtf) or clean_abort(
            "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
            "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nCould not open file $trainGenesGtf!\n");
        open (GOODGTF, ">", "$otherfilesDir/traingenes.good.gtf") or
            clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                $useexisting, "ERROR in file " . __FILE__ ." at line "
                . __LINE__
                . "\nCould not open file "
                . "$otherfilesDir/traingenes.good.gtf!\n");
        while(<GTF>){
            if($_ =~ m/transcript_id \"(\S+)\"/){
                if(defined($txInGb3{$1})){
                    print GOODGTF $_;
                }
            }
        }
        close(GOODGTF) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
            $useexisting, "ERROR in file " . __FILE__ ." at line "
            . __LINE__
            ."\nCould not close file $otherfilesDir/traingenes.good.gtf!\n");
        close(GTF) or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
            $useexisting, "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nCould not close file $trainGenesGtf!\n");

        # convert those training genes to protein fasta file
        gtf2fasta ($genome, "$otherfilesDir/traingenes.good.gtf",
            "$otherfilesDir/traingenes.good.fa", $ttable);

        # blast or diamond good training genes to exclude redundant sequences
        $string = find(
            "aa2nonred.pl",       $AUGUSTUS_BIN_PATH,
            $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
        );
        $errorfile     = "$errorfilesDir/aa2nonred.stderr";
        $stdoutfile    = "$otherfilesDir/aa2nonred.stdout";
        $perlCmdString = "";
        if ($nice) {
            $perlCmdString .= "nice ";
        }
        if(defined($DIAMOND_PATH) and not(defined($blast_path))){
            $perlCmdString .= "perl $string $otherfilesDir/traingenes.good.fa "
                           .  "$otherfilesDir/traingenes.good.nr.fa "
                           .  "--DIAMOND_PATH=$DIAMOND_PATH --cores=$CPU "
                           .  "--diamond 1> $stdoutfile 2>$errorfile";
            print CITE $pubs{'diamond'}; $pubs{'diamond'} = "";
        }else{
            $perlCmdString .= "perl $string $otherfilesDir/traingenes.good.fa "
                           .  "$otherfilesDir/traingenes.good.nr.fa "
                           .  "--BLAST_PATH=$BLAST_PATH --cores=$CPU 1> "
                           .  "$stdoutfile 2>$errorfile";
            print CITE $pubs{'blast1'}; $pubs{'blast1'} = "";
            print CITE $pubs{'blast2'}; $pubs{'blast2'} = "";
        }
        print LOG "\# "
            . (localtime)
            . ": BLAST or DIAMOND training gene structures against themselves:\n" if ($v > 3);
        print LOG "$perlCmdString\n" if ($v > 3);
        system("$perlCmdString") == 0
            or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                $useexisting, "ERROR in file " . __FILE__ ." at line "
                . __LINE__ ."\nFailed to execute: $perlCmdString\n");

        # parse output of blast
        my %nonRed;
        open (BLASTOUT, "<", "$otherfilesDir/traingenes.good.nr.fa") or
            clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
            $useexisting, "ERROR in file " . __FILE__ ." at line "
            . __LINE__
            ."\nCould not open file $otherfilesDir/traingenes.good.nr.fa!\n");
        while ( <BLASTOUT> ) {
            chomp;
            if($_ =~ m/^\>(\S+)/){
                $nonRed{$1} = 1;
            }
        }
        close (BLASTOUT) or clean_abort(
            "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
            "ERROR in file " . __FILE__ ." at line ". __LINE__
            ."\nCould not close file $otherfilesDir/traingenes.good.nr.fa!\n" );

        open ( NONREDLOCI, ">", "$otherfilesDir/nonred.loci.lst") or
            clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
            $useexisting, "ERROR in file " . __FILE__ ." at line "
            . __LINE__
            ."\nCould not open file $otherfilesDir/nonred.loci.lst!\n");
        foreach ( keys %nonRed ) {
            print NONREDLOCI $txInGb3{$_}."\n";
        }
        close (NONREDLOCI) or clean_abort(
            "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
            "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nCould not close file $otherfilesDir/nonred.loci.lst!\n");

        # filter trainGb3 file for nonredundant loci
        $string = find(
            "filterGenesIn.pl",       $AUGUSTUS_BIN_PATH,
            $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
        );
        $errorfile     = "$errorfilesDir/filterGenesIn.stderr";
        $perlCmdString = "";
        if ($nice) {
            $perlCmdString .= "nice ";
        }
        $perlCmdString
            .= "perl $string $otherfilesDir/nonred.loci.lst $trainGb3 1> $trainGb4 2>$errorfile";
        print LOG "\# "
            . (localtime)
            . ": Filtering nonredundant loci into $trainGb4:\n" if ($v > 3);
        print LOG "$perlCmdString\n" if ($v > 3);
        system("$perlCmdString") == 0
            or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                $useexisting, "ERROR in file " . __FILE__ ." at line "
                . __LINE__ ."\nFailed to execute: $perlCmdString\n");

        # count how many genes are in trainGb4
        my $gb_good_size = count_genes_in_gb_file($trainGb4);
        if( $gb_good_size == 0){
            $prtStr = "\# "
                    . (localtime)
                    . " ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                    . "Number of reliable training genes is 0, so the parameters cannot "
                    . "be optimized. Recommended are at least 600 genes\n"
                    . "You may try running BRAKER instead.\n";
                print LOG $prtStr;
                clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, $prtStr);
        }

        # making trainGb4 the trainGb file
        $cmdString = "mv $trainGb4 $trainGb1";
        print LOG "\# "
            . (localtime)
            . ": Moving $trainGb4 to $trainGb1:\n" if ($v > 3);
        print LOG "$cmdString\n" if ($v > 3);
        system ("$cmdString") == 0 or clean_abort(
            "$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
            "ERROR in file " . __FILE__ ." at line ". __LINE__
            ."\nFailed to execute: $cmdString!\n");

        # split into training and test set
        if (!uptodate(
                ["$otherfilesDir/train.gb"],
                [   "$otherfilesDir/train.gb.test",
                    "$otherfilesDir/train.gb.train"
                ]
            )
            || $overwrite
            )
        {
            print LOG "\# "
                . (localtime)
                . ": Splitting genbank file into train and test file\n" if ($v > 3);
            $string = find(
                "randomSplit.pl",       $AUGUSTUS_BIN_PATH,
                $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
            );
            $errorfile = "$errorfilesDir/randomSplit.stderr";
            if ( $gb_good_size < 600 ) {
                $prtStr = "#*********\n"
                        . "# WARNING: Number of reliable training genes is low ($gb_good_size). "
                        . "Recommended are at least 600 genes\n"
                        . "#*********\n";
                print LOG $prtStr if ($v > 0);
                print STDOUT $prtStr if ($v > 0);
                $testsize1 = floor($gb_good_size/3);
                $testsize2 = floor($gb_good_size/3);
                if( $testsize1 == 0 or $testsize2 == 0 or ($gb_good_size - ($testsize1 + $testsize2)) == 0 ){
                    $prtStr = "\# "
                            . (localtime)
                            . " ERROR: in file " . __FILE__ ." at line "
                            . __LINE__ ."\nUnable to create three genbank"
                            . "files for optimizing AUGUSTUS (number of LOCI "
                            . "too low)! \n"
                            . "\$testsize1 is $testsize1, \$testsize2 is "
                            . "$testsize2, additional genes are "
                            . ($gb_good_size - ($testsize1 + $testsize2))
                            . "\nThe provided input data is not "
                            . "sufficient for running galba.pl!\n";
                    print LOG $prtStr;
                    clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                        $useexisting, $prtStr);
                }
            }elsif ( $gb_good_size >= 600 && $gb_good_size <= 1000 ) {
                $testsize1 = 200;
                $testsize2 = 200;
            }else{
                $testsize1 = 300;
                $testsize2 = 300;
            }
            $perlCmdString = "";
            if ($nice) {
                $perlCmdString .= "nice ";
            }
            $perlCmdString
                .= "perl $string $trainGb1 $testsize1 2>$errorfile";
            print LOG "$perlCmdString\n" if ($v > 3);
            system("$perlCmdString") == 0
                or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nFailed to execute: $perlCmdString\n");
            print LOG "\# "
                        . (localtime)
                        . ": $otherfilesDir/train.gb.test will be used for "
                        . "measuring AUGUSTUS accuracy after training\n" if ($v > 3);
            if($v > 3) {
                count_genes_in_gb_file("$otherfilesDir/train.gb.test");
                count_genes_in_gb_file("$otherfilesDir/train.gb.train");
            }
            $perlCmdString = "";
            if ($nice) {
                $perlCmdString .= "nice ";
            }
            $perlCmdString .= "perl $string $otherfilesDir/train.gb.train $testsize2 2>$errorfile";
            print LOG "$perlCmdString\n" if ($v > 3);
            system("$perlCmdString") == 0
                or clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species",
                    $useexisting, "ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nFailed to execute: $perlCmdString\n");

            if($v > 3) {
                count_genes_in_gb_file("$otherfilesDir/train.gb.train.train");
                count_genes_in_gb_file("$otherfilesDir/train.gb.train.test");
            }

            print LOG "\# "
                . (localtime)
                . ": $otherfilesDir/train.gb.train.test will be used or "
                . "measuring AUGUSTUS accuracy during training with "
                . "optimize_augustus.pl\n"
                . " $otherfilesDir/train.gb.train.train will be used for "
                . "running etraining in optimize_augustus.pl (together with "
                . "train.gb.train.test)\n"
                . " $otherfilesDir/train.gb.train will be used for running "
                . "etraining (outside of optimize_augustus.pl)\n" if ($v > 3);
        }

        # train AUGUSTUS for the first time
        if (!uptodate(
                [   "$otherfilesDir/train.gb.train",
                    "$otherfilesDir/train.gb.test"
                ],
                ["$otherfilesDir/firstetraining.stdout"]
            )
            )
        {
            # set "stopCodonExcludedFromCDS" to true
            print LOG "\# "
                . (localtime)
                . ": Setting value of \"stopCodonExcludedFromCDS\" in "
                . "$AUGUSTUS_CONFIG_PATH/species/$species/$species\_parameters.cfg "
                . "to \"true\"\n" if ($v > 3);
            setParInConfig(
                $AUGUSTUS_CONFIG_PATH
                    . "/species/$species/$species\_parameters.cfg",
                "stopCodonExcludedFromCDS", "true"
            );

            # first try with etraining
            $augpath    = "$AUGUSTUS_BIN_PATH/etraining";
            $errorfile  = "$errorfilesDir/firstetraining.stderr";
            $stdoutfile = "$otherfilesDir/firstetraining.stdout";
            $cmdString = "";
            if ($nice) {
                $cmdString .= "nice ";
            }
            $cmdString .= "$augpath --species=$species --AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH $otherfilesDir/train.gb.train 1>$stdoutfile 2>$errorfile";
            print LOG "\# " . (localtime) . ": first etraining\n" if ($v > 3);
            print LOG "$cmdString\n" if ($v > 3);
            system("$cmdString") == 0
                or die("ERROR in file " . __FILE__ ." at line "
                    . __LINE__ ."\nFailed to execute $cmdString\n");

            # set "stopCodonExcludedFromCDS" to false and run etraining again if necessary
            $t_b_t = $gb_good_size - $testsize1;
            my $err_stopCodonExcludedFromCDS;
            if ($nice) {
                print LOG "nice grep -c \"exon doesn't end in stop codon\" "
                    . "$errorfile\n" if ($v > 3);
                $err_stopCodonExcludedFromCDS = `nice grep -c "exon doesn't end in stop codon" $errorfile` if ($v > 3);
            }
            else {
                print LOG "grep -c \"exon doesn't end in stop codon\" "
                    . "$errorfile\n" if ($v > 3);
                $err_stopCodonExcludedFromCDS = `grep -c "exon doesn't end in stop codon" $errorfile` if ($v > 3);
            }
            my $err_rate = $err_stopCodonExcludedFromCDS
                / $t_b_t;
            print LOG "\# "
                . (localtime)
                . ": Error rate of missing stop codon is $err_rate\n"
                 if ($v > 3);
            if ( $err_rate >= 0.5 ) {
                print LOG "\# "
                    . (localtime)
                    . ": The appropriate value for \"stopCodonExcludedFromCDS\" "
                    . "seems to be \"false\".\n" if ($v > 3);
                print LOG "\# "
                    . (localtime)
                    . ": Setting value of \"stopCodonExcludedFromCDS\" in "
                    . "$AUGUSTUS_CONFIG_PATH/species/$species/$species\_parameters.cfg "
                    . "to \"false\"\n" if ($v > 3);
                setParInConfig(
                    $AUGUSTUS_CONFIG_PATH
                        . "/species/$species/$species\_parameters.cfg",
                    "stopCodonExcludedFromCDS",
                    "false"
                );
                print LOG "\# "
                    . (localtime)
                    . ": Running etraining again\n" if ($v > 3);
                print LOG "$cmdString\n" if ($v > 3);
                system("$cmdString") == 0
                    or die("ERROR in file " . __FILE__ ." at line "
                        . __LINE__ ."\nFailed to execute $cmdString\n");
            }

            # adjust the stop-codon frequency in species_parameters.cfg
            # according to train.out
            print LOG "\# "
                . (localtime)
                . ": Adjusting stop-codon frequencies in "
                . "species_parameters.cfg according to $stdoutfile\n"
                if ($v > 3);
            my $freqOfTag;
            my $freqOfTaa;
            my $freqOfTga;
            open( TRAIN, "$stdoutfile" )
                or die("ERROR in file " . __FILE__ ." at line ". __LINE__
                    . "\nCan not open file $stdoutfile!\n");
            while (<TRAIN>) {
                if (/tag:\s*.*\((.*)\)/) {
                    $freqOfTag = $1;
                }
                elsif (/taa:\s*.*\((.*)\)/) {
                    $freqOfTaa = $1;
                }
                elsif (/tga:\s*.*\((.*)\)/) {
                    $freqOfTga = $1;
                }
            }
            close(TRAIN) or die("ERROR in file " . __FILE__ ." at line "
                . __LINE__ ."\nCould not close gff file $stdoutfile!\n");
            if($ttable == 1){
                print LOG "\# "
                    . (localtime)
                    . ": Setting frequency of stop codons to tag=$freqOfTag, "
                    . "taa=$freqOfTaa, tga=$freqOfTga.\n" if ($v > 3);
                setParInConfig(
                    $AUGUSTUS_CONFIG_PATH
                        . "/species/$species/$species\_parameters.cfg",
                    "/Constant/amberprob", $freqOfTag
                );
                setParInConfig(
                    $AUGUSTUS_CONFIG_PATH
                        . "/species/$species/$species\_parameters.cfg",
                    "/Constant/ochreprob", $freqOfTaa
                );
                setParInConfig(
                    $AUGUSTUS_CONFIG_PATH
                        . "/species/$species/$species\_parameters.cfg",
                    "/Constant/opalprob", $freqOfTga
                );
            }elsif($ttable =~ m/^(10|25|30|31)$/){
                print LOG "\# " . (localtime)
                          . ": Setting frequency of stop codon opalprob (TGA) to 0\n" if ($v > 3);
                setParInConfig($AUGUSTUS_CONFIG_PATH . "/species/$species/$species\_parameters.cfg",
                               "/Constant/opalprob", 0);
                if(not($freqOfTga == 0)){ # distribute false probablity to the other two codons
                    $freqOfTaa = $freqOfTaa + $freqOfTga/2;
                    $freqOfTag = $freqOfTag + $freqOfTga/2;
                }
                setParInConfig(
                    $AUGUSTUS_CONFIG_PATH
                        . "/species/$species/$species\_parameters.cfg",
                    "/Constant/amberprob", $freqOfTag
                );
                setParInConfig(
                    $AUGUSTUS_CONFIG_PATH
                        . "/species/$species/$species\_parameters.cfg",
                    "/Constant/ochreprob", $freqOfTaa
                );
            }elsif($ttable =~ m/^(6|27|29)$/){
                        print LOG "\# " . (localtime)
                                  . ": Setting frequencies of stop codons ochreprob (TAA) and " 
                                  . "amberprob (TAG) to 0 and opalprob (TGA) to 1\n" if ($v > 3);
                        setParInConfig($AUGUSTUS_CONFIG_PATH . "/species/$species/$species\_parameters.cfg",
                            "/Constant/ochreprob", 0);
                        setParInConfig($AUGUSTUS_CONFIG_PATH . "/species/$species/$species\_parameters.cfg",
                            "/Constant/amberprob", 0);
                        setParInConfig( $AUGUSTUS_CONFIG_PATH . "/species/$species/$species\_parameters.cfg",
                            "/Constant/opalprob", 1);
            }
        }

        # first test
        if (!uptodate(
                [   "$otherfilesDir/train.gb.test"],
                ["$otherfilesDir/firsttest.stdout"]
            )
            || $overwrite
            )
        {
            $augpath    = "$AUGUSTUS_BIN_PATH/augustus";
            $errorfile  = "$errorfilesDir/firsttest.stderr";
            $stdoutfile = "$otherfilesDir/firsttest.stdout";
            $cmdString = "";
            if ($nice) {
                $cmdString .= "nice ";
            }
            $cmdString .= "$augpath --species=$species --AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH $otherfilesDir/train.gb.test 1>$stdoutfile 2>$errorfile";
            print LOG "\# "
                . (localtime)
                . ": First AUGUSTUS accuracy test\n" if ($v > 3);
            print LOG "$cmdString\n" if ($v > 3);
            system("$cmdString") == 0
                or die("ERROR in file " . __FILE__ ." at line ". __LINE__
                    . "\nFailed to execute: $cmdString!\n");
            $target_1 = accuracy_calculator($stdoutfile);
            print LOG "\# "
                . (localtime)
                . ": The accuracy after initial training "
                . "(no optimize_augustus.pl, no CRF) is $target_1\n"
                if ($v > 3);
        }

        # optimize parameters
        if ( !$skipoptimize ) {
            if (!uptodate(
                    [   "$otherfilesDir/train.gb.train.train",
                        "$otherfilesDir/train.gb.train.test"
                    ],
                    [   $AUGUSTUS_CONFIG_PATH
                            . "/species/$species/$species\_exon_probs.pbl",
                        $AUGUSTUS_CONFIG_PATH
                            . "/species/$species/$species\_parameters.cfg",
                        $AUGUSTUS_CONFIG_PATH
                            . "/species/$species/$species\_weightmatrix.txt"
                    ]
                )
                )
            {
                $string = find(
                    "optimize_augustus.pl", $AUGUSTUS_BIN_PATH,
                    $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
                );
                $errorfile  = "$errorfilesDir/optimize_augustus.stderr";
                $stdoutfile = "$otherfilesDir/optimize_augustus.stdout";
                my $k_fold = 8;
                if($CPU > 1){
                    for(my $i=1; $i<=$CPU; $i++){
                        if ($t_b_t/$i > 200){
                            $k_fold = $i;
                        }
                    }   
                }
                if($k_fold < 8) {
                    $k_fold = 8;
                }
                $perlCmdString = "";
                if ($nice) {
                    $perlCmdString .= "nice ";
                }
                $perlCmdString .= "perl $string ";
                if ($nice) {
                    $perlCmdString .= "--nice=1 "
                }
                $perlCmdString  .= "--aug_exec_dir=$AUGUSTUS_BIN_PATH --rounds=$rounds "
                                 . "--species=$species "
                                 . "--kfold=$k_fold "
                                 . "--AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH "
                                 . "--onlytrain=$otherfilesDir/train.gb.train.train ";
                if($CPU > 1) {
                    $perlCmdString .= "--cpus=$k_fold ";
                }
                $perlCmdString  .= "$otherfilesDir/train.gb.train.test "
                                . "1>$stdoutfile 2>$errorfile";
                print LOG "\# "
                    . (localtime)
                    . ": optimizing AUGUSTUS parameters\n" if ($v > 3);
                print LOG "$perlCmdString\n" if ($v > 3);
                system("$perlCmdString") == 0
                    or die("ERROR in file " . __FILE__ ." at line ". __LINE__
                        . "\nFailed to execute: $perlCmdString!\n");
                print LOG "\# "
                    . (localtime)
                    . ":  parameter optimization finished.\n" if ($v > 3);
            }
        }

        # train AUGUSTUS for the second time
        if (!uptodate(
                ["$otherfilesDir/train.gb.train"],
                ["$otherfilesDir/secondetraining.stdout"]
            )
            )
        {
            $augpath    = "$AUGUSTUS_BIN_PATH/etraining";
            $errorfile  = "$errorfilesDir/secondetraining.stderr";
            $stdoutfile = "$otherfilesDir/secondetraining.stdout";
            $cmdString = "";
            if ($nice) {
                $cmdString .= "nice ";
            }
            $cmdString .= "$augpath --species=$species "
                       .  "--AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH "
                       .  "$otherfilesDir/train.gb.train 1>$stdoutfile "
                       .  "2>$errorfile";
            print LOG "\# " . (localtime) . ": Second etraining\n" if ($v > 3);
            print LOG "$cmdString\n" if ($v > 3);
            system("$cmdString") == 0
                or die("ERROR in file " . __FILE__ ." at line ". __LINE__
                    . "\nFailed to execute: $cmdString!\n");
        }

        # second test
        if (!uptodate(
                [   "$otherfilesDir/train.gb.test"],
                ["$otherfilesDir/secondtest.out"]
            )
            || $overwrite
            )
        {
            $augpath    = "$AUGUSTUS_BIN_PATH/augustus";
            $errorfile  = "$errorfilesDir/secondtest.stderr";
            $stdoutfile = "$otherfilesDir/secondtest.stdout";
            $cmdString = "";
            if ($nice) {
                $cmdString .= "nice ";
            }
            $cmdString
                .= "$augpath --species=$species "
                .  "--AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH "
                .  "$otherfilesDir/train.gb.test >$stdoutfile 2>$errorfile";
            print LOG "\# "
                . (localtime)
                . ": Second AUGUSTUS accuracy test\n" if ($v > 3);
            print LOG "$cmdString\n";
            system("$cmdString") == 0
                or die("ERROR in file " . __FILE__ ." at line ". __LINE__
                    . "\nFailed to execute: $cmdString\n");
            $target_2 = accuracy_calculator($stdoutfile);
            print LOG "\# " . (localtime) . ": The accuracy after training "
                . "(after optimize_augustus.pl, no CRF) is $target_2\n"
                if ($v > 3);
        }

        # optional CRF training
        if ($crf) {
            if (!uptodate(
                    ["$otherfilesDir/train.gb.train"],
                    ["$otherfilesDir/crftraining.stdout"]
                )
                || $overwrite
                )
            {
                $augpath = "$AUGUSTUS_BIN_PATH/etraining";
            }
            $errorfile  = "$errorfilesDir/crftraining.stderr";
            $stdoutfile = "$otherfilesDir/crftraining.stdout";
            $cmdString = "";
            if ($nice) {
                $cmdString .= "nice ";
            }
            $cmdString .= "$augpath --species=$species --CRF=1 "
                       .  "--AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH "
                       .  "$otherfilesDir/train.gb.train 1>$stdoutfile "
                       .  "2>$errorfile";
            print LOG "\# "
                . (localtime)
                . ": Third etraining - now with CRF\n" if ($v > 3);
            print LOG "$cmdString\n" if ($v > 3);
            system("$cmdString") == 0
                or die("ERROR in file " . __FILE__ ." at line ". __LINE__
                    . "\nfailed to execute: $cmdString\n");
            print LOG "\# "
                . (localtime)
                . ": etraining with CRF finished.\n" if ($v > 3);

            # third test
            if (!uptodate(
                    ["$otherfilesDir/train.gb.test"],
                    ["$otherfilesDir/thirdtest.out"]
                )
                || $overwrite
                )
            {
                $augpath    = "$AUGUSTUS_BIN_PATH/augustus";
                $errorfile  = "$errorfilesDir/thirdtest.stderr";
                $stdoutfile = "$otherfilesDir/thirdtest.stdout";
                $cmdString = "";
                if ($nice) {
                    $cmdString .= "nice ";
                }
                $cmdString .= "$augpath --species=$species "
                           .  "--AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH "
                           .  "$otherfilesDir/train.gb.test >$stdoutfile "
                           .  "2>$errorfile";
                print LOG "\# "
                    . (localtime)
                    . ": Third AUGUSTUS accuracy test\n" if ($v > 3);
                print LOG "$cmdString\n" if ($v > 3);
                system("$cmdString") == 0
                    or die("ERROR in file " . __FILE__ ." at line ". __LINE__
                        . "\nFailed to execute: $cmdString\n");
                $target_3 = accuracy_calculator($stdoutfile);
                print LOG "\# ". (localtime) . ": The accuracy after CRF "
                    . "training is $target_3\n" if ($v > 3);
            }

            # decide on whether to keep CRF parameters
            if ( $target_2 > $target_3 && !$keepCrf ) {
                print LOG "\# "
                    . (localtime)
                    . ": CRF performance is worse than HMM performance, "
                    . "reverting to usage of HMM paramters.\n" if ($v > 3);
            }
            else {
                print LOG "\# "
                    . (localtime)
                    . ": CRF performance is better than HMM performance, "
                    . "keeping CRF paramters.\n" if ($v > 3);
            }

            # cp config files
            print LOG "\# "
                . (localtime)
                . ": Copying parameter files to $species*.CRF\n" if ($v > 3);
            for (
                (   "$species" . "_exon_probs.pbl",
                    "$species" . "_igenic_probs.pbl",
                    "$species" . "_intron_probs.pbl"
                )
                )
            {
                $cmdString = "cp $AUGUSTUS_CONFIG_PATH/species/$species/$_ "
                           . "$AUGUSTUS_CONFIG_PATH/species/$species/$_" . ".CRF";
                print LOG "$cmdString\n" if ($v > 3);
                system("$cmdString") == 0
                    or die("ERROR in file " . __FILE__ ." at line ". __LINE__
                        . "\nfailed to execute: $cmdString\n");
            }

            # if the accuracy doesn't improve with CRF, overwrite the config
            # files with the HMM parameters from last etraining
            if ( ( $target_2 > $target_3 ) && !$keepCrf ) {
                print LOG "\# "
                    . (localtime)
                    . ": overwriting parameter files resulting from CRF "
                    . "training with original HMM files\n" if ($v > 3);
                for (
                    (   "$species" . "_exon_probs.pbl",
                        "$species" . "_igenic_probs.pbl",
                        "$species" . "_intron_probs.pbl"
                    )
                    )
                {
                    $cmdString
                        = "rm $AUGUSTUS_CONFIG_PATH/species/$species/$_";
                    print LOG "$cmdString\n" if ($v > 3);
                    system("$cmdString") == 0
                        or die("ERROR in file " . __FILE__ ." at line "
                            . __LINE__ ."\nFailed to execute: $cmdString\n");
                    print LOG "$cmdString\n" if ($v > 3);
                    $cmdString
                        = "cp $AUGUSTUS_CONFIG_PATH/species/$species/$_"
                        . ".HMM $AUGUSTUS_CONFIG_PATH/species/$species/$_";
                    system("$cmdString") == 0
                        or die("ERROR in file " . __FILE__ ." at line "
                            . __LINE__ ."\nFailed to execute: $cmdString\n");
                }
            }
        }
    }

    # copy species files to working directory
    if ( !-d "$parameterDir/$species" ) {
        $cmdString = "";
        if ($nice) {
            $cmdString .= "nice ";
        }
        $cmdString
            .= "cp -r $AUGUSTUS_CONFIG_PATH/species/$species $parameterDir";
        print LOG "\# "
            . (localtime)
            . ": Copying optimized parameters to working directory"
            . " $parameterDir\n" if ($v > 3);
        print LOG "$cmdString\n" if ($v > 3);
        system("$cmdString") == 0 or die("ERROR in file " . __FILE__
            ." at line ". __LINE__ ."\nFailed to execute: $cmdString!\n");
    }
}

####################### fix_ifs_genes ##########################################
# * AUGUSTUS sometimes predicts genes with in frame stop codons (IFSs)
#   if the stop codon is spliced/contains an intron
# * this function re-predicts in regions with IFSs genes using AUGUSTUS mea
#   (instead of Viterbi)
# * arguments:
#   $label -> unique identifier for the AUGUSTUS run that is postprocessed
#   $gtf_in -> gtf output file of AUGUSTUS run
#   $bad_lst -> output file of getAnnoFastaFromJoingenes.py
#   $utr_here -> on/off
#   $spec -> augustus species name 
#   $aug_c_p -> AUGUSTUS_CONFIG_PATH
#   $aug_b_p -> AUGUSTUS_BIN_PATH
#   $aug_s_p -> AUGUSTUS_SCRIPTS_PATH
#   Optional:
#   $h_file -> hints file for this AUGUSTUS run
#   $cfg_file -> extrinsic config file for hints
################################################################################

sub fix_ifs_genes{
    my ($label, $gtf_in, $bad_lst, $utr_here, $spec, 
         $aug_c_p, $aug_b_p, $aug_s_p, $h_file, $cfg_file) = @_;
    #print("Overview of fix_ifs_genes arguments:\n");
    #foreach(@_){
    #    print $_."\n";
    #}
    my $fix_ifs_out_stem = $label."_fix_ifs_";
    my $print_utr_here = "off";
    if($utr_here eq "on"){
        $print_utr_here = "on";
    }
    print LOG "\# " . (localtime) . ": fixing AUGUSTUS genes with in frame "
            . "stop codons...\n" if ($v > 2);
    $string = find( "fix_in_frame_stop_codon_genes.py", $aug_b_p, 
        $aug_s_p, $aug_c_p );
    my $cmdStr = $PYTHON3_PATH . "/python3 " . $string ." -g " . $genome 
               . " -t $gtf_in -b $bad_lst -o $fix_ifs_out_stem -s $spec ";
    if($soft_mask){
        $cmdStr .= "-m on ";
    }else{
        $cmdStr .= "-m off ";
    }
    $cmdStr .= "--UTR $utr_here --print_utr $print_utr_here -a $aug_c_p "
             . "-C $CDBTOOLS_PATH -A $aug_b_p -S $aug_s_p ";
    if ( defined($h_file) and defined($cfg_file) ) {
        $cmdStr .= "-H $h_file -e $cfg_file ";
    }
    $cmdStr .= " > $otherfilesDir/fix_in_frame_stop_codon_genes_".$label.".log "
            ."2> $errorfilesDir/fix_in_frame_stop_codon_genes_".$label.".err";
    print LOG $cmdStr . "\n"  if ($v > 3);
    system("$cmdStr") == 0
            or die("ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nFailed to execute: $cmdStr\n");
    print LOG "\# " . (localtime) . ": Moving gene prediction file "
                    . "without in frame stop codons to location of "
                    . "original file (overwriting it)...\n" if ($v > 2);
    $cmdStr = "mv $otherfilesDir/$label"."_fix_ifs_".".gtf $gtf_in";
    print LOG $cmdStr."\n" if ($v > 3);
    system("$cmdStr") == 0
        or die("ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nFailed to execute: $cmdStr\n");
    $cmdStr = "rm $otherfilesDir/bad_genes.lst\n";
    print LOG "\# " . (localtime) . ": Deleting file with genes with in frame "
                    . "stop codons...\n";
    print LOG $cmdStr;
    unlink("$otherfilesDir/bad_genes.lst");
}


####################### count_genes_in_gb_file #################################
# * return count of LOCUS tags in genbank file
################################################################################

sub count_genes_in_gb_file {
    my $gb_file = shift;
    open (GBFILE, "<", $gb_file) or
        clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
        "\# " . (localtime)
        . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
        . "Could not open file $gb_file!\n");
    my $nLociGb = 0;
    while ( <GBFILE> ) {
        if($_ =~ m/LOCUS/) {
            $nLociGb++;
        }
    }
    close (GBFILE) or
        clean_abort("$AUGUSTUS_CONFIG_PATH/species/$species", $useexisting,
        "\# " . (localtime)
        . ": ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
        . "Could not close file $gb_file!\n");
    print LOG "\# " . (localtime)
        . ": Genbank format file $gb_file contains $nLociGb genes.\n";
    return $nLociGb;
}

####################### accuracy_calculator ####################################
# * accuracy_calculator for assessing accuracy during training AUGUSTUS
################################################################################

sub accuracy_calculator {
    my $aug_out = shift;
    print LOG "\# " . (localtime) . ": Computing accuracy of AUGUSTUS "
        ."prediction (in test file derived from predictions on training data "
        . "set stored in $aug_out)\n" if ($v > 2);
    my ( $nu_sen, $nu_sp, $ex_sen, $ex_sp, $gen_sen, $gen_sp );
    open( AUGOUT, "$aug_out" ) or die("ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nCould not open $aug_out!\n");
    while (<AUGOUT>) {
        if (/^nucleotide level\s*\|\s*(\S+)\s*\|\s*(\S+)/) {
            $nu_sen = $1;
            $nu_sp  = $2;
        }
        if (/^exon level\s*\|.*\|.*\|.*\|.*\|.*\|\s*(\S+)\s*\|\s*(\S+)/) {
            $ex_sen = $1;
            $ex_sp  = $2;
        }
        if (/^gene level\s*\|.*\|.*\|.*\|.*\|.*\|\s*(\S+)\s*\|\s*(\S+)/) {
            $gen_sen = $1;
            $gen_sp  = $2;
        }
    }
    my $target
        = (   3 * $nu_sen
            + 2 * $nu_sp
            + 4 * $ex_sen
            + 3 * $ex_sp
            + 2 * $gen_sen
            + 1 * $gen_sp ) / 15;
    return $target;
}

####################### compute_flanking_region ################################
# * compute flanking region size for AUGUSTUS training genes in genbank format
################################################################################

sub compute_flanking_region {
    print LOG "\# " . (localtime) . ": Computing flanking region size for "
        . "AUGUSTUS training genes\n" if ($v > 2);
    my $gtf  = shift;
    my $size = 0;
    my %gene;
    open( GTF, "<", $gtf ) or die("ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nCould not open file $gtf!\n");
    while (<GTF>) {
        if (m/\tCDS\t/) {
            chomp;
            my @gtfLine = split(/\t/);
            $gtfLine[8] =~ m/gene_id \"(\S+)\"/;
            if( not( defined( $gene{$1}{'start'} ) ) ) {
                $gene{$1}{'start'} = min( $gtfLine[3], $gtfLine[4] );
            }elsif( $gene{$1}{'start'} > min( $gtfLine[3], $gtfLine[4] ) ) {
                $gene{$1}{'start'} = min( $gtfLine[3], $gtfLine[4] );
            }
            if( not( defined( $gene{$1}{'stop'} ) ) ) {
                $gene{$1}{'stop'} = max($gtfLine[3], $gtfLine[4]);
            }elsif( $gene{$1}{'stop'} < max( $gtfLine[3], $gtfLine[4] ) ) {
                $gene{$1}{'stop'} = max( $gtfLine[3], $gtfLine[4] );
            }
        }
    }
    close(GTF) or die("ERROR in file " . __FILE__ ." at line ". __LINE__
        ."\nCould not close file $gtf!\n");
    my $nGenes   = 0;
    my $totalLen = 0;
    my $avLen    = 0;
    foreach my $key ( keys %gene ) {
        $nGenes++;
        $totalLen += $gene{$key}{'stop'} - $gene{$key}{'start'} +1
    }
    $avLen = $totalLen / $nGenes;
    $size = min( ( floor( $avLen / 2 ), 10000 ) );
    if ( $size < 0 ) {
        print LOG "#*********\n"
                . "# WARNING: \$flanking_DNA has the value $size , which is "
                . "smaller than 0. Something must have gone wrong, there. "
                . "Replacing by value 10000.\n"
                . "#*********\n" if ($v > 0);
        $size = 10000;
    }
    return $size;
}

####################### gtf2gb #################################################
# * convert gtf and genome file to genbank file for training AUGUSTUS
################################################################################

sub gtf2gb {
    my $gtf = shift;
    print LOG "\# " . (localtime) . ": Converting gtf file $gtf to genbank "
        . "file\n" if ($v > 2);
    my $gb  = shift;
    if( not( defined( $flanking_DNA ) ) ) {
        $flanking_DNA = compute_flanking_region($gtf);
    }
    $string       = find(
        "gff2gbSmallDNA.pl",    $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    if ( !uptodate( [ $genome, $gtf ], [$gb] ) || $overwrite ) {
        my @pathName = split( /\//, $gtf );
        $errorfile
            = "$errorfilesDir/"
            . $pathName[ ( scalar(@pathName) - 1 ) ]
            . "_gff2gbSmallDNA.stderr";
        if ( -z $gtf ) {
            $prtStr
                = "\# "
                . (localtime)
                . " ERROR: in file " . __FILE__ ." at line ". __LINE__ ."\n"
                . "The training gene file $gtf file is empty!\n";
            print LOG $prtStr;
            print STDERR $prtStr;
            exit(1);
        }
        $perlCmdString = "";
        if ($nice) {
            $perlCmdString .= "nice ";
        }
        $perlCmdString
            .= "perl $string $gtf $genome $flanking_DNA $gb 2>$errorfile";
        print LOG "\# " . (localtime) . ": create genbank file $gb\n"
            if ($v > 3);
        print LOG "$perlCmdString\n" if ($v > 3);
        system("$perlCmdString") == 0
            or die("ERROR in file " . __FILE__ ." at line ". __LINE__
                . "\nFailed to execute: $perlCmdString\n");
        print LOG "#*********\n"
                . "# INFORMATION: the size of flanking region used in this "
                . "GALBA run is $flanking_DNA".". You might need this "
                . "value if you later add a UTR training on top of an "
                . "already existing GALBA run.\n"
                . "#*********\n" if ($v > 0);
    }
}

####################### augustus ###############################################
# * predict genes with AUGUSTUS
# * ab initio, if enabled
# * with hints
#   if RNA-Seq and protein hints, two separate AUGUSTUS runs are performed
#   1) RNA-Seq only
#   2) RNA-Seq and protein (with higher weight on protein)
#   subsequently, prediction sets are joined with joingenes
# * with ep hints (RNA-Seq) and all other hints and UTR parameters
################################################################################

sub augustus {
    my $localUTR = shift;
    my $genesetId = "";
    if( $localUTR eq "on" ) {
        $genesetId = "_utr";
    }
    print LOG "\# " . (localtime) . ": RUNNING AUGUSTUS\n" if ($v > 2);

    print CITE $pubs{'aug-cdna'}; $pubs{'aug-cdna'} = "";
    print CITE $pubs{'aug-hmm'}; $pubs{'aug-hmm'} = "";

    $augpath = "$AUGUSTUS_BIN_PATH/augustus";
    my @genome_files;
    my $genome_dir = "$otherfilesDir/genome_split";
    my $augustus_dir           = "$otherfilesDir/augustus_tmp$genesetId";
    my $augustus_dir_ab_initio = "$otherfilesDir/augustus_ab_initio_tmp$genesetId";

    if( $CPU > 1 ) {
        prepare_genome( $genome_dir );
    }

    if (!uptodate( [ $extrinsicCfgFile, $hintsfile, $genome ],
        ["$otherfilesDir/augustus.hints$genesetId.gtf"] ) || $overwrite)
    {
        if ( $CPU > 1 ) {
            # single ex.cfg scenarios are:
            # trainFromGth -> gth.cfg
            if ( ($foundProt>0 && $foundRNASeq==0) || ($foundProt==0 && $foundRNASeq > 0)) {
                if(defined($extrinsicCfgFile1) && $localUTR eq "off"){
                    $extrinsicCfgFile = $extrinsicCfgFile1;
                }elsif(defined($extrinsicCfgFile2) && $localUTR eq "on"){
                    $extrinsicCfgFile = $extrinsicCfgFile2;
                }else{
                    if ( $foundProt>0 && $foundRNASeq==0 ){
                        if (defined($prg)){
                            if ( $localUTR eq "off" ) {
                                assign_ex_cfg ("gth.cfg");
                            } else {
                                assign_ex_cfg ("gth_utr.cfg");
                            }
                        }
                    } elsif ( $foundProt==0 && $foundRNASeq > 0){
                        if ( $localUTR eq "off" ) {
                            assign_ex_cfg ("rnaseq.cfg");
                        } else {
                            assign_ex_cfg ("rnaseq_utr.cfg");
                        }
                    }
                }
                copy_ex_cfg($extrinsicCfgFile, "ex1$genesetId.cfg");
                my $hintId = "hints".$genesetId;
                make_hints_jobs( $augustus_dir, $genome_dir, $hintsfile,
                    $extrinsicCfgFile, $localUTR, $hintId );
                run_augustus_jobs( "$otherfilesDir/$hintId.job.lst" );
                join_aug_pred( $augustus_dir, "$otherfilesDir/augustus.$hintId.gff" );
                make_gtf("$otherfilesDir/augustus.$hintId.gff");
                if(not($skip_fixing_broken_genes)){
                    get_anno_fasta("$otherfilesDir/augustus.$hintId.gtf", "tmp");
                    if(-e "$otherfilesDir/bad_genes.lst"){
                        fix_ifs_genes("augustus.$hintId", 
                              "$otherfilesDir/augustus.$hintId.gtf", 
                               $otherfilesDir."/bad_genes.lst", $localUTR, $species, 
                               $AUGUSTUS_CONFIG_PATH, $AUGUSTUS_BIN_PATH, 
                               $AUGUSTUS_SCRIPTS_PATH, $hintsfile, $extrinsicCfgFile);
                    }
                }
                if (!$skipGetAnnoFromFasta) {
                    get_anno_fasta("$otherfilesDir/augustus.$hintId.gtf", $hintId);
                }
                clean_aug_jobs($hintId);
            }else{
                run_augustus_with_joingenes_parallel($genome_dir, $localUTR, $genesetId);
            }
        } else {
            push( @genome_files, $genome );
            if ( ($foundProt>0 && $foundRNASeq==0) || ($foundProt==0 && $foundRNASeq > 0)) {
                if(defined($extrinsicCfgFile1) && $localUTR eq "off"){
                    $extrinsicCfgFile = $extrinsicCfgFile1;
                }elsif(defined($extrinsicCfgFile2) && $localUTR eq "on"){
                    $extrinsicCfgFile = $extrinsicCfgFile2;
                }else{
                    if ( $foundProt>0 && $foundRNASeq==0 ){
                        if (defined($prg)) {
                            if ( $localUTR eq "off" ) {
                                assign_ex_cfg ("gth.cfg");
                            } else {
                                assign_ex_cfg ("gth_utr.cfg");
                            }
                        }
                    } elsif ( $foundProt==0 && $foundRNASeq > 0) {
                        if ( $localUTR eq "off") {
                            assign_ex_cfg ("rnaseq.cfg");
                        } else {
                            assign_ex_cfg ("rnaseq_utr.cfg");
                        }
                    }
                }
                my $hintId = "hints".$genesetId;
                copy_ex_cfg($extrinsicCfgFile, "ex1$genesetId.cfg");
                run_augustus_single_core_hints( $hintsfile, $extrinsicCfgFile,
                    $localUTR, $hintId);
                make_gtf("$otherfilesDir/augustus.$hintId.gff");
                if(not($skip_fixing_broken_genes)){
                    get_anno_fasta("$otherfilesDir/augustus.$hintId.gtf", "tmp");
                    if(-e "$otherfilesDir/bad_genes.lst"){
                        fix_ifs_genes("augustus.$hintId", 
                              "$otherfilesDir/augustus.$hintId.gtf", 
                               $otherfilesDir."/bad_genes.lst", $localUTR, $species, 
                               $AUGUSTUS_CONFIG_PATH, $AUGUSTUS_BIN_PATH, 
                               $AUGUSTUS_SCRIPTS_PATH, $hintsfile, $extrinsicCfgFile);
                    }
                }
                if (!$skipGetAnnoFromFasta) {
                    get_anno_fasta("$otherfilesDir/augustus.$hintId.gtf", $hintId);
                }
            }else{
                run_augustus_with_joingenes_single_core($localUTR, $genesetId);
            }
        }
        print LOG "\# " . (localtime) . ": AUGUSTUS prediction complete\n"
            if ($v > 3);
    }
}

####################### assign_ex_cfg ##########################################
# * predict genes with AUGUSTUS
# * ab initio, if enabled
# * with hints
#   if RNA-Seq and protein hints, two separate AUGUSTUS runs are performed
#   1) RNA-Seq only
#   2) RNA-Seq and protein (with higher weight on protein)
#   subsequently, prediction sets are joined with joingenes
################################################################################

sub assign_ex_cfg {
    my $thisCfg = shift;
    $string = find( "cfg/".$thisCfg, $AUGUSTUS_BIN_PATH, $AUGUSTUS_SCRIPTS_PATH,
        $AUGUSTUS_CONFIG_PATH );
    if ( -e $string ) {
        $extrinsicCfgFile = $string;
    }
    else {
        $prtStr = "#*********\n"
                . "# WARNING: tried to assign extrinsicCfgFile $thisCfg as "
                . "$string but this file does not seem to exist.\n"
                . "#*********\n";
        $logString .= $prtStr if ($v > 0);
        $extrinsicCfgFile = undef;
    }
}

####################### prepare_genome #########################################
# * split genome for parallel AUGUSTUS execution
################################################################################

sub prepare_genome {
    my $augustus_dir = shift;
    # check whether genome has been split, already, cannot use uptodate because
    # name of resulting files is unknown before splitting genome file
    my $foundFastaFile;
    if( -d $augustus_dir ) {
        opendir(DIR, $augustus_dir) or die ("ERROR in file " . __FILE__
            . " at line ". __LINE__
            . "\nFailed to open directory $augustus_dir!\n");
        while(my $f = readdir(DIR)) {
            if($f =~ m/\.fa$/) {
                $foundFastaFile = 1;
            }
        }
        closedir(DIR)
    }

    if( not( $foundFastaFile ) || $overwrite ) {
        # if augustus_dir already has contents, this leads to problems with
        # renaming fasta files, therefore delete the entire directory in case
        # of $overwrite
        if( $overwrite && -d $augustus_dir ) {
            rmtree( $augustus_dir ) or die ("ERROR in file " . __FILE__
            . " at line ". __LINE__
            . "\nFailed recursively delete directory $augustus_dir!\n");
        }

        print LOG "\# " . (localtime) . ": Preparing genome for running "
            . "AUGUSTUS in parallel\n" if ($v > 2);

        if ( not( -d $augustus_dir ) ) {
            print LOG "\# "
                . (localtime)
                . ": Creating directory for storing AUGUSTUS files (hints, "
                . "temporarily) $augustus_dir.\n" if ($v > 3);
            mkdir $augustus_dir or die ("ERROR in file " . __FILE__ ." at line "
                . __LINE__ ."\nFailed to create directory $augustus_dir!\n");
        }
        print LOG "\# "
            . (localtime)
            . ": splitting genome file in smaller parts for parallel execution of "
            . "AUGUSTUS prediction\n" if ($v > 3);
        $string = find(
            "splitMfasta.pl",       $AUGUSTUS_BIN_PATH,
            $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH);
        $errorfile = "$errorfilesDir/splitMfasta.stderr";
        $perlCmdString = "";
        if ($nice) {
            $perlCmdString .= "nice ";
        }
        $perlCmdString
            .= "perl $string $genome --outputpath=$augustus_dir 2>$errorfile";
        print LOG "$perlCmdString\n" if ($v > 3);
        system("$perlCmdString") == 0
            or die("ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nFailed to execute: $perlCmdString\n");

        # rename files according to scaffold name
        $cmdString = "cd $augustus_dir; for f in genome.split.*; "
                   . "do NAME=`grep \">\" \$f`; mv \$f \${NAME#>}.fa; "
                   . "done; cd ..\n";
        print LOG $cmdString if ($v > 3);
        system("$cmdString") == 0
            or die("ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nFailed to execute: $cmdString\n");
        my @genome_files = `ls $augustus_dir`;
        print LOG "\# " . (localtime) . ": Split genome file in "
        . scalar(@genome_files) . " parts, finished.\n" if ($v > 3);
    }else{
        print LOG "\# " . (localtime) . ": Skipping splitMfasta.pl because "
            . "genome file has already been split.\n" if ($v > 3);
    }
}

####################### make_hints_jobs ########################################
# * make AUGUSTUS hints jobs (parallelization)
################################################################################

sub make_hints_jobs{
    my $augustus_dir = shift;
    my $genome_dir = shift;
    my $thisHintsfile = shift;
    my $cfgFile = shift;
    my $localUTR = shift;
    my $hintId = shift;
    if( !uptodate([$genome, $thisHintsfile], ["$otherfilesDir/aug_$hintId.lst"] 
        ) || $overwrite ) {
        print LOG "\# " . (localtime) . ": Making AUGUSTUS jobs with hintsfile "
            . "$thisHintsfile, cfgFile $cfgFile, UTR status $localUTR, and hintId "
            . "$hintId\n" if ($v > 2);
        my @genome_files = `ls $genome_dir`;
        my %scaffFileNames;
        foreach (@genome_files) {
            chomp;
            $_ =~ m/(.*)\.\w+$/;
            $scaffFileNames{$1} = "$genome_dir/$_";
        }  
        if ( not( -d $augustus_dir ) && $CPU > 1) {
            print LOG "\# " . (localtime)
                . ": Creating directory for storing AUGUSTUS files (hints, "
                . "temporarily) $augustus_dir.\n" if ($v > 3);
            mkdir $augustus_dir or die ("ERROR in file " . __FILE__ ." at line "
                . __LINE__ ."\nFailed to create directory $augustus_dir!\n");
        }
        print LOG "\# "
            . (localtime)
            . ": creating $otherfilesDir/aug_$hintId.lst for AUGUSTUS jobs\n" 
            if ($v > 3);
        open( ALIST, ">", "$otherfilesDir/aug_$hintId.lst" )
            or die("ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nCould not open file $otherfilesDir/aug_$hintId.lst!\n");
        # make list for creating augustus jobs
        while ( my ( $locus, $size ) = each %scaffSizes ) {
            print ALIST "$scaffFileNames{$locus}\t$thisHintsfile\t1\t$size\n";
        }
        close(ALIST) or die("ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nCould not close file $otherfilesDir/aug_$hintId.lst!\n");
    }else{
        print LOG "\# " . (localtime) . ": Skip making AUGUSTUS job list file "
            . " with hintsfile $thisHintsfile and hintId $hintId because "
            . "$otherfilesDir/aug_$hintId.lst is up to date.\n" if ($v > 3);
    }
    if( !uptodate(["$otherfilesDir/aug_$hintId.lst"], 
        ["$otherfilesDir/$hintId.job.lst"]) || $overwrite ) {
        print LOG "\# " . (localtime)
            . ": creating AUGUSTUS jobs (with $hintId)\n" if ($v > 3);
        $string = find(
            "createAugustusJoblist.pl", $AUGUSTUS_BIN_PATH,
            $AUGUSTUS_SCRIPTS_PATH,     $AUGUSTUS_CONFIG_PATH );
        $errorfile = "$errorfilesDir/createAugustusJoblist_$hintId.stderr";
        $perlCmdString = "";
        $perlCmdString .= "cd $otherfilesDir\n";
        if ($nice) {
            $perlCmdString .= "nice ";
        }
        $perlCmdString .= "perl $string --sequences=$otherfilesDir/aug_$hintId.lst --wrap=\"#!/bin/bash\" --overlap=500000 --chunksize=$chunksize --outputdir=$augustus_dir "
                       .  "--joblist=$otherfilesDir/$hintId.job.lst --jobprefix=aug_".$hintId."_ --partitionHints --command \"$augpath --species=$species --AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH "
                       .  "--extrinsicCfgFile=$cfgFile --alternatives-from-evidence=$alternatives_from_evidence --UTR=$localUTR --exonnames=on --codingseq=on "
                       .  "--allow_hinted_splicesites=gcag,atac ";
        if ( defined($optCfgFile) ) {
            $perlCmdString .= " --optCfgFile=$optCfgFile";
        }
        if ($soft_mask) {
            $perlCmdString .= " --softmasking=1";
        }
        if ($augustus_args) {
            $perlCmdString .= " $augustus_args";
        }
        $perlCmdString .= "\" 2>$errorfile\n";
        $perlCmdString .= "cd ..\n";
        print LOG "$perlCmdString" if ($v > 3);
        system("$perlCmdString") == 0
            or die("ERROR in file " . __FILE__ ." at line "
            . __LINE__ ."\nFailed to execute: $perlCmdString\n");
    }else{
        print LOG "\# " . (localtime) . ": Skip making AUGUSTUS jobs with "
            . "hintsfile $thisHintsfile and hintId $hintId because "
            . "$otherfilesDir/$hintId.job.lst is up to date.\n" if ($v > 3);
    }
}

####################### make_ab_initio_jobs ####################################
# * make AUGUSTUS ab initio jobs (parallelization)
################################################################################

sub make_ab_initio_jobs{
    my $augustus_dir_ab_initio = shift;
    my $augustus_dir = shift;
    my $localUTR = shift;
    my $genesetId = shift;
    if( !uptodate( [$genome], ["$otherfilesDir/augustus_ab_initio.lst"])
        || $overwrite ) {
        print LOG "\# " . (localtime) . ": Creating AUGUSTUS ab initio jobs\n"
            if ($v > 2);
        my @genome_files = `ls $augustus_dir`;
        my %scaffFileNames;
        foreach (@genome_files) {
            chomp;
            $_ =~ m/(.*)\.\w+$/;
            $scaffFileNames{$1} = "$augustus_dir/$_";
        }
        if ( not( -d $augustus_dir_ab_initio ) && $CPU > 1) {
            print LOG "\# " . (localtime)
                . ": Creating directory for storing AUGUSTUS files (ab initio, "
                . "temporarily) $augustus_dir_ab_initio.\n" if ($v > 3);
            mkdir $augustus_dir_ab_initio or die ("ERROR in file " . __FILE__
                . " at line ". __LINE__
                ."\nFailed to create directory $augustus_dir_ab_initio!\n");
        }
        print LOG "\# " . (localtime)
            . ": creating $otherfilesDir/aug_ab_initio.lst for AUGUSTUS jobs\n"
            if ($v > 3);
        open( ILIST, ">", "$otherfilesDir/aug_ab_initio.lst" )
            or die(
            "ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nCould not open file $otherfilesDir/aug_ab_initio.lst!\n" );
        while ( my ( $locus, $size ) = each %scaffSizes ) {
            print ILIST "$scaffFileNames{$locus}\t1\t$size\n";
        }
        close(ILIST) or die(
            "ERROR in file " . __FILE__ ." at line ". __LINE__
            ."\nCould not close file $otherfilesDir/aug_ab_initio.lst!\n" );
    } else {
        print LOG "\# " . (localtime)
            . ": Using existing file  $otherfilesDir/aug_ab_initio.lst\n"
            if ($v > 3);
    }

    if( !uptodate(["$otherfilesDir/aug_ab_initio.lst"], 
        ["$otherfilesDir/ab_initio$genesetId.job.lst"]) || $overwrite ) {
        $string = find(
            "createAugustusJoblist.pl", $AUGUSTUS_BIN_PATH,
            $AUGUSTUS_SCRIPTS_PATH,     $AUGUSTUS_CONFIG_PATH);
        $errorfile
        = "$errorfilesDir/createAugustusJoblist_ab_initio$genesetId.stderr";

        $perlCmdString = "";
        $perlCmdString = "cd $otherfilesDir\n";
        if ($nice) {
            $perlCmdString .= "nice ";
        }
        $perlCmdString .= "perl $string "
                       .  "--sequences=$otherfilesDir/aug_ab_initio.lst "
                       .  "--wrap=\"#!/bin/bash\" --overlap=5000 "
                       .  "--chunksize=$chunksize "
                       .  "--outputdir=$augustus_dir_ab_initio "
                       .  "--joblist=$otherfilesDir/ab_initio$genesetId.job.lst "
                       .  "--jobprefix=aug_ab_initio_ "
                       .  "--command \"$augpath --species=$species "
                       .  "--AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH "
                       .  "--UTR=$localUTR  --exonnames=on --codingseq=on ";
        if ($soft_mask) {
            $perlCmdString .= " --softmasking=1";
        }
        $perlCmdString .= "\" 2>$errorfile\n";
        $perlCmdString .= "cd ..\n";
        print LOG "$perlCmdString" if ($v > 3);
        system("$perlCmdString") == 0
            or die("ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nFailed to execute: $perlCmdString\n");
    }else{
        print LOG "\# " . (localtime)
            . ": Skipping creation of AUGUSTUS ab inito jobs because they "
            . "already exist ($otherfilesDir/ab_initio$genesetId.job.lst).\n"
            if ($v > 3);
    }
}

####################### run_augustus_jobs ######################################
# * run parallel AUGUSTUS jobs (ForkManager)
################################################################################

sub run_augustus_jobs {
    my $jobLst = shift;
    print LOG "\# " . (localtime) . ": Running AUGUSTUS jobs from $jobLst\n" 
        if ($v > 2);
    my $pm = new Parallel::ForkManager($CPU);
    my $cJobs = 0;
    open( AIJOBS, "<", $jobLst )
        or die("ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nCould not open file $jobLst!\n");
    my @aiJobs;
    while (<AIJOBS>) {
        chomp;
        push @aiJobs, "$otherfilesDir/$_";
    }
    close(AIJOBS)
        or die("ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nCould not close file $jobLst!\n");
    foreach(@aiJobs){
        $cJobs++;
        print LOG "\# " . (localtime) . ": Running AUGUSTUS job $cJobs\n" 
            if ($v > 3);
        $cmdString = "$_";
        print LOG "$cmdString\n" if ($v > 3);
        my $pid = $pm->start and next;
        system("$cmdString") == 0
            or die("ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nFailed to execute: $cmdString!\n");
        $pm->finish;
    }
    $pm->wait_all_children;
}

####################### join_aug_pred ##########################################
# * join AUGUSTUS predictions from parallelized job execution
################################################################################

sub join_aug_pred {
    my $pred_dir    = shift;
    print LOG "\# " . (localtime) . ": Joining AUGUSTUS predictions in "
        . "directory $pred_dir\n" if ($v > 2);
    my $target_file = shift;
    $string = find(
        "join_aug_pred.pl",     $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH);
    my $n = 1;
    while (-e "$otherfilesDir/augustus.tmp${n}.gff") {
        $n += 1;
    }
    my $cat_file = "$otherfilesDir/augustus.tmp${n}.gff";
    my @t = split(/\//, $pred_dir);
    $t[scalar(@t)-1] =~ s/\///;
    my $error_cat_file = "$errorfilesDir/augustus_".$t[scalar(@t)-1].".err";
    print LOG "\# " . (localtime)
        . ": Concatenating AUGUSTUS output files in $pred_dir\n" if ($v > 3);
    opendir( DIR, $pred_dir ) or die("ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nFailed to open directory $pred_dir!\n");
    # need to concatenate gff files in the correct order along chromosomes for
    # join_aug_pred.pl
    my %gff_files;
    my %err_files;
    while ( my $file = readdir(DIR) ) {
        my %fileinfo;
        if ( $file =~ m/\d+\.\d+\.(.*)\.(\d+)\.\.\d+\.gff/ ) {
            $fileinfo{'start'} = $2;
            $fileinfo{'filename'} = $file;
            push @{$gff_files{$1}}, \%fileinfo;
        }elsif ( $file =~ m/\d+\.\d+\.(.*)\.(\d+)\.\.\d+\.err/ ){
            $fileinfo{'start'} = $2;
            $fileinfo{'filename'} = $file;
            push @{$err_files{$1}}, \%fileinfo;
        }
    }
    foreach(keys %gff_files){
        @{$gff_files{$_}} = sort { $a->{'start'} <=> $b->{'start'}} @{$gff_files{$_}};
    }
    foreach(keys %err_files){
        @{$gff_files{$_}} = sort { $a->{'start'} <=> $b->{'start'}} @{$gff_files{$_}};
    }
    foreach(keys %gff_files){
        foreach(@{$gff_files{$_}}){
            $cmdString = "";
            if ($nice) {
                $cmdString .= "nice ";
            }
            $cmdString .= "cat $pred_dir/".$_->{'filename'}." >> $cat_file";
            print LOG "$cmdString\n" if ($v > 3);
            system("$cmdString") == 0 or die("ERROR in file " . __FILE__
                . " at line ". __LINE__ ."\nFailed to execute $cmdString\n");
        }
    }
    foreach(keys %err_files){
        foreach(@{$err_files{$_}}){
            if ( -s $_ ) {
                $cmdString = "echo \"Contents of file ".$_->{'filename'}."\" >> $error_cat_file";
                print LOG "$cmdString\n" if ($v > 3);
                system ("$cmdString") == 0 or die ("ERROR in file " . __FILE__
                    ." at line ". __LINE__ ."\nFailed to execute $cmdString\n");
                $cmdString = "";
                if ($nice) {
                    $cmdString .= "nice ";
                }
                $cmdString .= "cat $pred_dir/".$_->{'filename'}." >> $error_cat_file";
                print LOG "$cmdString\n" if ($v > 3);
                system("$cmdString") == 0 or die("ERROR in file " . __FILE__
                    ." at line ". __LINE__ ."\nFailed to execute $cmdString\n");
            }
        }
    }

    closedir(DIR) or die ("ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nFailed to close directory $pred_dir\n");

    $perlCmdString = "";
    if ($nice) {
        $perlCmdString .= "nice ";
    }
    $perlCmdString .= "perl $string < $cat_file > $target_file";
    print LOG "$perlCmdString\n" if ($v > 3);
    system("$perlCmdString") == 0
        or die("ERROR in file " . __FILE__ ." at line ". __LINE__
            ."\nFailed to execute $perlCmdString\n");
    if($cleanup){
        print LOG "\# " . (localtime) . ": Deleting $pred_dir\n" if ($v > 3);
        rmtree( ["$pred_dir"] ) or die ("ERROR in file " . __FILE__ ." at line "
            . __LINE__ ."\nFailed to delete $pred_dir!\n");
        print LOG "\# " . (localtime) . ": Deleting $cat_file\n" if ($v > 3);
        unlink($cat_file);
    }
}

####################### run_augustus_single_core_ab_initio #####################
# * run AUGUSTUS ab initio on a single core
################################################################################

sub run_augustus_single_core_ab_initio {
    my $localUTR = shift;
    my $genesetId = shift;
    my $aug_ab_initio_err = "$errorfilesDir/augustus.ab_initio$genesetId.err";
    my $aug_ab_initio_out = "$otherfilesDir/augustus.ab_initio$genesetId.gff";
    $cmdString         = "";
    if ($nice) {
        $cmdString .= "nice ";
    }
    $cmdString .= "$augpath --species=$species "
               .  "--AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH "
               .  "--UTR=$localUTR --exonnames=on --codingseq=on";
    if ($soft_mask) {
        $cmdString .= " --softmasking=1";
    }
    $cmdString .= " $genome 1>$aug_ab_initio_out 2>$aug_ab_initio_err";
    print LOG "\# "
        . (localtime)
        . ": Running AUGUSTUS in ab initio mode for file $genome with "
        . "gensetsetId $genesetId.\n" if ($v > 2);
    print LOG "$cmdString\n" if ($v > 3);
    system("$cmdString") == 0
        or die("ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nFailed to execute: $cmdString!\n");
}

####################### run_augustus_single_core_hints #########################
# * run AUGUSTUS with hints on a single core (hints from a single source)
################################################################################

sub run_augustus_single_core_hints {
    my $thisHintsfile = shift;
    my $cfgFile = shift;
    my $localUTR = shift;
    my $hintId = shift;
    my $aug_hints_err = "$errorfilesDir/augustus.$hintId.stderr";
    my $aug_hints_out = "$otherfilesDir/augustus.$hintId.gff";
    $cmdString     = "";
    if ($nice) {
        $cmdString .= "nice ";
    }
    $cmdString .= "$augpath --species=$species --AUGUSTUS_CONFIG_PATH=$AUGUSTUS_CONFIG_PATH --extrinsicCfgFile=$cfgFile --alternatives-from-evidence=$alternatives_from_evidence "
               .  "--hintsfile=$thisHintsfile --UTR=$localUTR --exonnames=on --codingseq=on --allow_hinted_splicesites=gcag,atac";
    if ( defined($optCfgFile) ) {
        $cmdString .= " --optCfgFile=$optCfgFile";
    }
    if ($soft_mask) {
        $cmdString .= " --softmasking=1";
    }
    if ( defined($augustus_args) ) {
        $cmdString .= " $augustus_args";
    }
    $cmdString .= " $genome 1>$aug_hints_out 2>$aug_hints_err";
    print LOG "\# "
        . (localtime)
        . ": Running AUGUSTUS with $hintId for file $genome\n" if ($v > 2);
    print LOG "$cmdString\n" if ($v > 3);
    system("$cmdString") == 0
        or die("ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nFailed to execute: $cmdString!\n");
}

####################### adjust_pri #############################################
# * adjust priorities in hints files
################################################################################

sub adjust_pri {
    print LOG "\# " . (localtime) . ": Adjusting priority for protein hints for "
        . "running AUGUSTUS with RNA-Seq and protein hints simultaneously\n"
        if ($v > 2);
    my $hints = shift;
    my $adjusted = shift;
    my $source = shift;
    my $value = shift;
    open ( HINTS, "<", $hints ) or die("ERROR in file " . __FILE__
        . " at line ". __LINE__ ."\nCould not open file $hints!\n");
    open (OUT, ">", $adjusted) or die("ERROR in file " . __FILE__
        . " at line ". __LINE__ ."\nCould not open file $adjusted!\n");
    while(<HINTS>){
        if ( $_ =~ m/src=E/ ) {
            $_ =~ s/pri=(\d)/pri=4/;
            print OUT $_;
        }elsif ( $_ =~ m/src=P/ ) {
            $_ =~ s/pri=(\d)/pri=5/;
            print OUT $_;
        }else{
            print OUT $_;
        }
    }
    close (OUT) or die("ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nCould not close file $adjusted!\n");
    close (HINTS) or die ("ERROR in file " . __FILE__ ." at line ". __LINE__
        . "\nCould not close file $hints!\n");
}

####################### run_augustus_with_joingenes_parallel ###################
# * run AUGUSTUS with joingenes, parallelized
# * means: execute RNA-Seq only predictions
#          execute RNA-Seq & protein predictions (giving proteins higher weight)
#          joining predictions
#          adding genes missed by joingenes to final gene set
################################################################################

sub run_augustus_with_joingenes_parallel {
    print LOG "\# " . (localtime) . ": Running AUGUSTUS with joingenes in "
        . "parallel mode\n" if ($v > 2);
    my $genome_dir = shift;
    my $localUTR = shift;
    my $genesetId = shift;
    # if RNASeq and protein hints are given
    my $adjustedHintsFile = "$hintsfile.Ppri5";
    if( !uptodate( [$hintsfile], [$adjustedHintsFile]) || $overwrite ) {    
        $cmdString = "cp $hintsfile $adjustedHintsFile";
        print LOG "$cmdString\n" if ($v > 3);
        system("$cmdString") == 0 or die("ERROR in file " . __FILE__
            . " at line ". __LINE__ ."\nFailed to execute: $cmdString!\n");
    } else {
        print LOG "\# " . (localtime) . " Skip creating adjusted hints file "
            . "$adjustedHintsFile because it is up to date.\n" if($v > 3);
    }

    if( defined ($extrinsicCfgFile1) && $localUTR eq "off") {
        $extrinsicCfgFile = $extrinsicCfgFile1;
    }elsif(defined ($extrinsicCfgFile3) && $localUTR eq "on"){
        $extrinsicCfgFile = $extrinsicCfgFile3;
    }else{
        if( $localUTR eq "off" ) {
            assign_ex_cfg("ep.cfg");
        }else{
            assign_ex_cfg("ep_utr.cfg");
        }
    }
    copy_ex_cfg($extrinsicCfgFile, "ex1$genesetId.cfg");
    my $augustus_dir = "$otherfilesDir/augustus_tmp_Ppri5$genesetId";
    make_hints_jobs( $augustus_dir, $genome_dir, $adjustedHintsFile,
        $extrinsicCfgFile, $localUTR, "Ppri5", $genesetId);
    run_augustus_jobs( "$otherfilesDir/Ppri5$genesetId.job.lst" );
    join_aug_pred( $augustus_dir, "$otherfilesDir/augustus.Ppri5$genesetId.gff" );
    make_gtf("$otherfilesDir/augustus.Ppri5$genesetId.gff");
    if(not($skip_fixing_broken_genes)){
        get_anno_fasta("$otherfilesDir/augustus.Ppri5$genesetId.gtf", "tmp");
        if(-e "$otherfilesDir/bad_genes.lst"){
            fix_ifs_genes("augustus.Ppri5$genesetId", 
                          "$otherfilesDir/augustus.Ppri5$genesetId.gtf", 
                          $otherfilesDir."/bad_genes.lst", $localUTR, $species, 
                          $AUGUSTUS_CONFIG_PATH, $AUGUSTUS_BIN_PATH, 
                          $AUGUSTUS_SCRIPTS_PATH, $adjustedHintsFile, $extrinsicCfgFile);
        }
    }
    clean_aug_jobs("Ppri5$genesetId");
    $adjustedHintsFile = "$hintsfile.E";
    # the following includes evidence hints
    get_rnaseq_hints($hintsfile, $adjustedHintsFile);
    if (defined ($extrinsicCfgFile2) && $localUTR eq "off") {
        $extrinsicCfgFile = $extrinsicCfgFile2;
    }elsif(defined ($extrinsicCfgFile4) && $localUTR eq "on"){
        $extrinsicCfgFile = $extrinsicCfgFile4;
    }elsif($localUTR eq "off"){
        assign_ex_cfg("rnaseq.cfg");
    }else{
        assign_ex_cfg("rnaseq_utr.cfg");
    }
    copy_ex_cfg($extrinsicCfgFile, "ex2$genesetId.cfg");
    $augustus_dir = "$otherfilesDir/augustus_tmp_E$genesetId";
    make_hints_jobs( $augustus_dir, $genome_dir, $adjustedHintsFile,
        $extrinsicCfgFile, $localUTR, "E", $genesetId);
    run_augustus_jobs( "$otherfilesDir/E$genesetId.job.lst" );
    join_aug_pred( $augustus_dir, "$otherfilesDir/augustus.E$genesetId.gff" );
    make_gtf("$otherfilesDir/augustus.E$genesetId.gff");
    if(not($skip_fixing_broken_genes)){
        get_anno_fasta("$otherfilesDir/augustus.E$genesetId.gtf", "tmp");
        if(-e "$otherfilesDir/bad_genes.lst"){
            fix_ifs_genes("augustus.E$genesetId", 
                          "$otherfilesDir/augustus.E$genesetId.gtf", 
                          $otherfilesDir."/bad_genes.lst", $localUTR, $species, 
                          $AUGUSTUS_CONFIG_PATH, $AUGUSTUS_BIN_PATH, 
                          $AUGUSTUS_SCRIPTS_PATH, $adjustedHintsFile, $extrinsicCfgFile);
        }
    }
    clean_aug_jobs("E$genesetId");
    joingenes("$otherfilesDir/augustus.Ppri5$genesetId.gtf",
        "$otherfilesDir/augustus.E$genesetId.gtf", $genesetId);
}

####################### run_augustus_with_joingenes_single_core ################
# * run AUGUSTUS with joingenes on a single core
# * means: execute RNA-Seq only predictions
#          execute RNA-Seq & protein predictions (giving proteins higher weight)
#          joining predictions
#          adding genes missed by joingenes to final gene set
################################################################################

sub run_augustus_with_joingenes_single_core {
    print LOG "\# " . (localtime) . ": Running AUGUSTUS with joingenes in "
        . "single core mode\n" if ($v > 2);
    my $localUTR = shift;
    my $genesetId = shift;
    # if RNASeq and protein hints are given
    my $adjustedHintsFile = "$hintsfile.Ppri5";
    if( !uptodate([$hintsfile],[$adjustedHintsFile]) || $overwrite ) {
        $cmdString = "cp $hintsfile $adjustedHintsFile";
        print LOG "$cmdString\n" if ($v > 3);
        system("$cmdString") == 0 or die("ERROR in file " . __FILE__
            . " at line ". __LINE__ ."\nFailed to execute: $cmdString!\n");
    } else {
        print LOG "\# " . (localtime) . ": Skip making adjusted hints file "
            . "$adjustedHintsFile from hintsfile $hintsfile because file is up "
            . "to date.\n" if ($v > 3);
    }

    if( !uptodate( [$adjustedHintsFile], 
        ["$otherfilesDir/augustus.Ppri5$genesetId.gff"] ) || $overwrite ) {
        if( defined ($extrinsicCfgFile1) && $localUTR eq "off") {
            $extrinsicCfgFile = $extrinsicCfgFile1;
        }elsif(defined ($extrinsicCfgFile3) && $localUTR eq "on"){
            $extrinsicCfgFile = $extrinsicCfgFile3;
        }else{
            if( $localUTR eq "off" ) {
                assign_ex_cfg("ep.cfg");
            } else {
                assign_ex_cfg("ep_utr.cfg");
            }
        }
        copy($extrinsicCfgFile, "ex1$genesetId.cfg");
        run_augustus_single_core_hints($adjustedHintsFile, $extrinsicCfgFile,
            $localUTR, "Ppri5$genesetId");
        make_gtf("$otherfilesDir/augustus.Ppri5$genesetId.gff");
        if(not($skip_fixing_broken_genes)){
            get_anno_fasta("$otherfilesDir/augustus.Ppri5$genesetId.gtf", "tmp");
            if(-e "$otherfilesDir/bad_genes.lst"){
                fix_ifs_genes("augustus.Ppri5$genesetId", 
                              "$otherfilesDir/augustus.Ppri5$genesetId.gtf", 
                              $otherfilesDir."/bad_genes.lst", $localUTR, $species, 
                              $AUGUSTUS_CONFIG_PATH, $AUGUSTUS_BIN_PATH, 
                              $AUGUSTUS_SCRIPTS_PATH, $adjustedHintsFile, $extrinsicCfgFile);
            }
        }
    }else{
        print LOG "\# " . (localtime) . ": Skip making file "
            . "$otherfilesDir/augustus.Ppri5$genesetId.gff because file is up "
            . "to date.\n" if ($v > 3);
    }

    $adjustedHintsFile = "$hintsfile.E";
    if ( !uptodate( [$hintsfile], [$adjustedHintsFile] ) || $overwrite ) {
        get_rnaseq_hints($hintsfile, $adjustedHintsFile);
    }else{
        print LOG "\# " . (localtime) . ": Skip making adjusted hints file "
            . "$adjustedHintsFile from hintsfile $hintsfile because file is up "
            . "to date.\n" if ($v > 3);
    }
    if ( !uptodate( [$adjustedHintsFile], 
        ["$otherfilesDir/augustus.E$genesetId.gff"] ) || $overwrite ) {
        if (defined ($extrinsicCfgFile2) && $localUTR eq "off") {
            $extrinsicCfgFile = $extrinsicCfgFile2;
        }elsif(defined ($extrinsicCfgFile4) && $localUTR eq "on"){
            $extrinsicCfgFile = $extrinsicCfgFile4;
        }elsif($localUTR eq "off"){
            assign_ex_cfg("rnaseq.cfg");
        }else{
            assign_ex_cfg("rnaseq_utr.cfg");
        }
        copy_ex_cfg($extrinsicCfgFile, "ex2$genesetId.cfg");
        run_augustus_single_core_hints($adjustedHintsFile, $extrinsicCfgFile,
            $localUTR, "E$genesetId");
        make_gtf("$otherfilesDir/augustus.E$genesetId.gff");
        if(not($skip_fixing_broken_genes)){
            get_anno_fasta("$otherfilesDir/augustus.E$genesetId.gtf", "tmp");
            if(-e "$otherfilesDir/bad_genes.lst"){
                fix_ifs_genes("augustus.E$genesetId", 
                              "$otherfilesDir/augustus.E$genesetId.gtf", 
                              $otherfilesDir."/bad_genes.lst", $localUTR, $species, 
                              $AUGUSTUS_CONFIG_PATH, $AUGUSTUS_BIN_PATH, 
                              $AUGUSTUS_SCRIPTS_PATH, $adjustedHintsFile, $extrinsicCfgFile);
            }
        }
    } else {
        print LOG "\# " . (localtime) . ": Skip making file "
            . "$otherfilesDir/augustus.E$genesetId.gff because file is up "
            . "to date.\n" if ($v > 3);
    }
    if( !uptodate(["$otherfilesDir/augustus.Ppri5$genesetId.gtf", 
        "$otherfilesDir/augustus.E$genesetId.gtf"], 
        ["$otherfilesDir/augustus.hints$genesetId.gtf"]) || $overwrite ) {
        joingenes("$otherfilesDir/augustus.Ppri5$genesetId.gtf",
            "$otherfilesDir/augustus.E$genesetId.gtf", $genesetId);
    }else{
        print LOG "\# " . (localtime) . ": Skip running joingenes with input "
            . "files $otherfilesDir/augustus.E$genesetId.gtf and "
            . "$otherfilesDir/augustus.Ppri5$genesetId.gtf to produce "
            . "$otherfilesDir/augustus.hints$genesetId.gtf because file is "
            . "up to date.\n" if ($v > 3);
    }
}

####################### copy_ex_cfg ############################################
# * copy the extrinsic config file to GALBA working directory
################################################################################

sub copy_ex_cfg {
    my $thisCfg = shift;
    my $target = shift;
    if ( not( -d "$parameterDir/$species/" ) ) {
        mkdir "$parameterDir/$species/";
    }
    $cmdString = "cp $thisCfg $parameterDir/$species/$target";
    print LOG "\# "
        . (localtime)
        . ": copy extrinsic file $thisCfg to working directory\n" if ($v > 2);
    print LOG "$cmdString\n" if ($v > 2);
    system("$cmdString") == 0
        or die("ERROR in file " . __FILE__ ." at line "
            . __LINE__ ."\nFailed to execute: $cmdString!\n");
}

####################### clean_aug_jobs #########################################
# * clean up AUGUSTUS job files from parallelization
# * if not --cleanup: move job files to a separate folder
# * if --cleanup: delete job files
################################################################################

sub clean_aug_jobs {
    my $hintId = shift;
    opendir( DIR, $otherfilesDir ) or die("ERROR in file " . __FILE__
        . " at line ". __LINE__
        . "\nFailed to open directory $otherfilesDir!\n");
    if( $cleanup ) {
        # deleting files from AUGUSTUS parallelization
        print LOG "\# " . (localtime) . ": deleting files from AUGUSTUS "
            . "parallelization\n" if ($v > 3);

        while ( my $file = readdir(DIR) ) {
            my $searchStr = "aug_".$hintId."_";
            if( $file =~ m/$searchStr/){
                print LOG "rm $otherfilesDir/$file\n" if ($v > 3);
                unlink( "$otherfilesDir/$file" ) or die ("ERROR in file "
                    . __FILE__ ." at line ". __LINE__
                    . "\nFailed to delete file $otherfilesDir/$file!\n");
            }
        }

    } else {
        # moving files for AUGUSTUS prallelization to a separate folder
        print LOG "\# " . (localtime) . ": moving files from AUGUSTUS "
            . "parallelization to directory "
            . "$otherfilesDir/augustus_files_$hintId\n" if ($v > 3);
        if ( !-d "$otherfilesDir/augustus_files_$hintId" ) {
            $prtStr = "\# "
                    . (localtime)
                    . ": creating directory "
                    . "$otherfilesDir/augustus_files_$hintId.\n"
                    . "mkdir $otherfilesDir/augustus_files_$hintId\n";
            $logString .= $prtStr if ( $v > 2 );
            make_path("$otherfilesDir/augustus_files_$hintId") or 
                die("ERROR in file " . __FILE__ ." at line "
                . __LINE__ ."\nFailed to create directory "
                . "$otherfilesDir/augustus_files_$hintId!\n");
        }
        while ( my $file = readdir(DIR) ) {
            my $searchStr1 = "aug_".$hintId."_";
            my $searchStr2 = "aug_".$hintId.".";
            my $searchStr3 = "hintsfile.gff.".$hintId;
            my $searchStr4 = $hintId.".job.lst";
            if( $file =~ m/($searchStr1|$searchStr2|$searchStr3|$searchStr4)/){
                print LOG "mv $otherfilesDir/$file "
                     . "$otherfilesDir/augustus_files_$hintId/$file\n" if ($v > 3);
                move("$otherfilesDir/$file", "$otherfilesDir/augustus_files_$hintId/$file") or
                    die ("ERROR in file "
                    . __FILE__ ." at line ". __LINE__
                    . "\nFailed to move $otherfilesDir/$file "
                    . "to $otherfilesDir/augustus_files_$hintId/$file!\n");
            }
        }
    }
    closedir(DIR) or die("ERROR in file " . __FILE__ ." at line "
        . __LINE__ . "\nFailed to close directory $otherfilesDir!\n");
}

####################### joingenes ##############################################
# * join two AUGUSTUS prediction sets in gff formats into one
################################################################################

sub joingenes {
    my $file1 = shift;
    my $file2 = shift;
    my $genesetId = shift;
    print LOG "\# " . (localtime) . ": Executing joingenes on files $file1 and "
        . "$file2\n" if ($v > 2);
    # determine which source set of P and E supports more transcripts to decide
    # which gene set is to be prioritized higher (the one with more support)
    # use filter_augustus_gff.pl with --src=(P|E) as tool for counting
    my $string = find(
        "filter_augustus_gff.pl",      $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    # file1 is should have predictions with protein hints -> count src=P
    # file2 has predictions with protein and RNA-Seq hints but RNA-Seq had
    # higher priority when running AUGUSTUS -> count src=E
    $perlCmdString = "";
    if ($nice) {
        $perlCmdString .= "nice ";
    }
    my $gff_file1 = $file1;
    $gff_file1 =~ s/\.gtf/\.gff/;
    $perlCmdString .= "perl $string --in=$gff_file1 --src=P > $otherfilesDir/file1_ntx";
    print LOG "# Counting the number of transcripts with support from src=P in file $file1...\n";
    print LOG "$perlCmdString\n" if ($v > 3);
    system("$perlCmdString") == 0 or die("ERROR in file " . __FILE__
        . " at line ". __LINE__ ."\nFailed to execute: $perlCmdString!\n");
    open(NTX1, "<", "$otherfilesDir/file1_ntx") or die("ERROR in file " . __FILE__
        . " at line ". __LINE__ ."\nFailed to open file $otherfilesDir/file1_ntx for reading!\n");
    my @hn_tx_1;
    while(<NTX1>){
        chomp;
        push(@hn_tx_1, $_);
    }
    my $n_tx_1 = $hn_tx_1[0];
    close(NTX1) or die("ERROR in file " . __FILE__
        . " at line ". __LINE__ ."\nFailed to close file $otherfilesDir/file1_ntx!\n");
    $perlCmdString = "";
    if ($nice) {
        $perlCmdString .= "nice ";
    }
    my $gff_file2 = $file2;
    $gff_file2 =~ s/\.gtf/\.gff/;
    $perlCmdString .= "perl $string --in=$gff_file2 --src=E > $otherfilesDir/file2_ntx";
    print LOG "# Counting the number of transcripts with support from src=E in file $file2...\n";
    print LOG "$perlCmdString\n" if ($v > 3);
    system("$perlCmdString") == 0 or die("ERROR in file " . __FILE__
        . " at line ". __LINE__ ."\nFailed to execute: $perlCmdString!\n");
    open(NTX2, "<", "$otherfilesDir/file2_ntx") or die("ERROR in file " . __FILE__
        . " at line ". __LINE__ ."\nFailed to open file $otherfilesDir/file2_ntx for reading!\n");
    my @hn_tx_2;
    while(<NTX2>){
        chomp;
        push(@hn_tx_2, $_);
    }
    my $n_tx_2 = $hn_tx_2[0];
    close(NTX2) or die("ERROR in file " . __FILE__
        . " at line ". __LINE__ ."\nFailed to close file $otherfilesDir/file2_ntx!\n");
    if( $cleanup ) {
        print LOG "rm $otherfilesDir/file1_ntx $otherfilesDir/file2_ntx\n";
        unlink("$otherfilesDir/file1_ntx");
        unlink("$otherfilesDir/file2_ntx");
    }
    print LOG "# File $file1 has $n_tx_1 supported transcripts, $file2 has $n_tx_2 supported transcripts\n";
    # filter only supported transcripts from the file with fewer supported transcripts and build joingenes command
    my $join_basis;
    my $join_on_top;
    if($n_tx_1 < $n_tx_2){
        $join_basis = $file2;
        $join_on_top = $file1."_filtered";
        $perlCmdString = "";
        if ($nice) {
            $perlCmdString .= "nice ";
        }
        $perlCmdString .= "perl $string --in=$gff_file1 --src=P --out=$join_on_top";
        print LOG "# Filtering those genes that have evidence by src=P from $file1...\n";
        print LOG "$perlCmdString\n" if ($v > 3);
        system("$perlCmdString") == 0 or die("ERROR in file " . __FILE__
                                            . " at line ". __LINE__ ."\nFailed to execute: $perlCmdString!\n");
    }else {
        $join_basis = $file1;
        $join_on_top = $file2."_filtered";
        $perlCmdString = "";
        if ($nice) {
            $perlCmdString .= "nice ";
        }
        $perlCmdString .= "perl $string --in=$gff_file2 --src=E --out=$join_on_top";
        print LOG "# Filtering those genes that have evidence by src=E from $file2...\n";
        print LOG "$perlCmdString\n" if ($v > 3);
        system("$perlCmdString") == 0 or die("ERROR in file " . __FILE__
                                            . " at line ". __LINE__ ."\nFailed to execute: $perlCmdString!\n");
    }
    # join two prediction files (join the less supported set on top of the better supported set)
    my $joingenespath = "$AUGUSTUS_BIN_PATH/joingenes";
    $cmdString = "";
    if($nice){
        $cmdString .= "nice ";
    }
    $cmdString .= "$joingenespath --genesets=$join_basis,$join_on_top --priorities=2,1 "
               .  "--output=$otherfilesDir/join$genesetId.gtf 1> /dev/null 2> "
               .  "$errorfilesDir/joingenes$genesetId.err";
    print LOG "$cmdString\n" if ($v > 3);
    system("$cmdString") == 0 or die("ERROR in file " . __FILE__ ." at line "
        . __LINE__ ."\nFailed to execute: $cmdString!\n");
    # find genes in introns from first gene set
    $string = find(
        "findGenesInIntrons.pl",      $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    $perlCmdString = "";
    if ($nice) {
        $perlCmdString .= "nice ";
    }
    $perlCmdString .= "perl $string --in_gff=$join_basis "
                   .  "--jg_gff=$otherfilesDir/join$genesetId.gtf "
                   .  "--out_gff=$otherfilesDir/missed.genes$genesetId"."_1.gtf 1> "
                   .  "/dev/null 2> "
                   .  "$errorfilesDir/findGenesInIntrons$genesetId"."_1.err";
    print LOG "$perlCmdString\n" if ($v > 3);
    system("$perlCmdString") == 0 or die("ERROR in file " . __FILE__
        . " at line ". __LINE__ ."\nFailed to execute: $perlCmdString!\n");
    # find genes in introns from second (filtered) gene set
        $perlCmdString = "";
    if ($nice) {
        $perlCmdString .= "nice ";
    }
    $perlCmdString .= "perl $string --in_gff=$join_on_top "
                   .  "--jg_gff=$otherfilesDir/join$genesetId.gtf "
                   .  "--out_gff=$otherfilesDir/missed.genes$genesetId"."_2.gtf 1> "
                   .  "/dev/null 2> "
                   .  "$errorfilesDir/findGenesInIntrons$genesetId"."_2.err";
    print LOG "$perlCmdString\n" if ($v > 3);
    system("$perlCmdString") == 0 or die("ERROR in file " . __FILE__
        . " at line ". __LINE__ ."\nFailed to execute: $perlCmdString!\n");
    # merge missed genes in a nonredundant fashion
    if ( (-e "$otherfilesDir/missed.genes$genesetId"."_1.gtf") && (-e "$otherfilesDir/missed.genes$genesetId"."_2.gtf") ) {
        my %tx_lines;
        my %tx_structures;
        open(MISSED1, "<", "$otherfilesDir/missed.genes$genesetId"."_1.gtf") or die("ERROR in file " . __FILE__
             . " at line ". __LINE__ ."\nFailed to open file $otherfilesDir/missed.genes$genesetId"."_1.gtf for reading!\n");
        #Some modifications here to avoid regex hitting the first field:
        while(my $missed_line = <MISSED1>){
            my @gff_parts = split /\t/, $missed_line;
            # need to rename transcripts because names could be the same for different txs in both files
            my ($tx_id, $g_id);
            for (my $i = 8; $i < scalar(@gff_parts); $i++) {
               $gff_parts[$i] =~ m/(g\d+\.t\d+)/;
               $tx_id = "m1-".$1;
               $gff_parts[$i] =~ m/(g\d+)/;
               $g_id = "m1-".$1;
            }
            #Fix suggested by visoca in issue #118, some of my contigs end in g#
            # and get mangled by this line:
            #$_ =~ s/g\d+/$g_id/g;
            #Somewhat modified visoca's fix, since we're working with GTFs,
            # so the gene_id may not be the last tag.
            #Instead, we apply the regex to all fields after 8:
            for (my $i = 8; $i < scalar(@gff_parts); $i++) {
               $gff_parts[$i] =~ s/g\d+/$g_id/g;
            }
            $missed_line = join("\t", @gff_parts);
            #Continue with the rest of the flow:
            push(@{$tx_lines{$tx_id}}, $missed_line);
            if( ($missed_line =~ m/CDS/) or ($missed_line =~ m/UTR/) ) {
                my @t = split /\t/, $missed_line;
                if(not(defined($tx_structures{$tx_id}))){
                    $tx_structures{$tx_id} = $t[0]."_".$t[3]."_".$t[4]."_".$t[6];
                }else{
                    $tx_structures{$tx_id} .= "_".$t[0]."_".$t[3]."_".$t[4]."_".$t[6];
                }
            }
        }
        close(MISSED1) or die("ERROR in file " . __FILE__
              . " at line ". __LINE__ ."\nFailed to close file $otherfilesDir/missed.genes$genesetId"."_1.gtf!\n");
        open(MISSED2, "<", "$otherfilesDir/missed.genes$genesetId"."_2.gtf") or die("ERROR in file " . __FILE__
             . " at line ". __LINE__ ."\nFailed to open file $otherfilesDir/missed.genes$genesetId"."_2.gtf for reading!\n");
        #Some modifications here to avoid regex hitting the first field:
        while(my $missed_line = <MISSED2>){
            my @gff_parts = split /\t/, $missed_line;
            my $tx_id;
            for (my $i = 8; $i < scalar(@gff_parts); $i++) {
               $gff_parts[$i] =~ m/(g\d+\.t\d+)/;
               $tx_id = $1;
            }
            push(@{$tx_lines{$tx_id}}, $missed_line);
            if( ($missed_line =~ m/CDS/) or ($missed_line =~ m/UTR/) ) {
                my @t = split /\t/, $missed_line;
                if(not(defined($tx_structures{$tx_id}))){
                    $tx_structures{$tx_id} = $t[0]."_".$t[3]."_".$t[4]."_".$t[6];
                }else{
                    $tx_structures{$tx_id} .= "_".$t[0]."_".$t[3]."_".$t[4]."_".$t[6];
                }
            }
        }
        close(MISSED2) or die("ERROR in file " . __FILE__
              . " at line ". __LINE__ ."\nFailed to close file $otherfilesDir/missed.genes$genesetId"."_2.gtf!\n");
        # identify unique transcript structures
        my %tx_to_keep;
        while (my ($key, $value) = each (%tx_structures)) {
            $tx_to_keep{$value} = $key;
        }
        open(MISSED, ">", $otherfilesDir."/missed.genes$genesetId.gtf") or die("ERROR in file " . __FILE__
             . " at line ". __LINE__ ."\nFailed to open file $otherfilesDir./missed.genes$genesetId.gtf for writing!\n");
        while(my ($key, $value) = each(%tx_to_keep)){
            foreach(@{$tx_lines{$value}}){
                print MISSED $_;
            }
        }
        close(MISSED) or die("ERROR in file " . __FILE__
             . " at line ". __LINE__ ."\nFailed to close file $otherfilesDir./missed.genes$genesetId.gtf!\n");
    }elsif(-e  "$otherfilesDir/missed.genes$genesetId"."_1.gtf"){
        move("$otherfilesDir/missed.genes$genesetId"."_1.gtf", "$otherfilesDir/missed.genes$genesetId".".gtf") or die(
            "ERROR in file " . __FILE__
             . " at line ". __LINE__ ."\nFailed to to move file $otherfilesDir/missed.genes$genesetId"."_1.gtf to "
             . "$otherfilesDir/missed.genes$genesetId".".gtf!\n");
    }elsif(-e  "$otherfilesDir/missed.genes$genesetId"."_2.gtf"){
        move("$otherfilesDir/missed.genes$genesetId"."_2.gtf", "$otherfilesDir/missed.genes$genesetId".".gtf") or die(
            "ERROR in file " . __FILE__
             . " at line ". __LINE__ ."\nFailed to to move file $otherfilesDir/missed.genes$genesetId"."_2.gtf to "
             . "$otherfilesDir/missed.genes$genesetId".".gtf!\n");
    }

    if (-e "$otherfilesDir/missed.genes$genesetId.gtf") {
        $cmdString = "cat $otherfilesDir/missed.genes$genesetId.gtf >> "
                   . "$otherfilesDir/join$genesetId.gtf";
        print LOG "$cmdString\n" if ($v > 3);
        system("$cmdString") == 0 or die("ERROR in file " . __FILE__
            . " at line ". __LINE__ ."\nFailed to execute: $cmdString!\n");
    }
    $string = find(
        "fix_joingenes_gtf.pl",      $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    $perlCmdString = "";
    if ($nice) {
        $perlCmdString .= "nice ";
    }
    $perlCmdString .= "perl $string < $otherfilesDir/join$genesetId.gtf "
                   .  "> $otherfilesDir/augustus.hints$genesetId.gtf";
    print LOG "$perlCmdString\n" if ($v > 3);
    system("$perlCmdString") == 0 or die("ERROR in file " . __FILE__
        . " at line ". __LINE__ ."\nFailed to execute: $perlCmdString!\n");
    if (!$skipGetAnnoFromFasta) {
        get_anno_fasta("$otherfilesDir/augustus.hints$genesetId.gtf", "");
    }
    print LOG "\# " . (localtime) . "rm $otherfilesDir/join$genesetId.gtf\n";
    unlink "$otherfilesDir/join$genesetId.gtf" or die("ERROR in file " . __FILE__
        . " at line ". __LINE__ ."\nFailed to execute: rm $otherfilesDir/join$genesetId.gtf!\n");
    $cmdString = "rm $otherfilesDir/join$genesetId.gtf";
    print LOG "$cmdString\n" if ($v > 3);
}

####################### get_anno_fasta #########################################
# * extract codingseq and protein sequences from AUGUSTUS output
################################################################################

sub get_anno_fasta {
    my $AUG_pred = shift;
    my $label = shift;
    print LOG "\# "
        . (localtime)
        . ": Making a fasta file with protein sequences of $AUG_pred\n"
        if ($v > 2);
    my $name_base = $AUG_pred;
    $name_base =~ s/[^\.]+$//;
    $name_base =~ s/\.$//;
    my @name_base_path_parts = split(/\//, $name_base);
    my $string = find(
        "getAnnoFastaFromJoingenes.py",      $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    my $errorfile = "$errorfilesDir/getAnnoFastaFromJoingenes.".$name_base_path_parts[scalar(@name_base_path_parts)-1]."_".$label.".stderr";
    my $outfile = "$otherfilesDir/getAnnoFastaFromJoingenes.".$name_base_path_parts[scalar(@name_base_path_parts)-1]."_".$label.".stdout";
    my $pythonCmdString = "";
    if ($nice) {
        $pythonCmdString .= "nice ";
    }
    $pythonCmdString .= "$PYTHON3_PATH/python3 $string ";
    if (not($ttable == 1)){
        $pythonCmdString .= "-t $ttable ";
    }
    $pythonCmdString .= "-g $genome -f $AUG_pred "
                     .  "-o $name_base 1> $outfile 2>$errorfile";

    print LOG "$pythonCmdString\n" if ($v > 3);
    system("$pythonCmdString") == 0
        or die("ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nFailed to execute: $pythonCmdString\n");
}

####################### make_gtf ###############################################
# * convert AUGUSTUS output to gtf format
################################################################################

sub make_gtf {
    my $AUG_pred = shift;
    @_ = split( /\//, $AUG_pred );
    my $name_base = substr( $_[-1],    0, -4 );
    my $gtf_file_tmp = substr( $AUG_pred, 0, -4 ) . ".tmp.gtf";
    my $gtf_file  = substr( $AUG_pred, 0, -4 ) . ".gtf";
    if( !uptodate([$AUG_pred], [$gtf_file]) || $overwrite ) {
        print LOG "\# " . (localtime) . ": Making a gtf file from $AUG_pred\n"
            if ($v > 2);
        my $errorfile  = "$errorfilesDir/gtf2gff.$name_base.gtf.stderr";
        my $perlstring = find(
            "gtf2gff.pl",           $AUGUSTUS_BIN_PATH,
            $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH );
        $cmdString = "";
        if ($nice) {
            $cmdString .= "nice ";
        }
        my $cmdString .= "cat $AUG_pred | perl -ne 'if(m/\\tAUGUSTUS\\t/) {print \$_;}' | perl $perlstring --printExon --out=$gtf_file_tmp 2>$errorfile";
        print LOG "$cmdString\n" if ($v > 3);
        system("$cmdString") == 0 or die("ERROR in file " . __FILE__
            . " at line ". __LINE__ ."\nFailed to execute: $cmdString\n");
        open (GTF, "<", $gtf_file_tmp) or die("ERROR in file " . __FILE__
            . " at line ". __LINE__ ."\nCannot open file $gtf_file_tmp\n");
        open (FINALGTF, ">", $gtf_file) or die("ERROR in file " . __FILE__
            . " at line ". __LINE__ ."\nCannot open file $gtf_file\n");
        while(<GTF>){
            if(not($_ =~ m/\tterminal\t/) && not($_ =~ m/\tinternal\t/) && not ($_ =~ m/\tinitial\t/) && not ($_ =~ m/\tsingle\t/)) {
                print FINALGTF $_;
            }
        }
        close (FINALGTF) or die ("ERROR in file " . __FILE__ ." at line "
            . __LINE__ ."\nCannot close file $gtf_file\n");
        close(GTF) or die("ERROR in file " . __FILE__ ." at line "
            . __LINE__ ."\nCannot close file $gtf_file_tmp\n");
    }else{
        print LOG "\# " . (localtime) . ": Skip making gtf file from $AUG_pred "
            . "because $gtf_file is up to date.\n" if ($v > 3);
    }
}

####################### evaluate ###############################################
# * evaluate gene predictions (find prediction files, start eval_gene_pred)
################################################################################

sub evaluate {
    my @results;
    my $seqlist = "$otherfilesDir/seqlist";
    print LOG "\# "
        . (localtime)
        . ": Trying to evaluate galba.pl gene prediction files...\n" if ($v > 2);
    if ( -e "$otherfilesDir/augustus.ab_initio.gtf" ) {
        print LOG "\# "
            . (localtime)
            . ": evaluating $otherfilesDir/augustus.ab_initio.gtf!\n"
            if ($v > 3);
        eval_gene_pred("$otherfilesDir/augustus.ab_initio.gtf");
    }else{
         print LOG "\# "
            . (localtime)
            . ": did not find $otherfilesDir/augustus.ab_initio.gtf!\n"
            if ($v > 3);
    }

    if ( -e "$otherfilesDir/augustus.ab_initio_utr.gtf" ) {
        print LOG "\# "
            . (localtime)
            . ": evaluating $otherfilesDir/augustus.ab_initio_utr.gtf!\n"
            if ($v > 3);
        eval_gene_pred("$otherfilesDir/augustus.ab_initio_utr.gtf");
    }else{
         print LOG "\# "
            . (localtime)
            . ": did not find $otherfilesDir/augustus.ab_initio_utr.gtf!\n"
            if ($v > 3);
    }

    if ( -e "$otherfilesDir/augustus.hints.gtf" ) {
        print LOG "\# "
            . (localtime)
            . ": evaluating $otherfilesDir/augustus.hints.gtf!\n"
            if ($v > 3);
        eval_gene_pred("$otherfilesDir/augustus.hints.gtf");
    }else{
        print LOG "\# "
            . (localtime)
            . ": did not find $otherfilesDir/augustus_hints.gtf!\n"
            if ($v > 3);
    }

        if ( -e "$otherfilesDir/augustus.hints_iter1.gtf" ) {
        print LOG "\# "
            . (localtime)
            . ": evaluating $otherfilesDir/augustus.hints_iter1.gtf!\n"
            if ($v > 3);
        eval_gene_pred("$otherfilesDir/augustus.hints_iter1.gtf");
    }else{
        print LOG "\# "
            . (localtime)
            . ": did not find $otherfilesDir/augustus_hints_iter1.gtf!\n"
            if ($v > 3);
    }

    if ( -e "$otherfilesDir/augustus.hints_utr.gtf" ) {
        print LOG "\# "
            . (localtime)
            . ": evaluating $otherfilesDir/augustus.hints_utr.gtf!\n"
            if ($v > 3);
        eval_gene_pred("$otherfilesDir/augustus.hints_utr.gtf");
    }else{
        print LOG "\# "
            . (localtime)
            . ": did not find $otherfilesDir/augustus_hints_utr.gtf!\n"
            if ($v > 3);
    }

    if ( -e "$otherfilesDir/gthTrainGenes.gtf" ) {
        print LOG "\# "
            . (localtime)
            . ": evaluating $otherfilesDir/gthTrainGenes.gtf!\n" if ($v > 3);
        eval_gene_pred("$otherfilesDir/gthTrainGenes.gtf");
    }else{
        print LOG "\# "
            . (localtime)
            . ": did not find $otherfilesDir/gthTrainGenes.gtf!\n" if ($v > 3);
    }
    my @accKeys = keys %accuracy;
    if(scalar(@accKeys) > 0){
        print LOG "\# "
        . (localtime)
        . ": was able to run evaluations on ". scalar (@accKeys)
        . "gene sets. Now summarizing "
        . "eval results...\n" if ($v > 3);
        open (ACC, ">", "$otherfilesDir/eval.summary") or die ("ERROR in file "
            . __FILE__ ." at line ". __LINE__
            . "\nCould not open file $otherfilesDir/eval.summary");
        print ACC "Measure";
        foreach(@accKeys){
            chomp;
            print ACC "\t$_";
        }
        print ACC "\n";

        my @gene_sens;
        my @gene_spec;
        my @trans_sens;
        my @trans_spec;
        my @exon_sens;
        my @exon_spec;
        for( my $i = 0; $i < 6; $i ++){
            if( $i == 0 ){ print ACC "Gene_Sensitivity" }
            elsif( $i == 1 ){ print ACC "Gene_Specificity" }
            elsif( $i == 2 ){ print ACC "Transcript_Sensitivity" }
            elsif( $i == 3 ){ print ACC "Transcript_Specificity" }
            elsif( $i == 4 ){ print ACC "Exon_Sensitivity" }
            elsif( $i == 5 ){ print ACC "Exon_Specificity" }
            foreach(@accKeys){
                chomp(${$accuracy{$_}}[$i]);
                print ACC "\t".${$accuracy{$_}}[$i];
                if($i == 0){
                    push(@gene_sens, ${$accuracy{$_}}[$i]);
                }elsif($i == 1){
                    push(@gene_spec, ${$accuracy{$_}}[$i]);
                }elsif($i == 2){
                    push(@trans_sens, ${$accuracy{$_}}[$i]);
                }elsif($i == 3){
                    push(@trans_spec, ${$accuracy{$_}}[$i]);
                }elsif($i == 4){
                    push(@exon_sens, ${$accuracy{$_}}[$i]);
                }elsif($i == 5){
                    push(@exon_spec, ${$accuracy{$_}}[$i]);
                }
            }
            print ACC "\n";
            my @gene_sens;
            my @gene_spec;
            my @trans_sens;
            my @trans_spec;
            my @exon_sens;
            my @exon_spec;
            for( my $i = 0; $i < 6; $i ++){
                if( $i == 0 ){ print ACC "Gene_Sensitivity" }
                elsif( $i == 1 ){ print ACC "Gene_Specificity" }
                elsif( $i == 2 ){ print ACC "Transcript_Sensitivity" }
                elsif( $i == 3 ){ print ACC "Transcript_Specificity" }
                elsif( $i == 4 ){ print ACC "Exon_Sensitivity" }
                elsif( $i == 5 ){ print ACC "Exon_Specificity" }
                foreach(@accKeys){
                    chomp(${$accuracy{$_}}[$i]);
                    print ACC "\t".${$accuracy{$_}}[$i];
                    if($i == 0){
                        push(@gene_sens, ${$accuracy{$_}}[$i]);
                    }elsif($i == 1){
                        push(@gene_spec, ${$accuracy{$_}}[$i]);
                    }elsif($i == 2){
                        push(@trans_sens, ${$accuracy{$_}}[$i]);
                    }elsif($i == 3){
                        push(@trans_spec, ${$accuracy{$_}}[$i]);
                    }elsif($i == 4){
                        push(@exon_sens, ${$accuracy{$_}}[$i]);
                    }elsif($i == 5){
                        push(@exon_spec, ${$accuracy{$_}}[$i]);
                    }
                }
                print ACC "\n";
                if( $i == 1 ){
                    print ACC "Gene_F1\t";
                    if(($gene_sens[0] != 0) && ($gene_spec[0] != 0)){
                        my $f1_gene = 2*$gene_sens[0]*$gene_spec[0]/($gene_sens[0]+$gene_spec[0]);
                        printf ACC "%.2f", $f1_gene;
                    }else{
                        print ACC "NA";
                    }
                    print ACC "\n";
                }elsif( $i == 3 ){
                    print ACC "Transcript_F1\t";
                    if(($trans_sens[0] != 0) && ($trans_spec[0] != 0)){
                        my $f1_trans = 2*$trans_sens[0]*$trans_spec[0]/($trans_sens[0]+$trans_spec[0]);
                        printf ACC "%.2f", $f1_trans;
                    }else{
                        print ACC "NA";
                    }
                    print ACC "\n";
                }elsif( $i == 5){
                    print ACC "Exon_F1\t";
                    if(($exon_sens[0] != 0) && ($exon_spec[0] != 0)){
                        my $f1_exon = 2*$exon_sens[0]*$exon_spec[0]/($exon_sens[0]+$exon_spec[0]);
                        printf ACC "%.2f", $f1_exon;
                    }else{
                        print ACC "NA";
                    }
                    print ACC "\n";
                }
            }
        }
        close(ACC) or die ("ERROR in file " . __FILE__ . " at line "
                . __LINE__ ."\nCould not close file $otherfilesDir/eval.summary");
    }
    print LOG "\# "
        . (localtime)
        . ": Done with evaluating galba.pl gene prediction files!\n" if ($v > 3);
}

####################### eval_gene_pred #########################################
# * evaluate a particular gene set in gtf format
# * switched to scripts form GaTech written by Alex & Tomas in Februrary 2020
# * their scripts are included in GALBA repository
################################################################################

sub eval_gene_pred {
    my $gtfFile        = shift;
    my $compute_accuracies = find(
        "compute_accuracies.sh",    $AUGUSTUS_BIN_PATH,
        $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
    );
    print LOG "\# "
        . (localtime)
        . ": Trying to evaluate predictions in file $gtfFile\n" if ($v > 3);
    $cmdString = "$compute_accuracies $annot $annot_pseudo $gtfFile gene trans cds";
    my @res = `$cmdString`; # when using system, it did not print to file
    my @eval_result;
    foreach(@res){
        my @line = split(/\t/);
        push(@eval_result, $line[1]);
    }
    $accuracy{$gtfFile} = \@eval_result;
}

####################### gtf2gff3 ###############################################
# convert gtf to gff3 format
# (do not use native AUGUSTUS gff3 output because joingenes does not produce
# gff3 format)
####################### gtf2gff3 ###############################################

sub gtf2gff3 {
    my $gtf = shift;
    my $gff3 = shift;
    print LOG "\# " . (localtime) . ": converting gtf file $gtf to gff3 format "
        . ", outputfile $gff3.\n" if ($v > 2);
    if( not( uptodate( [$gtf] , [$gff3] ) ) || $overwrite ){
        $string = find(
            "gtf2gff.pl", $AUGUSTUS_BIN_PATH,
            $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
        );
        $perlCmdString = "";
        if($nice){
            $perlCmdString .= "nice ";
        }
        $perlCmdString .= "cat $gtf | perl -ne 'if(m/\\tAUGUSTUS\\t/ or "
                       .  "m/\\tAnnotationFinalizer\\t/ or m/\\tGUSHR\\t/ or "
                       .  "m/\\tGeneMark\.hmm\\t/) {"
                       .  "print \$_;}' | perl $string --gff3 --out=$gff3 "
                       .  ">> $otherfilesDir/gtf2gff3.log "
                       .  "2>> $errorfilesDir/gtf2gff3.err";
        print LOG "$perlCmdString\n" if ($v > 3);
        system("$perlCmdString") == 0
            or die("ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nFailed to execute: $perlCmdString\n");
    }else{
        print LOG "\# " . (localtime) . ": skipping format conversion because "
            . "files are up to date.\n" if ($v > 2);
    }
}

####################### all_preds_gtf2gff3 #####################################
# convert gtf to gff3 format for the following possible final output files:
#  * augustus.ab_initio.gtf
#  * augustus.hints.gtf
####################### all_preds_gtf2gff3 #####################################

sub all_preds_gtf2gff3 {
    print LOG "\# " . (localtime) . ": converting essential output files "
        . "to gff3 format.\n" if ($v > 2);
    my @files = ("$otherfilesDir/augustus.ab_initio.gtf", 
        "$otherfilesDir/augustus.hints.gtf");
    foreach(@files){
        if(-e $_){
            my $gtf = $_;
            my $gff3 = $_;
            $gff3 =~ s/\.gtf/\.gff3/;
            gtf2gff3($gtf, $gff3);
        }
    }
}

####################### make_hub ################################################
# create track data hub for visualizing GALBA results with the UCSC Genome
# Browser using make_hub.py
####################### make_hub ################################################

sub make_hub {
    print LOG  "\# " . (localtime) . ": generating track data hub for UCSC "
           . " Genome Browser\n" if ($v > 2);

    print CITE $pubs{'makehub'}; $pubs{'makehub'} = "";

    my $cmdStr = $PYTHON3_PATH . "/python3 " . $MAKEHUB_PATH . "/make_hub.py -g " . $genome 
            . " -e " . $email . " -l " . "hub_" . substr($species, 0, 3) 
            . " -L " . $species . " -X " . $otherfilesDir . " -P ";
    if ($annot) {
        $cmdStr .= "-a $annot";
    }
    $cmdStr .= " > $otherfilesDir/makehub.log 2> $errorfilesDir/makehub.err";
    print LOG $cmdStr . "\n"  if ($v > 3);
    system("$cmdStr") == 0
            or die("ERROR in file " . __FILE__ ." at line ". __LINE__
            . "\nFailed to execute: $cmdStr\n");
}

####################### clean_up ###############################################
# delete empty files, and files produced by parallelization
####################### clean_up ###############################################

sub clean_up {
    print LOG "\# " . (localtime) . ": deleting empty files\n" if ($v > 2);
    if ($nice) {
        print LOG "\# " . (localtime) . ": nice find $otherfilesDir -empty\n"
        if ($v > 3);
        @files = `nice find $otherfilesDir -empty`;
    }
    else {
        print LOG "\# " . (localtime) . ": find $otherfilesDir -empty\n"
            if ($v > 3);
        @files = `find $otherfilesDir -empty`;
    }
    for ( my $i = 0; $i <= $#files; $i++ ) {
        chomp( $files[$i] )
            ; # to prevent error: Unsuccessful stat on filename containing newline
        if ( -f $files[$i] ) {
            print LOG "rm $files[$i]\n" if ($v > 3);
            unlink( rel2abs( $files[$i] ) );
        }
    }
    # deleting files from AUGUSTUS parallelization
    if($cleanup){
        print LOG "\# " . (localtime) . ": deleting job lst files (if existing)\n"
            if ($v > 3);
        opendir( DIR, $otherfilesDir ) or die("ERROR in file " . __FILE__
            . " at line ". __LINE__
            . "\nFailed to open directory $otherfilesDir!\n");
        while ( my $file = readdir(DIR) ) {
            if( $file =~ m/\.lst/ || $file =~ m/aug_ab_initio_/ || $file =~ m/Ppri5/ || $file =~ m/augustus\.E/ 
                || $file =~ m/gff\.E/ || 
                $file =~ m/missed/ || $file =~ m/prot_hintsfile\.aln2hints\.temp\.gff/ ||
                $file =~ m/aa2nonred\.stdout/ || $file =~ m/augustus\.hints\.tmp\.gtf/ ||
                $file =~ m/firstetraining\.stdout/ || $file =~ m/gbFilterEtraining\.stdout/
                || $file =~ m/secondetraining\.stdout/ || $file =~ m/traingenes\.good\.fa/ ||
                $file =~ m/aa2nonred\.stdout/ || $file =~ m/singlecds\.hints/ ||
                $file =~ m/augustus\.hints\.tmp\.gtf/ || $file =~ m/train\.gb\./ ||
                $file =~ m/traingenes\.good\.fa/ || $file =~ m/augustus\.ab_initio\.tmp\.gtf/
                || $file =~ m/augustus\.ab_initio_utr\.tmp\.gtf/ || $file =~ m/augustus\.hints_utr\.tmp\.gtf/
                || $file =~ m/genes\.gtf/ || $file =~ m/genes_in_gb\.gtf/ ||
                $file =~ m/merged\.s\.bam/ || $file =~ m/utr_genes_in_gb\.fa/ ||
                $file =~ m/utr_genes_in_gb\.nr\.fa/ || $file =~ m/utr\.gb\.test/ ||
                $file =~ m/utr\.gb\.train/ || $file =~ m/utr\.gb\.train\.test/ ||
                $file =~ m/utr\.gb\.train\.train/ || $file =~ m/ep\.hints/ || 
                $file =~ m/rnaseq\.utr\.hints/ || $file =~ m/stops\.and\.starts.gff/ ||
                $file =~ m/trainGb3\.train/ || $file =~ m/traingenes\.good\.nr.\fa/ ||
                $file =~ m/nonred\.loci\.lst/ || $file =~ m/traingenes\.good\.gtf/ ||
                $file =~ m/etrain\.bad\.lst/ || $file =~ m/etrain\.bad\.lst/ ||
                $file =~ m/train\.f*\.gb/ || $file =~ m/good_genes\.lst/ || 
                $file =~ m/traingenes\.good\.nr\.fa/ || $file =~ m/fix_IFS_log_/ || 
                $file =~ m/tmp_merge_hints\.gff/ || $file =~ m/tmp_no_merge_hints\.gff/ ){
                print LOG "rm $otherfilesDir/$file\n" if ($v > 3);
                unlink( "$otherfilesDir/$file" );
            }
        }

        if(-e "$otherfilesDir/seqlist"){
            unlink ( "$otherfilesDir/seqlist" );
        }
        if(-d "$otherfilesDir/genome_split" ) {
            rmtree( ["$otherfilesDir/genome_split"] ) or die ("ERROR in file "
                . __FILE__ ." at line ". __LINE__
                . "\nFailed to delete $otherfilesDir/genome_split!\n");
        }
        if(-d "$otherfilesDir/tmp_opt_$species") {
            rmtree( ["$otherfilesDir/tmp_opt_$species"] ) or die ("ERROR in file "
                . __FILE__ ." at line ". __LINE__
                . "\nFailed to delete $otherfilesDir/tmp_opt_$species!\n");
        }
        if(-d "$otherfilesDir/augustus_files_E"){
            rmtree ( ["$otherfilesDir/augustus_files_E"] ) or die ("ERROR in file "
                . __FILE__ ." at line ". __LINE__
                . "\nFailed to delete $otherfilesDir/augustus_files_E!\n");
        }
        if(-d "$otherfilesDir/augustus_files_Ppri5"){
            rmtree ( ["$otherfilesDir/augustus_files_Ppri5"] ) or die ("ERROR in file "
                . __FILE__ ." at line ". __LINE__
                . "\nFailed to delete $otherfilesDir/augustus_files_Ppri5!\n");
        }
        # clean up ProtHint output files
        if(-e "$otherfilesDir/evidence_augustus.gff"){
            print LOG "rm $otherfilesDir/evidence_augustus.gff\n" if ($v > 3);
            unlink("$otherfilesDir/evidence_augustus.gff");
        }
        if(-e "$otherfilesDir/gene_stat.yaml"){
            print LOG "rm $otherfilesDir/gene_stat.yaml\n" if ($v > 3);
            unlink("$otherfilesDir/gene_stat.yaml");
        }
        if(-e "$otherfilesDir/nuc.fasta"){
            print LOG "rm $otherfilesDir/nuc.fasta\n" if ($v > 3);
            unlink("$otherfilesDir/nuc.fasta");
        }
        if(-e "$otherfilesDir/prothint_augustus.gff"){
            print LOG "rm $otherfilesDir/prothint_augustus.gff\n" if ($v > 3);
            unlink("$otherfilesDir/prothint_augustus.gff");
        }
        if(-e "$otherfilesDir/prothint_reg.out"){
            print LOG "rm $otherfilesDir/prothint_reg.out\n" if ($v > 3);
            unlink("$otherfilesDir/prothint_reg.out");
        }
        if(-e "$otherfilesDir/top_chains.gff"){
            print LOG "rm $otherfilesDir/top_chains.gff\n" if ($v > 3);
            unlink("$otherfilesDir/top_chains.gff");
        }
        if(-d "$otherfilesDir/diamond"){
            print LOG "rm -r $otherfilesDir/diamond\n" if ($v > 3);
            rmtree ( ["$otherfilesDir/diamond"] ) or die ("ERROR in file "
                . __FILE__ ." at line ". __LINE__
                . "\nFailed to delete $otherfilesDir/diamond!\n");
        }
        if(-d "$otherfilesDir/Spaln"){
            print LOG "rm -r $otherfilesDir/Spaln\n" if ($v > 3);
            rmtree ( ["$otherfilesDir/Spaln"] ) or die ("ERROR in file "
                . __FILE__ ." at line ". __LINE__
                . "\nFailed to delete $otherfilesDir/Spaln!\n");
        }


        $string = find(
            "GALBA_cleanup.pl", $AUGUSTUS_BIN_PATH,
            $AUGUSTUS_SCRIPTS_PATH, $AUGUSTUS_CONFIG_PATH
        );
        $perlCmdString = "";
        if($nice){
            $perlCmdString .= "nice ";
        }
        $perlCmdString .= "perl $string --wdir=$otherfilesDir";
        print LOG "$perlCmdString\n" if ($v > 3);
        my $loginfo = `$perlCmdString`;
        print LOG $loginfo;
    }
}

