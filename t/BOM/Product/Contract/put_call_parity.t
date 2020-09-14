#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 4;
use Test::Warnings;
use Test::Exception;
use Date::Utility;
use Format::Util::Numbers qw/roundcommon/;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Product::ContractFactory qw(produce_contract);

use Cache::RedisDB;
use BOM::Config::Redis;

initialize_realtime_ticks_db();
my $now = Date::Utility->new('1-Mar-2017');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc('economic_events', {recorded_date => $now});
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        rates => {
            1   => 0.683,
            7   => 0.71,
            30  => 0.847,
            90  => 1.106,
            180 => 1.225,
            365 => 1.365
        },
        recorded_date => $now,
        symbol        => 'USD',
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        rates => {
            7   => 0.001,
            30  => -0.052,
            90  => -0.008,
            180 => 0.024,
            365 => 0.13
        },
        recorded_date => $now,
        symbol        => 'JPY',
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        rates => {
            1   => 1.525,
            30  => 1.64,
            90  => 1.79,
            180 => 2,
            365 => 1.839
        },
        recorded_date => $now,
        symbol        => 'AUD',
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        rates => {
            1   => -0.0273,
            7   => -0.4626,
            30  => -0.8753,
            90  => -0.5304,
            180 => -0.5374,
            365 => -0.5863
        },
        recorded_date => $now,
        symbol        => 'JPY-USD',
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        rates => {
            1   => 1.7002,
            7   => 1.765,
            30  => 2.4477,
            90  => 2.3414,
            180 => 2.4712,
            365 => 2.7343
        },
        recorded_date => $now,
        symbol        => 'AUD-JPY',
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => $_,
        recorded_date => $now
    }) for qw(frxUSDJPY frxAUDJPY frxAUDUSD);

BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxUSDJPY',
    quote      => 114.3,
    epoch      => $now->epoch
});
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxUSDJPY',
    epoch      => $now->epoch + 1,
    quote      => 114.5,
});

my $redis     = BOM::Config::Redis::redis_replicated_write();
my $undec_key = "DECIMATE_frxUSDJPY" . "_31m_FULL";
my $encoder   = Sereal::Encoder->new({
    canonical => 1,
});
my %defaults = (
    symbol => 'frxUSDJPY',
    epoch  => $now->epoch,
    quote  => 114.3,
    bid    => 114.3,
    ask    => 114.3,
    count  => 1,
);
$redis->zadd($undec_key, $defaults{epoch}, $encoder->encode(\%defaults));

$defaults{epoch} = $now->epoch + 1;
$defaults{quote} = 114.5;
$redis->zadd($undec_key, $defaults{epoch}, $encoder->encode(\%defaults));

subtest 'put_call_parity_IH_basic' => sub {

    my @shortcode = (
        "CALL_FRXUSDJPY_10_1488326400_1488327300_S0P_0",  "CALL_FRXUSDJPY_10_1488326400_1488327300_S2P_0",
        "CALLE_FRXUSDJPY_10_1488326400_1488327300_S0P_0", "CALLE_FRXUSDJPY_10_1488326400_1488327300_S0P_0",
        "CALLE_FRXUSDJPY_10_1488326400_1488330000_S0P_0", "CALLE_FRXUSDJPY_10_1488326400_1488344400_S0P_0"
    );

    foreach my $shortcode (@shortcode) {

        foreach my $currency ('AUD', 'USD') {
            my $c1 = produce_contract($shortcode, $currency);
            my $p  = $c1->build_parameters;
            $p->{date_pricing} = $c1->date_start;
            # test was done with the assumption of 10% pricing vol
            $p->{pricing_vol} = 0.1;
            my $c = produce_contract($p);
            isa_ok $c->pricing_engine, 'BOM::Product::Pricing::Engine::Intraday::Forex';
            my $call_theo_prob = $c->pricing_engine->base_probability->amount;
            my $put_theo_prob  = $c->opposite_contract->pricing_engine->base_probability->amount;
            is $call_theo_prob + $put_theo_prob, '1', "put call parity hold for " . $c->shortcode . " with payout currency $currency";
        }
    }
};

