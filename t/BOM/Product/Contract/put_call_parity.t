#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 6;
use Test::Exception;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use Format::Util::Numbers qw(roundnear);
use Date::Utility;
use BOM::Product::ContractFactory qw(produce_contract);

use Cache::RedisDB;
use BOM::Platform::RedisReplicated;

initialize_realtime_ticks_db();
my $now = Date::Utility->new('1-Mar-2017');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        rates => {
            1   => 0,
            7   => 0,
            30  => 0,
            90  => 0,
            180 => 0,
            380 => 0
        },
        recorded_date => $now,
        symbol        => $_,
    }) for qw( USD JPY JPY-USD AUD-JPY AUD AUD-USD);
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

my $redis     = BOM::Platform::RedisReplicated::redis_write();
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

subtest 'put_call_parity_IH_non_japan' => sub {

    my @shortcode = (
        "CALL_FRXUSDJPY_10_1488326400_1488327300_S0P_0",  "CALL_FRXUSDJPY_10_1488326400_1488327300_S2P_0",
        "CALLE_FRXUSDJPY_10_1488326400_1488327300_S0P_0", "CALLE_FRXUSDJPY_10_1488326400_1488327300_S2P_0",
        "CALLE_FRXUSDJPY_10_1488326400_1488330000_S0P_0", "CALLE_FRXUSDJPY_10_1488326400_1488344400_S0P_0"
    );

    foreach my $shortcode (@shortcode) {

        my $c1 = produce_contract($shortcode, 'USD');
        my $p = $c1->build_parameters;
        $p->{date_pricing} = $c1->date_start;
        my $c = produce_contract($p);
        isa_ok $c->pricing_engine, 'BOM::Product::Pricing::Engine::Intraday::Forex';
        my $call_theo_prob = $c->pricing_engine->base_probability->amount;
        my $put_theo_prob  = $c->opposite_contract->pricing_engine->base_probability->amount;
        is $call_theo_prob + $put_theo_prob, '1', "put call parity hold for " . $c->shortcode;
    }
};

subtest 'put_call_parity_IH_japan' => sub {

    my @shortcode = (
        "CALLE_FRXUSDJPY_1000_1488326400_1488326520F_114000000_0", "CALLE_FRXUSDJPY_10_1488326400_1488327300F_114000000_0",
        "CALLE_FRXUSDJPY_10_1488326400_1488327300F_114000000_0",   "CALLE_FRXUSDJPY_10_1488326400_1488344400F_114000000_0",
        "CALLE_FRXUSDJPY_10_1488326400_1488369600F_114000000_0",   "CALLE_FRXUSDJPY_10_1488326400_1488384000F_114000000_0",
        "CALLE_FRXUSDJPY_10_1488326402_1488412799F_114000000_0",
        "ONETOUCH_FRXUSDJPY_1000_1488326400_1488344400F_114200000_0", "ONETOUCH_FRXUSDJPY_1000_1488326400_1488326700F_114130000_0",

    );

    foreach my $shortcode (@shortcode) {

        my $c1 = produce_contract($shortcode, 'JPY');
        my $p = $c1->build_parameters;
        $p->{date_pricing}    = $c1->date_start;
        $p->{landing_company} = 'japan';
        my $c = produce_contract($p);
        isa_ok $c->pricing_engine, 'BOM::Product::Pricing::Engine::Intraday::Forex';
        my $call_theo_prob = $c->pricing_engine->base_probability->amount;
        my $put_theo_prob  = $c->opposite_contract->pricing_engine->base_probability->amount;
        is $call_theo_prob + $put_theo_prob, '1', "put call parity hold for " . $c->shortcode;
    }
};

subtest 'put_call_parity_slope_non_japan' => sub {

    my @shortcode = (
        "CALL_FRXUSDJPY_10_1488326400_1489017599_S0P_0",                      "CALL_FRXUSDJPY_10_1488326400_1489017599_S2P_0",
        "CALLE_FRXUSDJPY_10_1488326400_1491263999_S0P_0",                     "CALLE_FRXUSDJPY_10_1488326400_1491263999_S2P_0",
        "CALLE_FRXUSDJPY_10_1488326400_1519948799_S0P_0",                     "CALLE_FRXUSDJPY_10_1488326400_1519948799_S0P_0",
        "EXPIRYRANGE_FRXUSDJPY_10_1488326400_1489017599_114500000_113500000", "EXPIRYRANGE_FRXUSDJPY_10_1488326400_1491263999_115000000_113500000",
        "EXPIRYRANGE_FRXUSDJPY_10_1488326400_1491263999_115500000_113500000", "EXPIRYRANGE_FRXUSDJPY_10_1488326400_1519948799_116000000_113500000",
        "EXPIRYRANGE_FRXUSDJPY_10_1488326400_1519948799_118000000_113500000",
    );

    foreach my $shortcode (@shortcode) {

        my $c1 = produce_contract($shortcode, 'AUD');
        my $p = $c1->build_parameters;
        $p->{date_pricing} = $c1->date_start;
        my $c = produce_contract($p);
        isa_ok $c->pricing_engine, 'Pricing::Engine::EuropeanDigitalSlope';
        my $call_theo_prob  = $c->pricing_engine->_base_probability;
        my $put_theo_prob   = $c->opposite_contract->pricing_engine->_base_probability;
        my $discounted_prob = $c->discounted_probability->amount;
        is $call_theo_prob + $put_theo_prob, $discounted_prob, "put call parity hold for " . $c->shortcode;
    }
};

