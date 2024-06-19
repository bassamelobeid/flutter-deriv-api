#!/usr/bin/perl

use strict;
use warnings;

# To run the script
#
# # This runs the script for the current time
# export PGPASSFILE=/home/nobody/.pgpass && perl /home/git/regentmarkets/bom-commission-management-service/bin/commission_calculator.pl --db_service=commission01 --cfd_provider=dxtrade
#
# # To run the script for a specific time
# export PGPASSFILE=/home/nobody/.pgpass && perl /home/git/regentmarkets/bom-commission-management-service/bin/commission_calculator.pl --db_service=commission01 --cfd_provider=dxtrade --date='2021-05-01 10:20:00'

use IO::Async::Loop;

use Date::Utility;
use Getopt::Long;
use Log::Any::Adapter qw(Stderr), log_level => $ENV{BOM_LOG_LEVEL} // 'warning';

use Commission::Calculator;

my $cfd_provider                = '';
my $affiliate_provider          = '';
my $db_service                  = '';
my $redis_exchange_rates_config = '';
my $per_page_limit;
my $concurrency;
my $date = Date::Utility->new->db_timestamp;
my $from_date;

GetOptions(
    "x|cfd_provider=s"               => \$cfd_provider,
    "p|affiliate_provider=s"         => \$affiliate_provider,
    "s|db_service=s"                 => \$db_service,
    "e|redis_exchange_rate_config=s" => \$redis_exchange_rates_config,
    "l|per_page_limit=i"             => \$per_page_limit,
    "c|concurrency=i"                => \$concurrency,
    "d|date=s"                       => \$date,
    "f|from_date=s"                  => \$from_date,
) or die("Error in command line arguments\n");

my $loop = IO::Async::Loop->new;

my $calc = Commission::Calculator->new(
    db_service                  => $db_service,
    cfd_provider                => $cfd_provider,
    affiliate_provider          => $affiliate_provider,
    date                        => $date,
    redis_exchange_rates_config => $redis_exchange_rates_config,
    per_page_limit              => $per_page_limit,
    concurrency_limit           => $concurrency,
    from_date                   => $from_date
);

$loop->add($calc);
$calc->calculate->get();