subtest 'put_call_parity_slope_basic' => sub {

    my @shortcode = (
        "CALL_FRXUSDJPY_10_1488326400_1489017599_S0P_0",                      "CALL_FRXUSDJPY_10_1488326400_1489017599_S2P_0",
        "CALLE_FRXUSDJPY_10_1488326400_1491263999_S0P_0",                     "CALLE_FRXUSDJPY_10_1488326400_1491263999_S2P_0",
        "CALLE_FRXUSDJPY_10_1488326400_1519948799_S0P_0",                     "CALLE_FRXUSDJPY_10_1488326400_1519948799_S0P_0",
        "EXPIRYRANGE_FRXUSDJPY_10_1488326400_1489017599_114500000_113500000", "EXPIRYRANGE_FRXUSDJPY_10_1488326400_1491263999_115000000_113500000",
        "EXPIRYRANGE_FRXUSDJPY_10_1488326400_1491263999_115500000_113500000", "EXPIRYRANGE_FRXUSDJPY_10_1488326400_1519948799_116000000_113500000",
        "EXPIRYRANGE_FRXUSDJPY_10_1488326400_1519948799_118000000_113500000",
    );

    foreach my $shortcode (@shortcode) {

        foreach my $currency ('AUD', 'USD') {
            my $c1 = produce_contract($shortcode, $currency);
            my $p  = $c1->build_parameters;
            $p->{date_pricing} = $c1->date_start;
            my $c = produce_contract($p);
            isa_ok $c->pricing_engine, 'Pricing::Engine::EuropeanDigitalSlope';
            my $c_type        = $c->pricing_code;
            my $opposite_type = $c->opposite_contract->pricing_code;
            $c->ask_price;
            $c->bid_price;
            my $call_theo_prob  = $c->pricing_engine->_base_probability;
            my $put_theo_prob   = $c->opposite_contract->pricing_engine->_base_probability;
            my $discounted_prob = exp(-$c->discount_rate * $c->timeinyears->amount);
            is roundcommon(0.0000000001, $call_theo_prob + $put_theo_prob), roundcommon(0.0000000001, $discounted_prob),
                "put call parity hold for " . $c->shortcode . " with payout currency $currency";
        }
    }
};

subtest 'put_call_parity_vv_basic' => sub {
    # For vv, the theo_prob are not sum up to the discounted probability because one is price with pay out at hit[one touch] and another one is pay out at end [notouch]
    my @shortcode = (
        "ONETOUCH_FRXUSDJPY_10_1488326400_1489017599_114500000_0",      "ONETOUCH_FRXUSDJPY_10_1488326400_1491263999_115000000_0",
        "ONETOUCH_FRXUSDJPY_10_1488326400_1491263999_115500000_0",      "ONETOUCH_FRXUSDJPY_10_1488326400_1519948799_116000000_0",
        "ONETOUCH_FRXUSDJPY_10_1488326400_1519948799_118000000_0",      "RANGE_FRXUSDJPY_10_1488326400_1489017599_114500000_113500000",
        "RANGE_FRXUSDJPY_10_1488326400_1491263999_115500000_113500000", "RANGE_FRXUSDJPY_10_1488326400_1519948799_116000000_113500000",
        "RANGE_FRXUSDJPY_10_1488326400_1519948799_118000000_113500000",
    );

    foreach my $shortcode (@shortcode) {
        foreach my $currency ('AUD', 'USD') {
            my $c1 = produce_contract($shortcode, $currency);
            my $p  = $c1->build_parameters;
            $p->{date_pricing} = $c1->date_start;
            my $c = produce_contract($p);
            isa_ok $c->pricing_engine, 'BOM::Product::Pricing::Engine::VannaVolga::Calibrated';
            my $contract_theo_prob          = $c->pricing_engine->base_probability->amount;
            my $opposite_contract_theo_prob = $c->opposite_contract->pricing_engine->base_probability->amount;
            my $discounted_prob             = roundcommon(0.1, exp(-$c->discount_rate * $c->timeinyears->amount));
            is roundcommon(0.1, $contract_theo_prob + $opposite_contract_theo_prob), $discounted_prob,
                "put call parity hold for " . $c->shortcode . " with payout currency $currency";
        }
    }
};

