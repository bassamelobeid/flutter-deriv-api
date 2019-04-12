use strict;
use warnings;

use Test::Most;
use Test::Exception;
use Test::Warnings qw/warning/;
use Scalar::Util qw( looks_like_number );
use Test::MockModule;
use File::Spec;
use Date::Utility;

use BOM::Product::ContractFactory qw( produce_contract );
use Finance::Contract::Longcode qw( shortcode_to_parameters );
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => Date::Utility->new('2008-01-01'),
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => 'USD',
        recorded_date => Date::Utility->new(1200614400),
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => 'JPY',
        recorded_date => Date::Utility->new('6-Feb-08'),
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'randomindex',
    {
        symbol => 'R_100',
        date   => Date::Utility->new
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => 'JPY-USD',
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
        recorded_date => Date::Utility->new(1200614400),
        type          => 'implied',
        implied_from  => 'USD'
    });

#create an empty un-used even so ask_price won't fail preparing market data for pricing engine
#Because the code to prepare market data is called for all pricings in Contract
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'economic_events',
    {
        events => [{
                symbol       => 'USD',
                release_date => 1,
                source       => 'forexfactory',
                event_name   => 'FOMC',
            }]});

use BOM::Product::ContractFactory qw( produce_contract );

my $res;
subtest 'Numbers and stuff.' => sub {

    my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => 1200614400,
        quote      => 76
    });
    my $bet_params = {
        bet_type     => 'CALL',
        date_expiry  => '13-Feb-08',             # 13-Feb-08 107.36 108.38 106.99 108.27
        date_pricing => '2008-02-13 23:59:59',
        date_start   => 1200614400,              # 18-Jan-08 106.42 107.59 106.38 106.88
        underlying   => 'frxUSDJPY',
        payout       => 1,
        currency     => 'USD',
        barrier      => 108.26,
        current_spot => 76,
    };

    my $bet = produce_contract($bet_params);

    $res = $bet->pricing_vol;
    ok(looks_like_number($res),             'Pricing iv looks like a number.');
    ok(looks_like_number($bet->pricing_mu), 'Pricing mu looks like a number.');

    $res = $bet->bid_price;
    ok(looks_like_number($res), 'Bid price looks like a number.');

    ok(looks_like_number($bet->payout),     'Payout looks like a number.');
    ok(looks_like_number($bet->ask_price),  'Ask price looks like a number.');
    ok(looks_like_number($bet->theo_price), 'Theo price looks like a number.');

    lives_ok { shortcode_to_parameters($bet->shortcode) } 'Can extracts parameters from shortcode.';

    ok(not($bet->pricing_new), 'Pricing in the past, so we expect pricing_new to be false.');
    my $remaining_time = $bet->remaining_time;
    isa_ok($remaining_time, 'Time::Duration::Concise', 'remaining_time');
    cmp_ok($remaining_time->seconds, '==', 0, ' of 0 on expired.');

    my $max_ted = $bet->_max_tick_expiry_duration;
    isa_ok($max_ted, 'Time::Duration::Concise', 'max_tick_expiry_duration');
    cmp_ok($max_ted->minutes, '>=', 1, ' of at least one minute.');

    done_testing;
};

subtest 'Probabilities etc.' => sub {
    plan tests => 2;

    my $bet_params = {
        bet_type     => 'RANGE',
        date_expiry  => '6-Feb-08',
        date_pricing => '6-Feb-08',
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

    lives_ok {
        warning { $res = $bet->bid_probability }, qr/Volatility error:/;
    }
    "can call bid_probability for expired contract.";
};

subtest 'Forward starting.' => sub {
    plan tests => 2;

    # 1am tomorrow.
    my $date_start  = Date::Utility->new(Date::Utility->new->truncate_to_day->epoch + 86400 + 3600);
    my $date_expiry = Date::Utility->new($date_start->epoch + 600);
    my $tick        = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $date_start->epoch,
        quote      => 100
    });
    my $bet = produce_contract({
        bet_type                   => 'PUT',
        date_start                 => $date_start,
        date_expiry                => $date_expiry,
        underlying                 => 'R_100',
        payout                     => 100,
        currency                   => 'USD',
        current_spot               => 70000,
        is_forward_starting        => 1,
        starts_as_forward_starting => 1,
        barrier                    => 'S0P',
        current_tick               => $tick,
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

    my $bet          = produce_contract($bet_params);
    my $pricing_args = $bet->_pricing_args;
    is(ref $pricing_args, 'HASH', 'Pricing args is a HashRef.');

    cmp_bag(
        [keys %{$pricing_args}],
        [qw(barrier1 barrier2 iv payouttime_code q_rate r_rate spot t mu discount_rate)],
        'pricing_args has expected keys.'
    );
};

done_testing;
