use strict;
use warnings;
use Date::Utility;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use Devel::Refcount qw(refcount);

use Test::More;
use Test::Deep;

use BOM::Test::Helper qw/test_schema build_wsapi_test/;
use BOM::Product::Contract::PredefinedParameters qw(generate_trading_periods);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use Binary::WebSocketAPI::v3::Instance::Redis qw| redis_pricer |;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Platform::RedisReplicated;
use Sereal::Encoder;

my $encoder   = Sereal::Encoder->new({
    canonical => 1,
});

my $redis = BOM::Platform::RedisReplicated::redis_write();
my @tick_data;
for (my $epoch=time - 80*15; $epoch <= time; $epoch+=15) {
    push @tick_data, +{symbol => 'frxUSDJPY', epoch => $epoch, decimate_epoch => $epoch, quote => 100 + rand(0.0001)};
}

$redis->zadd('DECIMATE_frxUSDJPY_15s_DEC', $_->{epoch}, $encoder->encode($_)) for @tick_data;

#use BOM::Test::RPC::BomRpc;
#use BOM::Test::RPC::PricingRpc;

my $response;

my $currency = "USD";
my $lc       = 'costarica';
my $pt       = 'multi_barrier';
my $symbol   = "frxUSDJPY";

my $now = Date::Utility->new;

my $contract_type_pairs = {
    "PUT"           => "CALLE",
    "ONETOUCH"      => "NOTOUCH",
    "EXPIRYMISS"    => "EXPIRYRANGEE",
    "RANGE"         => "UPORDOWN",
};

my $trading_frames = {};

generate_trading_periods($symbol);
initialize_realtime_ticks_db();


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
            symbol        => $symbol,
            recorded_date => $now
        });

#Add extra tick for 2 minutes, this is because for USDJPY the minimum duration
#was increase from 1 to 3 minutes
for (my $cnt=0; $cnt < 3; $cnt+=1) {
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => $symbol,
        epoch      => $now->epoch + 60 * $cnt,
        quote      => 100,
        });
}

my $t = build_wsapi_test();

my $contracts_for = $t->await::contracts_for( {
        "contracts_for"     => $symbol,
        "currency"          => $currency,
        "landing_company"   => $lc,
        "product_type"      => $pt,
});


my @contract_types = (keys %$contract_type_pairs, values %$contract_type_pairs);
my $proposal_array_variants = {};
for my $i (0 .. $#{$contracts_for->{contracts_for}{available}}) {
    my $tf = $contracts_for->{contracts_for}{available}[$i]{trading_period}{duration};
    $trading_frames->{$tf} = 1;
    my $ct = $contracts_for->{contracts_for}{available}[$i]{contract_type};
    next unless exists $contract_type_pairs->{$ct};
    my $key = $ct.'_'.$contract_type_pairs->{$ct}.'_'.$tf;
    next if exists $proposal_array_variants->{$key};
    $proposal_array_variants->{$key} = {
        available_barriers      => $contracts_for->{contracts_for}{available}[$i]{available_barriers},
        barriers                => $contracts_for->{contracts_for}{available}[$i]{barriers},
        date_expiry             => $contracts_for->{contracts_for}{available}[$i]{trading_period}{date_expiry}{epoch},
        trading_period_start    => $contracts_for->{contracts_for}{available}[$i]{trading_period}{date_start}{epoch},
    };
}

my $proposal_array_req_tpl = {
    'symbol' => $symbol,
    'req_id' => '1',
    'barriers' => undef,
    'date_expiry' => undef,
    'currency' => 'JPY',
    'amount' => '100',
    'trading_period_start' => undef,
    'basis' => 'payout',
    'proposal_array' => '1',
    'contract_type' => undef,
    'passthrough' => {}
};

subtest 'allcombinations' => sub {
    for my $key (keys %$proposal_array_variants) {
        my ($ct1, $ct2) = split '_', $key;
        my $data = $proposal_array_variants->{$key};
        my $fbarriers = [];
        if ($data->{barriers} == 2) {
            $fbarriers = [map { {barrier2 => $_->[0], barrier => $_->[1]} } @{$data->{available_barriers}}]
        } else {
            $fbarriers = [map { {barrier=>$_} } @{$data->{available_barriers}}];
        }
        $proposal_array_req_tpl->{barriers}                 = $fbarriers;
        $proposal_array_req_tpl->{date_expiry}              = $data->{date_expiry};
        $proposal_array_req_tpl->{trading_period_start}     = $data->{trading_period_start};
        $proposal_array_req_tpl->{contract_type}            = [$ct1, $ct2];
        my $response = $t->await::proposal_array($proposal_array_req_tpl);
        test_schema('proposal_array', $response);
    }
};


