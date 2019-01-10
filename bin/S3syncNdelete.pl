#!/etc/rmg/bin/perl
use strict;
use warnings;

# There are a number of reporting scripts that generate files on the compliance server
# In order to keep the server clean and have these backed up, they need to be sent to S3
# This script performs the backup operation and after completing it, deletes them from the server.

# Note: this script needs to be run by the nobody user as it has/should have the profile definition file in it's ~/.aws directory
# Also, the directory tree is owned by the nobody user to allow deletes.

# It should be called something like this: S3syncNdelete.pl /reports binary-misc-backup binary_misc_backup
# although the bucket and the profile may not always seem identical
my ($directory, $bucket, $aws_profile) = @ARGV;
die "directory to backup, S3 bucket name and AWS profile name are required arguments" unless $directory && $bucket && $aws_profile;
die "directory to backup does not seem to be valid" unless -d $directory;

open my $fh, '-|', qq( /home/nobody/bin/aws s3 sync $directory s3://$bucket --profile $aws_profile ) or die "Cannot pipeopen AWS S3 - $!";

my ($rz, $fn, @err);

while (<$fh>) {
    $rz .= $_;

    if (m/upload: (.*) to .*/) {
        $fn = $1;
        unless (unlink $fn) {
            push @err, "Response line was this:\n$_\nCould not remove $fn: $!";
        }
    }
}

if (@err) {
    print "Syncing to S3 returned this result:\n$rz\nThere were issues with the following lines:\n";
    print "$_\n" foreach @err;
}

close $fh or die "AWS S3 exited nonzero - $?";

# The result of that S3 call is similar to this
# upload: ../../reports/RTP/MX/MX_2018-04-21_20170421_20180420.csv to s3://binary-misc-backup/RTP/MX/MX_2018-04-21_20170421_20180420.csv
# upload: ../../reports/RTP/MLT/MLT_2018-04-17_20170417_20180416.csv to s3://binary-misc-backup/RTP/MLT/MLT_2018-04-17_20170417_20180416.csv
# upload: ../../reports/RTP/MLT/MLT_2018-04-19_20170419_20180418.csv to s3://binary-misc-backup/RTP/MLT/MLT_2018-04-19_20170419_20180418.csv

# also, unfortunately, this sort of stuff sometimes
# Completed 1 file(s) with 2 file(s) remaining^Mupload: ../../reports/mnb.ky to s3://binary-misc-backup/mnb.ky
# Completed 2 file(s) with 1 file(s) remaining^Mupload: ../../reports/mnb.k to s3://binary-misc-backup/mnb.k
# Completed 619.7 KiB/~619.7 KiB (4.1 MiB/s) with ~0 file(s) remaining (calculating...)
