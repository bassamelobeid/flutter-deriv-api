use strict;
use warnings;
use BOM::MyAffiliatesCFDReport;
use Date::Utility;
use Pod::Usage;
use Getopt::Long;
use Log::Any::Adapter qw(Stderr), log_level => $ENV{BOM_LOG_LEVEL} // 'info';

my $help     = 0;
my $test_run = 0;
my $brand;
my $date = Date::Utility->new->truncate_to_day->minus_time_interval('1d')->epoch;

=head1 NAME

perl ./generate_cfd_reports.pl | This script generates and sends DerivX CSVs to myaffiliates

=head1 SYNOPSIS

./generate_and_send_derivx_csvs.pl -b 'brand_name'

=head1 OPTIONS

=over 20

=item B<-h>, B<--help>

Brief help message

=item B<-t>, B<--test> bool (default: 0)

Test run (will not send CSVs to myaffiliates)

=item B<-b>, B<--brand> string

(Required) Platform to generate CSVs for e.g. 'derivx' 

=item B<-d>, B<--date> string (default: yesterday date)

Date to generate CSVs for in YYYY-MM-DD format e.g. '2019-01-01'

=back

=cut

# used in database queries
my $brand_to_platform = {
    'derivx'  => 'dxtrade',
    'ctrader' => 'ctrader'
};

# used in CSV headers
my $brand_display_name = {
    'derivx'  => 'DerivX',
    'ctrader' => 'cTrader'
};

GetOptions(
    'h|help'    => \$help,
    't|test'    => \$test_run,
    'b|brand=s' => \$brand,
    'd|date=s'  => \$date,
) or pod2usage(2);

pod2usage(1)                                              if $help or not defined $brand;
$date = Date::Utility->new($date)->truncate_to_day->epoch if defined $date;

BOM::MyAffiliatesCFDReport->new(
    brand              => $brand,
    platform           => $brand_to_platform->{$brand}  // $brand,
    brand_display_name => $brand_display_name->{$brand} // $brand,
    date               => $date,
    test_run           => $test_run,
)->execute();