subtest 'put_call_parity_slope_japan' => sub {

    my @shortcode = (
        "CALLE_FRXUSDJPY_1000_1488326400_1520110800F_114000000_0",
        "CALLE_FRXUSDJPY_10_1488326400_1491091199F_114000000_0",
        "CALLE_FRXUSDJPY_10_1488326400_1496361599F_114000000_0",
        "CALLE_FRXUSDJPY_10_1488326400_1514581200F_114000000_0",
        "EXPIRYRANGE_FRXUSDJPY_10_1488326400_1520110800F_114300000_113800000",
        "EXPIRYRANGE_FRXUSDJPY_10_1488326400_1491091199F_115000000_113500000",
        "EXPIRYRANGE_FRXUSDJPY_10_1488326400_1496361599F_115500000_113500000",
        "EXPIRYRANGE_FRXUSDJPY_10_1488326400_1514581200F_118000000_113500000",
    );

    foreach my $shortcode (@shortcode) {

        my $c1 = produce_contract($shortcode, 'JPY');
        my $p = $c1->build_parameters;
        $p->{date_pricing}    = $c1->date_start;
        $p->{landing_company} = 'japan';
        my $c = produce_contract($p);
        isa_ok $c->pricing_engine, 'Pricing::Engine::EuropeanDigitalSlope';
        my $call_theo_prob  = $c->pricing_engine->_base_probability;
        my $put_theo_prob   = $c->opposite_contract->pricing_engine->_base_probability;
        my $discounted_prob = $c->discounted_probability->amount;
        is $call_theo_prob + $put_theo_prob, $discounted_prob, "put call parity hold for " . $c->shortcode;

    }
};

subtest 'put_call_parity_vv_non_japan' => sub {

    my @shortcode = (
        "ONETOUCH_FRXUSDJPY_10_1488326400_1489017599_114500000_0",      "ONETOUCH_FRXUSDJPY_10_1488326400_1491263999_115000000_0",
        "ONETOUCH_FRXUSDJPY_10_1488326400_1491263999_115500000_0",      "ONETOUCH_FRXUSDJPY_10_1488326400_1519948799_116000000_0",
        "ONETOUCH_FRXUSDJPY_10_1488326400_1519948799_118000000_0",      "RANGE_FRXUSDJPY_10_1488326400_1489017599_114500000_113500000",
        "RANGE_FRXUSDJPY_10_1488326400_1491263999_115500000_113500000", "RANGE_FRXUSDJPY_10_1488326400_1519948799_116000000_113500000",
        "RANGE_FRXUSDJPY_10_1488326400_1519948799_118000000_113500000",
    );

    foreach my $shortcode (@shortcode) {

        my $c1 = produce_contract($shortcode, 'AUD');
        my $p = $c1->build_parameters;
        $p->{date_pricing} = $c1->date_start;
        my $c = produce_contract($p);
        isa_ok $c->pricing_engine, 'BOM::Product::Pricing::Engine::VannaVolga::Calibrated';
        my $call_theo_prob  = $c->pricing_engine->base_probability->amount;
        my $put_theo_prob   = $c->opposite_contract->pricing_engine->base_probability->amount;
        my $discounted_prob = $c->discounted_probability->amount;
        is $call_theo_prob + $put_theo_prob, $discounted_prob, "put call parity hold for " . $c->shortcode;
    }
};

subtest 'put_call_parity_vv_japan' => sub {

    my @shortcode = (
        "ONETOUCH_FRXUSDJPY_1000_1488326400_1520110800F_114500000_0",      "ONETOUCH_FRXUSDJPY_1000_1488326400_1491091199F_115000000_0",
        "ONETOUCH_FRXUSDJPY_1000_1488326400_1496361599F_116000000_0",      "ONETOUCH_FRXUSDJPY_1000_1488326400_1514581200F_118000000_0",
        "RANGE_FRXUSDJPY_1000_1488326400_1520110800F_114500000_113500000", "RANGE_FRXUSDJPY_1000_1488326400_1491091199F_115500000_113500000",
        "RANGE_FRXUSDJPY_1000_1488326400_1496361599F_116000000_113500000", "RANGE_FRXUSDJPY_1000_1488326400_1514581200F_118000000_113500000",
    );

    foreach my $shortcode (@shortcode) {

        my $c1 = produce_contract($shortcode, 'JPY');
        my $p = $c1->build_parameters;
        $p->{date_pricing}    = $c1->date_start;
        $p->{landing_company} = 'japan';
        my $c = produce_contract($p);
        isa_ok $c->pricing_engine, 'BOM::Product::Pricing::Engine::VannaVolga::Calibrated';
        my $call_theo_prob  = $c->pricing_engine->base_probability->amount;
        my $put_theo_prob   = $c->opposite_contract->pricing_engine->base_probability->amount;
        my $discounted_prob = $c->discounted_probability->amount;
        is $call_theo_prob + $put_theo_prob, $discounted_prob, "put call parity hold for " . $c->shortcode;

    }
};

