#!/etc/rmg/bin/perl
use strict;
use warnings;
use BOM::Platform::Script::NotifyPub;
use Getopt::Long;
use Path::Tiny;

my $pid_file;
GetOptions("pid-file=s" => \$pid_file) || die "Bad options";
if ($pid_file) {
    $pid_file = Path::Tiny($pid_file);
    $pid_file->spew($$);
}
exit BOM::Platform::Script::NotifyPub::run();
