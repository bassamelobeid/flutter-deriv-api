#!/etc/rmg/bin/perl
use strict;
use warnings;

use Getopt::Long qw(GetOptions :config no_auto_abbrev no_ignore_case);
use BOM::Platform::Script::MonthlyClientReport;
use Pod::Usage;

=head1 SYNOPSIS

Writes the monthly debit credit reports. Executed as a monthly cron job in collector01,
and downloaded from monthly client reports in backoffice.

usage: $0 OPTIONS

 These options are available:
   -d, --date      Date in yyyy-mm format. Defaults to the past month
   -b, --brokers   Specify broker codes, separated by comma without spaces. Defaults
                     to "MLT,MX,MF,CR,CH"
   -r, --report    Specifies which reports to generate. Defaults to "debit,credit" (all
                     reports)
   -h, --help      Show this message.

=cut

GetOptions(
    'd|date:s'    => \my $date,
    'b|brokers:s@' => \my $brokers,
    'r|report:s@'  => \my $report,
    'h|help'      => \my $help,
);

pod2usage(-verbose => 1) if $help;

if ($brokers) {
    $brokers = [split /,/ => join ',' => @$brokers];
}

if ($report) {
    $report = [split /,/ => join ',' => @$report];
}

exit BOM::Platform::Script::MonthlyClientReport::run(
    date    => $date,
    brokers => $brokers,
    report  => $report
);
