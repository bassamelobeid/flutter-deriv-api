#!/etc/rmg/bin/perl
use strict;
use warnings;
use BOM::Platform::Script::NotifyPub;
use Getopt::Long;
use Path::Tiny;

# pid_file is used by external program to manage the process.
my $pid_file;

GetOptions("pid-file=s" => \$pid_file) || die "Usage: $0 --pid-file=/tmp/$0.pid\n";
if ($pid_file) {
    $pid_file = Path::Tiny->new($pid_file);
    $pid_file->spew($$);
}
my $exit_code = BOM::Platform::Script::NotifyPub::run();
$pid_file->remove if ($pid_file);
exit $exit_code;

