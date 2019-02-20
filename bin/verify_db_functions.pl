#!perl

## Compare checksums stored in the git repo with production values for all functions

use strict;
use warnings;
use Data::Dumper;
use Path::Tiny;
use Getopt::Long qw( GetOptions );
Getopt::Long::Configure(qw/ auto_version /);
use Log::Any qw($log), default_adapter => 'Stdout';

my (%opt, $verbose, $quiet, $repo, $repodir, $db);

our $VERSION = '1.8';

my $USAGE = "Usage: $0 --repo=<repo name> --db=<service file name>";

my @excluded_schemas = qw/ tmp /;

get_all_options();

my ($taginfo, $commitinfo, $git_hashes) = get_git_hashes();

my ($dbinfo, $db_hashes) = get_db_hashes();

unless ($quiet) {
    my $message = sprintf "Repo: %s at commit %s, created on %s
Author: %s Title: %s
Latest tag: %s, created on %s, points to commit %s
Database service: %s (%sport=%s user=%s database=%s)",

        $repo, $commitinfo->{hash}, $commitinfo->{date},
        $commitinfo->{author}, $commitinfo->{title},
        $taginfo->{name},      $taginfo->{tagdate}, $taginfo->{shortcommit},
        $dbinfo->{service},    $dbinfo->{host} ? "host=$dbinfo->{host} " : '',
        $dbinfo->{port}, $dbinfo->{user}, $dbinfo->{dbname};

    $log->notice($message);

}

my $prefix = '* ';

## Any functions that exist in the repo but not the database?
my @onlyrepo;
for my $gitfunc (keys %{$git_hashes}) {
    next if exists $db_hashes->{$gitfunc};
    push @onlyrepo => $gitfunc;
}
if (@onlyrepo) {
    for my $func (sort @onlyrepo) {
        $log->notice("${prefix}Function in the repo but not in database $db: $func");
    }
} elsif ($verbose) {
    $log->notice("${prefix}All functions in the repo are also in database $db");
}

## Any functions that exist in the database but not in the repo?
my @onlydb;
for my $dbfunc (keys %{$db_hashes}) {
    next if exists $git_hashes->{$dbfunc};
    next if $dbfunc =~ /^(\w+)\./ and grep { $_ eq $1 } @excluded_schemas;
    push @onlydb => $dbfunc;
}
if (@onlydb) {
    for my $func (sort @onlydb) {
        $log->notice("${prefix}Function in database $db but not in the repo: $func");
    }
} elsif ($verbose) {
    $log->notice("${prefix}All functions in database $db are also in the repo");
}

## Any functions with a mismatched checksum?
my $identical = 0;
my @mismatch;
for my $dbfunc (keys %{$db_hashes}) {
    next if !exists $git_hashes->{$dbfunc};
    if ($db_hashes->{$dbfunc} ne $git_hashes->{$dbfunc}) {
        push @mismatch => $dbfunc;
    } else {
        $identical++;
    }
}
if (@mismatch) {
    for my $func (sort @mismatch) {
        $log->notice("${prefix}Function is different in the repo and database $db: $func");
    }
} elsif ($verbose) {
    $log->notice("${prefix}All functions have identical checksums for database $db");
}

$verbose and $log->notice("Total identical functions for db $db: $identical");

if (!@onlyrepo and !@onlydb and !@mismatch) {
    $log->notice(' Everything is identical!');
}

$log->notice("\n");

exit;

sub debug {

    return if $opt{debug} < 1;
    my $message = shift;
    chomp $message;
    $log->debug(">>DEBUG: $message");
    return;
}

sub get_git_hashes {

    ## Grab the manifest information from the latest git tag for a repo
    ## Assumes a file named "manifest" exists in the root directory of the repo
    ## Returns three hashrefs:
    ## 1. git tag information (name, date, tagger, commit, commit date)
    ## 2. latest commit information (hash, author name, date, title)
    ## 3. function names and their hash values

    if (!$repodir->exists) {
        $log->fatal("Cannot proceed: directory does not exist: $repodir");
        exit 1;
    }

    ## We rely on other people leaving the repo in our desired state

    ## Grab the latest "V" tag
    my $command    = "tag -l | grep '^V' | sort -k1.2 -g | tail -1";
    my $latest_tag = run_git_command($command);
    chomp $latest_tag;
    $verbose and $log->notice("Latest git tag: $latest_tag");

    ## Gather information about this tag
    my $taginfo = get_tag_info($latest_tag);

    ## Gather information about the latest commit
    my $commitinfo = get_latest_commit_info();

    ## Open the manifest file and read in the checksums
    my $manifest = path($repodir, 'manifest');
    if (!$manifest->exists) {
        $log->fatal("Could not find $manifest!");
        exit 1;
    }
    my @lines = $manifest->lines;
    my %git_func_hash;
    for my $line (@lines) {
        if ($line =~ /([a-f0-9]+)\s+(.+)/) {
            $git_func_hash{$2} = $1;
        } else {
            chomp $line;
            warn $log->warning("Unknown line inside $manifest: $line");
        }
    }

    if ($verbose) {
        my $count = keys %git_func_hash;
        $log->notice("Entries found in $manifest: $count");
    }

    return $taginfo, $commitinfo, \%git_func_hash;
}

