#!/etc/rmg/bin/perl
use strict;
use warnings;
use BOM::Platform::Script::TradeWarnings;
use Getopt::Long;
use Path::Tiny;
use Log::Any qw($log);

# pid_file is used by external program to manage the process.

GetOptions(
    'pid-file=s' => \(my $pid_file),
    'l|log=s'    => \(my $log_level = "info"),
) or die "Usage: $0 --pid-file=/tmp/$0.pid --log=<log_level>\n";

require Log::Any::Adapter;
Log::Any::Adapter->import(qw(Stderr), log_level => $log_level);

if ($pid_file) {
    $pid_file = Path::Tiny->new($pid_file);
    $pid_file->spew($$);
}
my $exit_code = BOM::Platform::Script::TradeWarnings::run();
$pid_file->remove if ($pid_file);
exit $exit_code;
