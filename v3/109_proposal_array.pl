use strict;
use warnings;
use JSON;
use Date::Utility;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use Net::EmptyPort qw(empty_port);

use Test::More;
use Test::Deep;
use Test::MockTime qw( set_absolute_time );
use Test::MockModule;

use await;

use BOM::Test::Helper qw/test_schema build_wsapi_test call_mocked_client build_mojo_test/;
use BOM::Product::Contract::PredefinedParameters qw(generate_trading_periods);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Database::Model::OAuth;
use BOM::Platform::RedisReplicated;
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Platform::Runtime;

use BOM::Test::RPC::BomRpc;
use BOM::Test::RPC::PricingRpc;

#my $eleventh = Date::Utility->new('2010-01-11 02:00:00');
#set_absolute_time($eleventh->epoch);    # before opening time


my $currency = "USD";
my $lc       = 'costarica';
my $pt       = 'multi_barrier';
my $symbol   = "frxUSDJPY";

my $now = Date::Utility->new;

#build_test_frxUSDJPY_data();
generate_trading_periods('frxUSDJPY');
#initialize_realtime_ticks_db();


BOM::Test::Data::Utility::UnitTestMarketData::create_doc('currency', {symbol => $_}) for qw(USD JPY);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'economic_events',
        {
            events => [{
            symbol       => 'USD',
            release_date => 1,
            source       => 'forexfactory',
            impact       => 1,
            event_name   => 'FOMC',
            }]
        });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
        symbol        => 'frxUSDJPY',
        recorded_date => $now
        });
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => $now->epoch,
        quote      => 100,
        });
#BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
#        'randomindex',
#        {
#        symbol => 'frxUSDJPY',
#        date   => Date::Utility->new
#        });


    #BOM::Platform::RedisReplicated::redis_write->publish('FEED::R_50', 'R_50;1447998048;443.6823;');



my $t = build_wsapi_test();



my $contracts_for = $t->await::contracts_for( {
        "contracts_for"     => $symbol,
        "currency"          => $currency,
        "landing_company"   => $lc,
        "product_type"      => $pt,
});

my $put = [grep { $_->{contract_type} eq 'PUT' and $_->{trading_period}{duration} eq '2h15m'} @{$contracts_for->{contracts_for}{available}}]->[0];

note explain $put;

my $barriers = $put->{available_barriers};
my $fixed_bars= [map {{barrier=>$_}} @$barriers];

if ($put->{trading_period}{date_expiry}{epoch} - $now->epoch <= 600) {
    note "#############################################";
    note;
    note "Too close to the trading window border.";
    note "Trading is not offered for this duration.";
    note;
    note "#############################################";
    $t->finish_ok;
    done_testing();
    exit;
}

my $proposal_array_req = {
    'symbol' => 'frxUSDJPY',
    'req_id' => '1',
    'subscribe' => '1',
    'barriers' => $fixed_bars,
    'date_expiry' => $put->{trading_period}{date_expiry}{epoch},
    'currency' => 'JPY',
    'amount' => '100',
    'trading_period_start' => $put->{trading_period}{date_start}{epoch},
    'basis' => 'payout',
    'proposal_array' => '1',
    'contract_type' => [
        'CALLE',
        'PUT'
    ],
    'passthrough' => {}
};

my $response = $t->await::proposal_array($proposal_array_req);

note explain $response;


$t->finish_ok;

done_testing();



__DATA__

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'currency',
        {
        symbol        => $_,
        recorded_date => $now,
        }) for qw(USD JPY JPY-USD);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $now,
    });
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        quote      => 100,
        epoch      => $now->epoch - 1,
        underlying => 'frxUSDJPY',
});
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        quote      => 101,
        epoch      => $now->epoch,
        underlying => 'frxUSDJPY',
});

BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        quote      => 102,
        epoch      => $now->epoch + 1,
        underlying => 'frxUSDJPY',
});

