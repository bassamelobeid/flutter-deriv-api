#!/usr/bin/env perl

## Download a "bootstrap" version of a database from S3 and restore it
## Note: this does not have production postgresql.conf and pg_hba.conf files
## Also, the database name is different, for safety

use strict;
use warnings;
use Getopt::Long   qw( GetOptions );
use File::Path     qw( make_path remove_tree );
use Time::Duration qw( duration );

our $VERSION = '1.01';

my $USAGE = "Usage: $0 --db=<cr or vr> [--verbose]\n";

my %opt = ();

GetOptions(\%opt, 'db=s', 'help', 'verbose+')
    or exit 1;

if ($opt{help}) {
    print "$USAGE\n";
    exit 0;
}

my $db      = $opt{db}      // die $USAGE;
my $verbose = $opt{verbose} // 0;

$verbose and print "Starting $0 version $VERSION\n";
$verbose and printf "--> Time:                         %s\n", scalar localtime;

if (!-f "$ENV{HOME}/.bootstrap.password") {
    die qq{Cannot proceed without a GPG password file\n};
}

my $s3_profile_name = "db-pgarchive-$db";
my $s3_bucket_name  = "binary-pgarchive-$db";

if ($verbose) {
    print "--> S3 profile name:              $s3_profile_name\n";
    print "--> S3 bucket name:               $s3_bucket_name\n";
}

my $file = "bootstrap.basebackup.$db.tar.xz.gpg";

my $start_time = time();
my $result     = run_command("aws s3 --profile $s3_profile_name cp s3://$s3_bucket_name/bootstrap/$file .");
$verbose and printf "--> Downloaded:                   %s (Time: %s)\n", $file, duration(time() - $start_time);

my $dbdir = 'bootstrap_database';
remove_tree($dbdir);
mkdir $dbdir, 0700;

$verbose and print "--> Created directory:            $dbdir\n";

$start_time = time();
my $gpg        = "gpg --quiet --batch --passphrase-file $ENV{HOME}/.bootstrap.password --output -";
my $decompress = 'xz -d';
my $detar      = "tar --directory $dbdir --extract";
$result = run_command(qq{ $gpg $file | $decompress | $detar });
if (length $result) {
    chomp $result;
    print "Something went wrong: $result\n";
    exit 1;
}

$verbose and printf "--> Restored base backup:         complete (Time: %s)\n", duration(time() - $start_time);

## Remove old customizations
$result = run_command(q{sed -i '/7777/,$d' } . "$dbdir/postgresql.conf");
$verbose and printf "--> File modified:                $dbdir/postgresql.conf\n";

## Cleanup
unlink $file;
$verbose and printf "--> Removed file:                 $file\n";

exit;

sub run_command {

    ## Shell out and run a command, return the result
    my $command = shift // 'Need a command';

    $verbose > 1 and print "ABOUT TO RUN: $command\n";

    my $output = qx{ $command 2>&1 };
    chomp $output;
    $verbose > 1 and print "RESULT: $output\n";

    return $output;

} ## end of run_command
