#!/etc/rmg/bin/perl

use strict;
use warnings;
use BOM::Market::Script::DecimateChecker;
use Getopt::Long qw(GetOptions :config no_auto_abbrev no_ignore_case);
use Log::Any::Adapter;

=head1 NAME

bom-feed-decimate.pl - Run feed decimate for checking ticks consistency

=head1 DESCRIPTION

This script will periodically fetches the values from replicated redis and
compares them from the ticks values for each symbol in the database.  In case
there's an inconsistency it will be reported to DataDog

=cut

GetOptions(
    'h|help'  => \my $help,
    'l|log=s' => \(my $log_level = "info"),
);

my $show_help = $help;
die <<"EOF" if ($show_help);
usage: $0 OPTIONS
These options are available:
  -h, --help                    Show this message.
  -l, --log LEVEL               Set the Log::Any logging level
EOF

# We use Log::Any::Adapter here because this module is the entrance of the whole program.
# https://wikijs.deriv.cloud/en/Backend/guides/perl/perl-style-guide#log-setup
require Log::Any::Adapter;
Log::Any::Adapter->import(
    qw(DERIV),
    stderr    => 'json',
    log_level => $log_level
);

exit BOM::Market::Script::DecimateChecker::run()->get;