sub get_tag_info {

    ## Given a tag, return a hashref of information about it

    my $tagname = shift;

    my $command = qq{git show "$tagname"};
    my $result  = run_git_command($command);

    debug substr($result, 0, 400) . "\n\n";

    ## Sanity check
    if ($result !~ /^tag $tagname$/m) {
        $log->fatal("Invalid tag information returned from $command");
        exit 1;
    }

    my %taginfo = (
        name => $tagname,
    );

    if ($result =~ /^Tagger:\s+(.+)/m) {
        $taginfo{tagger} = $1;
    }
    if ($result =~ s/^Date:\s+(.+)//m) {
        $taginfo{tagdate} = $1;
    }
    if ($result =~ /^commit ([a-f0-9]+)/m) {
        $taginfo{commit} = $1;
        $taginfo{shortcommit} = substr($1, 0, 8);
    }
    if ($result =~ /^Author:\s+(.+)/m) {
        $taginfo{author} = $1;
    }
    if ($result =~ /^Date:\s+(.+)/m) {
        $taginfo{commitdate} = $1;
    }

    return \%taginfo;
}

sub get_latest_commit_info {

    ## Return information about the latest commit

    my $command = qq{git log -1 --format="Commit: %h%nAuthor: %an%nDate: %aD%nTitle: %s%n"};
    my $result  = run_git_command($command);

    debug $result;

    ## Sanity check
    if ($result !~ /^Commit: ([a-f0-9]+)/) {
        $log->fatal("Invalid log information returned from $command");
        exit 1;
    }

    my %commitinfo = (
        hash => $1,
    );

    if ($result =~ /^Author:\s+(.+)/m) {
        $commitinfo{author} = $1;
    }
    if ($result =~ /^Date:\s+(.+)/m) {
        $commitinfo{date} = $1;
    }
    if ($result =~ /^Title:\s+(.+)/m) {
        $commitinfo{title} = $1;
    }

    return \%commitinfo;
}

sub run_git_command {

    ## Run a git command in the currect repo, return all output
    ## Both stdout and stderr are combined into the return string

    my $command = shift;

    chdir $repodir;

    $command = "git $command" unless $command =~ /^git/;

    debug "Running command: $command";
    my $output = qx{ $command 2>&1 };

    return $output;

}

sub get_db_hashes {

    ## Build and return a hashref of function checksums from a live database

    my $sqlfile = path($repodir, 'tools', 'manifest.sql');
    if (!$sqlfile->exists) {
        $log->fatal("Could not find SQL file at $sqlfile");
        exit 1;
    }
    my $SQL = $sqlfile->slurp;

    my %db_func_hash;
    my $command = qq{psql service="$db" -AX -qt -c "$SQL"};
    debug "Running: $command";
    my $res = qx{ $command };
    while ($res =~ /([a-f0-9]+)\|(.+)/g) {
        $db_func_hash{$2} = $1;
    }

    if (!keys %db_func_hash) {
        $log->fatal("Could not get database function checksums from $db");
        exit 1;
    }

    if ($verbose) {
        my $count = keys %db_func_hash;
        $log->notice("Entries found in database $db: $count");
    }

    $SQL     = "SELECT current_database(), setting, user, inet_server_addr() FROM pg_settings WHERE name = 'port'";
    $command = qq{psql service="$db" -AX -qt -c "$SQL"};
    debug "Running: $command";
    my $result = qx{ $command };
    chomp $result;
    debug "Result: $result";
    my ($dbname, $dbport, $dbuser, $dbhost) = split /\|/ => $result;
    my $dbinfo = {
        service => $db,
        dbname  => $dbname,
        host    => $dbhost,
        port    => $dbport,
        user    => $dbuser,
    };

    return $dbinfo, \%db_func_hash;

}

sub get_token {

    ## Attempt to get a token for github

    my $tokenfile = path($opt{tokenfile} // ($ENV{HOME}, '.config', 'git'));

    if (!$tokenfile->exists) {
        $log->fatal("Could not find token file: $tokenfile");
        exit 1;
    }

    my $data = $tokenfile->slurp_utf8;
    if ($data =~ /token:\s*([a-f0-9]+)/) {
        my $token = $1;
        my $len   = length $token;
        debug "Found a token of length $len in file: $tokenfile";
        return $token;
    }

    $log->fatal("File does not contain a token: $tokenfile");
    exit 1;
}

sub get_all_options {

    ## Set some default options
    %opt = (
        verbose => 0,
        debug   => 0,
        quiet   => 0,
        githome => '/home/git/regentmarkets',
    );

    GetOptions(\%opt, 'verbose', 'debug+', 'quiet|q', 'database|db=s', 'repo|repository=s', 'githome=s', 'tokenfile=s', 'help|h',) or die;

    if ($opt{help} or !$opt{repo} or !$opt{database}) {    ## no critic
        $log->fatal("$USAGE");
        exit 1;
    }

    $verbose = $opt{verbose};
    $quiet   = $opt{quiet};
    $repo    = $opt{repo};
    $repodir = path($opt{githome}, $repo);
    $db      = $opt{database};

    return \%opt;

}
