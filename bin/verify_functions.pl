#!perl

## Compare checksums stored in the git repo with production values for all functions

use strict;
use warnings;
use Data::Dumper;
use Path::Tiny;
use Getopt::Long qw( GetOptions );
Getopt::Long::Configure(qw/ auto_version /);
my (%opt, $verbose, $quiet, $repo, $repodir, $db);

our $VERSION = '1.3';

my $USAGE = "Usage: $0 --repo=<repo name> --db=<service file name>";

get_all_options();

my ($taginfo, $git_hashes) = get_git_hashes();

my ($dbinfo, $db_hashes) = get_db_hashes();

if (!$quiet) {
    printf "Repo: %s at tag %s, created on %s\n (points to commit %s, created on %s)\n",
        $repo, $taginfo->{name}, $taginfo->{tagdate}, $taginfo->{shortcommit}, $taginfo->{commitdate};
    printf "Database service: %s (%sport=%s user=%s database=%s)\n",
        $dbinfo->{service}, $dbinfo->{host} ? "host=$dbinfo->{host} " : '',
        $dbinfo->{port}, $dbinfo->{user}, $dbinfo->{dbname};
}

my @wrong;

my $prefix = '* ';

## Any functions that exist in the repo but not the database?
for my $gitfunc (keys %{$git_hashes}) {
    next if exists $db_hashes->{$gitfunc};
    push @wrong => $gitfunc;
}
if (@wrong) {
    for my $func (sort @wrong) {
        print "${prefix}Function in the repo but not in database $db: $func\n";
    }
} elsif ($verbose) {
    print "${prefix}All functions in the repo are also in database $db\n";
}

## Any functions that exist in the database but not in the repo?
undef @wrong;
for my $dbfunc (keys %{$db_hashes}) {
    next if exists $git_hashes->{$dbfunc};
    push @wrong => $dbfunc;
}
if (@wrong) {
    for my $func (sort @wrong) {
        print "${prefix}Function in database $db but not in the repo: $func\n";
    }
} elsif ($verbose) {
    print "${prefix}All functions in database $db are also in the repo\n";
}

## Any functions with a mismatched checksum?
my $identical = 0;
undef @wrong;
for my $dbfunc (keys %{$db_hashes}) {
    next if !exists $git_hashes->{$dbfunc};
    if ($db_hashes->{$dbfunc} ne $git_hashes->{$dbfunc}) {
        push @wrong => $dbfunc;
    } else {
        $identical++;
    }
}
if (@wrong) {
    for my $func (sort @wrong) {
        print "${prefix}Function is different in the repo and database $db: $func\n";
    }
} elsif ($verbose) {
    print "${prefix}All functions have identical checksums for database $db\n";
}

$verbose and print "Total identical functions for db $db: $identical\n";

print "\n";

exit;

sub debug {

    return if $opt{debug} < 1;
    my $message = shift;
    chomp $message;
    print ">>DEBUG: $message\n";
    return;
}

sub get_git_hashes {

    ## Grab the manifest information from the latest git tag for a repo
    ## Assumes a file named "manifest" exists in the root directory of the repo
    ## Returns two hashrefs:
    ## 1. git tag information (name, date, tagger, commit, commit date)
    ## 2. function names and their hash values

    if (!$repodir->exists) {
        $quiet or print "Creating $repodir\n";
        my $TOKEN   = get_token();
        my $command = "clone https://$TOKEN\@github.com/regentmarkets/$repo $repodir";
        run_git_command($command);
    }

    ## Just in case, stash away any existing work
    my $command = 'stash save';
    run_git_command($command);

    ## Make sure we are on the latest important tag
    $command = "tag -l | grep '^V' | sort -k1.2 -g | tail -1";
    my $latest_tag = run_git_command($command);
    chomp $latest_tag;
    length $latest_tag or die qq{Could not determine latest tag for $repo\n};
    $verbose and print "Latest git tag: $latest_tag\n";

    ## Gather information about this tag
    my $taginfo = get_tag_info($latest_tag);

    ## Switch to this tag if not already there
    $command = qq{checkout "$latest_tag"};
    run_git_command($command);

    ## Open the manifest file and read in the checksums
    my $manifest = path($repodir, 'manifest');
    $manifest->exists or die "Could not find $manifest!\n";
    my @lines = $manifest->lines;
    my %git_func_hash;
    for my $line (@lines) {
        if ($line =~ /([a-f0-9]+)\s+(.+)/) {
            $git_func_hash{$2} = $1;
        } else {
            chomp $line;
            warn "Unknown line inside $manifest: $line\n";
        }
    }

    if ($verbose) {
        my $count = keys %git_func_hash;
        print "Entries found in $manifest: $count\n";
    }

    return $taginfo, \%git_func_hash;
}

sub get_tag_info {

    ## Given a tag, return a hashref of information about it

    my $tagname = shift;

    my $command = qq{git show "$tagname"};
    my $result  = run_git_command($command);

    debug substr($result, 0, 400) . "\n\n";

    ## Sanity check
    if ($result !~ /^tag $tagname$/m) {
        die "Invalid tag information returned from $command\n";
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

    ## Taken from bom-postgres-clientdb/tools/manifest.sql:
    my $SQL = <<EOF;
WITH excl(nsp, proc) AS (VALUES
    ('public', 'heap_page_item_attrs')
)
SELECT md5(pg_get_functiondef(p.oid)) AS md5, p.oid::regproc::text
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid=p.pronamespace
  JOIN pg_language l ON l.oid=p.prolang
  LEFT JOIN excl ON excl.nsp=n.nspname AND excl.proc=p.proname
 WHERE n.nspname NOT IN ('sequences', 'information_schema', 'pg_catalog')
   AND p.probin IS NULL
   AND l.lanname NOT IN ('internal', 'c')
   AND excl.proc IS NULL AND excl.nsp IS NULL
 ORDER BY n.nspname, 2, 1
EOF

    my %db_func_hash;
    my $command = qq{psql service="$db" -AX -qt -c "$SQL"};
    debug "Running: $command";
    my $res = qx{ $command };
    while ($res =~ /([a-f0-9]+)\|(.+)/g) {
        $db_func_hash{$2} = $1;
    }

    keys %db_func_hash or die qq{Could not get database function checksums\n};

    if ($verbose) {
        my $count = keys %db_func_hash;
        print "Entries found in database $db: $count\n";
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
        die "Could not find token file: $tokenfile";
    }

    my $data = $tokenfile->slurp_utf8;
    if ($data =~ /token:\s*([a-f0-9]+)/) {
        my $token = $1;
        my $len   = length $token;
        debug "Found a token of length $len in file: $tokenfile";
        return $token;
    }

    die "File does not contain a token: $tokenfile\n";
}

sub get_all_options {

    ## Set some default options
    %opt = (
        verbose => 0,
        debug   => 0,
        quiet   => 0,
        githome => "$ENV{HOME}/repos",
    );

    GetOptions(\%opt, 'verbose', 'debug+', 'quiet|q', 'database|db=s', 'repo|repository=s', 'githome=s', 'tokenfile=s', 'help|h',) or die;

    if ($opt{help} or !$opt{repo} or !$opt{database}) {    ## no critic
        die "$USAGE\n";
    }

    $verbose = $opt{verbose};
    $quiet   = $opt{quiet};
    $repo    = $opt{repo};
    $repodir = path($opt{githome} || $ENV{HOME}, $repo);
    $db      = $opt{database};

    return \%opt;

}
