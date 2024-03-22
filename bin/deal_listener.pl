#!/usr/bin/perl

# To run this script
#
# export PGPASSFILE=/home/nobody/.pgpass && perl -Ilib /home/git/regentmarkets/bom-commission-management-service/bin/deal_listener.pl --redis_uri=redis://$REDIS_HOST$REDIS_PORT --redis_auth=$REDIS_PASSWORD --db_service=commission01 --redis_stream=$STREAM

use strict;
use warnings;

use IO::Async::Loop;
use Commission::Deal::DXTradeListener;
use Commission::Deal::CTraderListener;
use Getopt::Long;
use Log::Any::Adapter qw(Stderr), log_level => $ENV{BOM_LOG_LEVEL} // 'warning';

my $db_service           = '';
my $db_uri               = '';
my $redis_stream         = '';
my $provider             = '';
my $redis_consumer_group = '';
my $redis_config         = '';
GetOptions(
    "s|redis_stream=s"         => \$redis_stream,
    "g|redis_consumer_group=s" => \$redis_consumer_group,
    "p|provider=s"             => \$provider,
    "d|db_service=s"           => \$db_service,
    "u|db_uri=s"               => \$db_uri,
    "c|redis_config=s"         => \$redis_config,
) or die("Error in command line arguments\n");

my $loop = IO::Async::Loop->new;

my %listener_class = (
    dxtrade => "DXTradeListener",
    ctrader => "CTraderListener"
);

die 'Provider does not exist.' unless $listener_class{$provider};

my $listener = "Commission::Deal::$listener_class{$provider}"->new(
    db_service           => $db_service,
    db_uri               => $db_uri,
    redis_stream         => $redis_stream,
    redis_consumer_group => $redis_consumer_group,
    provider             => $provider,
    redis_config         => $redis_config,
);

$loop->add($listener);
$listener->start()->get;