my $put = [grep { $_->{contract_type} eq 'PUT' and $_->{trading_period}{duration} eq '2h15m'} @{$contracts_for->{contracts_for}{available}}]->[0];

my $barriers = $put->{available_barriers};
my $fixed_bars= [map {{barrier=>$_}} @$barriers];

if ($put->{trading_period}{date_expiry}{epoch} - Date::Utility->new->epoch <= 900) {
    BAIL_OUT( "Too close to the trading window border. Trading is not offered for this duration.");
    done_testing();
    exit;
}

subtest "one barrier, one contract_type" => sub {

    $proposal_array_req_tpl->{barriers}                 = $fixed_bars;
    $proposal_array_req_tpl->{date_expiry}              = $put->{trading_period}{date_expiry}{epoch};
    $proposal_array_req_tpl->{trading_period_start}     = $put->{trading_period}{date_start}{epoch};
    $proposal_array_req_tpl->{contract_type}            = ['CALLE', 'PUT'];

    $response = $t->await::proposal_array($proposal_array_req_tpl);
    test_schema('proposal_array', $response);

    $proposal_array_req_tpl->{barriers}                 = [{barrier => $put->{available_barriers}[0]}];

    $response = $t->await::proposal_array($proposal_array_req_tpl);
    test_schema('proposal_array', $response);

    $proposal_array_req_tpl->{barriers}                 = $fixed_bars,
    $proposal_array_req_tpl->{contract_type}            = ['CALLE'];

    $response = $t->await::proposal_array($proposal_array_req_tpl);
    test_schema('proposal_array', $response);

    $proposal_array_req_tpl->{barriers}                 = [{barrier => $put->{available_barriers}[0]}];

    $response = $t->await::proposal_array($proposal_array_req_tpl);
    test_schema('proposal_array', $response);
};

subtest "various results" => sub {

# We add 120 here because we want to increase the duration from 1 to 3 minutes.
    $proposal_array_req_tpl->{date_expiry}              = $put->{trading_period}{date_expiry}{epoch} + 120;
    $proposal_array_req_tpl->{trading_period_start}     = $put->{trading_period}{date_start}{epoch};
# And this line is to fix the minimum stake validation failure.
    $proposal_array_req_tpl->{amount}                   = 200;
    $proposal_array_req_tpl->{barriers}                 = [{barrier => 97.2}];
    $proposal_array_req_tpl->{contract_type}            = ['CALLE'];

    $response = $t->await::proposal_array($proposal_array_req_tpl);
    test_schema('proposal_array', $response);

    ok $response->{proposal_array}{proposals}{CALLE}[0]{ask_price}, "proposal is ok, price presented";

    $proposal_array_req_tpl->{barriers}                 = [{barrier => 99}];
    $response = $t->await::proposal_array($proposal_array_req_tpl);
    test_schema('proposal_array', $response);
    ok $response->{proposal_array}{proposals}{CALLE}[0]{error}, "ContractBuyValidationError : Minimum stake of 35 and maximum payout of 100000.";

    $proposal_array_req_tpl->{barriers}                 = [{barrier => 95}];
    $response = $t->await::proposal_array($proposal_array_req_tpl);
    test_schema('proposal_array', $response);
    ok $response->{proposal_array}{proposals}{CALLE}[0]{error}, "ContractBuyValidationError : This contract offers no return.";
};

subtest 'subscriptions' => sub {
    $proposal_array_req_tpl->{date_expiry}              = $put->{trading_period}{date_expiry}{epoch};
    $proposal_array_req_tpl->{trading_period_start}     = $put->{trading_period}{date_start}{epoch};

    $proposal_array_req_tpl->{barriers}                 = [{barrier => 97}];
    $proposal_array_req_tpl->{contract_type}            = ['CALLE'];

    $proposal_array_req_tpl->{subscribe}                = 1;

    $response = $t->await::proposal_array($proposal_array_req_tpl);
    test_schema('proposal_array', $response);

    is(scalar keys %{$t->app->pricing_subscriptions()}, 1, "Subscription created");
    my $channel = [keys %{$t->app->pricing_subscriptions()}]->[0];
    is(refcount($t->app->pricing_subscriptions()->{$channel}), 1, "check refcount");
    ok(redis_pricer->get($channel), "check redis subscription");

    $response = $t->await::forget_all({forget_all => "proposal_array"});
    is($t->app->pricing_subscriptions()->{$channel}, undef, "Forgotten");
};


$t->finish_ok;

done_testing();

