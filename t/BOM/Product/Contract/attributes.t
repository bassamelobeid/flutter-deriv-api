use strict;
use warnings;

use Test::Most;
use Test::FailWarnings;
use Scalar::Util qw( looks_like_number );
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);

use Date::Utility;
use BOM::Test::Runtime qw(:normal);
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Product::ContractFactory::Parser qw( shortcode_to_parameters );

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Data::Utility::UnitTestCouchDB qw( :init );

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'currency_config',
    {
        symbol => $_,
        date   => Date::Utility->new,
    }) for qw( JPY USD );
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'exchange',
    {
        symbol => 'FOREX',
        date   => Date::Utility->new,
    });
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'exchange',
    {
        symbol => 'RANDOM',
        date   => Date::Utility->new,
    });
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => Date::Utility->new,
    });
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_flat',
    {
        symbol        => 'R_100',
        recorded_date => Date::Utility->new,
    });

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'currency',
    {
        symbol => $_,
        date   => Date::Utility->new,
    }) for (qw/JPY USD/);

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'randomindex',
    {
        symbol => 'R_100',
        date   => Date::Utility->new
    });

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'currency',
    {
        symbol => 'JPY',
        rates  => {
            1   => 0.2,
            2   => 0.15,
            7   => 0.18,
            32  => 0.25,
            62  => 0.2,
            92  => 0.18,
            186 => 0.1,
            365 => 0.13,
        },
        date         => Date::Utility->new,
        type         => 'implied',
        implied_from => 'USD'
    });

use BOM::Product::ContractFactory qw( produce_contract );

subtest 'Numbers and stuff.' => sub {
    plan tests => 13;

    my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => 1200614400,
        quote      => 76
    });
    my $bet_params = {
        bet_type     => 'CALL',
        date_expiry  => '13-Feb-08',    # 13-Feb-08 107.36 108.38 106.99 108.27
        date_start   => 1200614400,     # 18-Jan-08 106.42 107.59 106.38 106.88
        underlying   => 'frxUSDJPY',
        payout       => 1,
        currency     => 'USD',
        barrier      => 108.26,
        current_spot => 76,
    };

    my $bet = produce_contract($bet_params);

    ok(looks_like_number($bet->pricing_vol), 'Pricing iv looks like a number.');
    ok(looks_like_number($bet->pricing_mu),  'Pricing mu looks like a number.');
    ok(looks_like_number($bet->bid_price),   'Bid price looks like a number.');
    ok(looks_like_number($bet->payout),      'Payout looks like a number.');
    ok(looks_like_number($bet->ask_price),   'Ask price looks like a number.');
    ok(looks_like_number($bet->bs_price),    'BS price looks like a number.');
    ok(looks_like_number($bet->theo_price),  'Theo price looks like a number.');

    lives_ok { shortcode_to_parameters($bet->shortcode) } 'Can extracts parameters from shortcode.';

    ok(not($bet->pricing_new), 'Pricing in the past, so we expect pricing_new to be false.');

    my $calendar_minutes = $bet->calendar_minutes;
    isa_ok($calendar_minutes, 'Math::Util::CalculatedValue::Validatable', 'calculated_minutes is a CalcVal.');
    cmp_ok($calendar_minutes->amount, '==', 0, 'calculated_minutes value.');    # zero as bet has expired.

    my $max_ted = $bet->max_tick_expiry_duration;
    isa_ok($max_ted, 'Time::Duration::Concise', 'max_tick_expiry_duration');
    cmp_ok($max_ted->minutes, '>=', 1, ' of at least one minute.');
};

subtest 'Probabilities etc.' => sub {
    plan tests => 5;

    my $bet_params = {
        bet_type     => 'RANGE',
        date_expiry  => '6-Feb-08',
        date_start   => 1199836800,
        underlying   => 'frxUSDJPY',
        payout       => 1000,
        high_barrier => 110.0,
        low_barrier  => 106.0,
        current_spot => 109.87,
        currency     => 'JPY',
    };

    my $bet = produce_contract($bet_params);

    isa_ok($bet->discounted_probability, 'Math::Util::CalculatedValue::Validatable', 'isa CalculatedValue.');
    isa_ok($bet->bid_probability,        'Math::Util::CalculatedValue::Validatable', 'isa CalculatedValue.');

    my $otm_defaults = BOM::Platform::Runtime->instance->app_config->quants->commission->deep_otm_threshold;
    ok(BOM::Platform::Runtime->instance->app_config->quants->commission->deep_otm_threshold('{}'), 'Removed minimum theoreticals');
    $bet->market->clear_deep_otm_threshold;
    throws_ok { $bet->ask_probability } qr/Missing deep_otm_threshold for market/,
        'Markets with undefined minimum theoretical probabilities blow up.';
    ok(BOM::Platform::Runtime->instance->app_config->quants->commission->deep_otm_threshold($otm_defaults), 'Removed minimum theoreticals');
};

subtest 'Forward starting.' => sub {
    plan tests => 2;

    # 1am tomorrow.
    my $date_start  = Date::Utility->new(Date::Utility->new->truncate_to_day->epoch + 86400 + 3600);
    my $date_expiry = Date::Utility->new($date_start->epoch + 600);
    my $bet         = produce_contract({
        bet_type     => 'INTRADD',
        date_start   => $date_start,
        date_expiry  => $date_expiry,
        underlying   => 'R_100',
        payout       => 100,
        currency     => 'USD',
        current_spot => 70000,
    });

    ok(looks_like_number($bet->bid_price), 'Bid price is a number.');
    cmp_ok($bet->bid_price, '<', $bet->payout, 'Bid price is less than payout.');
};

subtest 'Range on R_100.' => sub {
    plan tests => 2;

    my $bet_params = {
        bet_type     => 'RANGE',
        date_start   => '1-Nov-12',
        date_expiry  => '2-Nov-12',
        underlying   => 'R_100',
        high_barrier => 80000,
        low_barrier  => 70000,
        payout       => 100,
        currency     => 'USD',
        current_spot => 70000,
    };

    # This really shouldn't be necessary :-/
    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'volsurface_flat',
        {
            symbol        => 'R_100',
            recorded_date => Date::Utility->new,
        });

    my $bet          = produce_contract($bet_params);
    my $pricing_args = $bet->pricing_args;
    is(ref $pricing_args, 'HASH', 'Pricing args is a HashRef.');

    cmp_bag([keys %{$pricing_args}], [qw(barrier1 barrier2 iv payouttime_code q_rate r_rate spot starttime t)], 'pricing_args has expected keys.');
};

subtest 'Exchange' => sub {
    plan tests => 1;

    my $bet_params = {
        bet_type     => 'RANGE',
        date_start   => '1-Nov-12',
        date_expiry  => '2-Nov-12',
        underlying   => 'R_100',
        high_barrier => 80000,
        low_barrier  => 70000,
        payout       => 100,
        currency     => 'USD',
        current_spot => 70000,
    };

    my $bet = produce_contract($bet_params);
    is($bet->exchange->symbol, $bet->underlying->exchange->symbol, ' Bet exchange matches that of underlying');

};

done_testing;
