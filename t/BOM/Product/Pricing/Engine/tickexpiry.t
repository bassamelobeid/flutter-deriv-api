#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 5;
use Test::NoWarnings;
use Test::Exception;
use Test::MockModule;

use BOM::Product::Pricing::Engine::TickExpiry;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
initialize_realtime_ticks_db();

use Date::Utility;
use BOM::Product::ContractFactory qw(produce_contract);

my $now = Date::Utility->new('24-Dec-2014');

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('exchange');

# Extra currencies are to cover WLDUSD components
foreach my $needed_currency (qw(USD GBP JPY AUD EUR)) {
    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('currency', {symbol => $needed_currency});
}

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $now,
    });

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxGBPUSD',
        recorded_date => $now,
    });

my @ticks = map { {epoch => $now->epoch + $_, quote => 100} } (1 .. 20);
my $mocked = Test::MockModule->new('BOM::Product::Pricing::Engine::TickExpiry');
$mocked->mock('_latest_ticks', sub { \@ticks });
subtest 'tick expiry fx CALL' => sub {
    my $c = produce_contract({
        bet_type   => 'FLASHU',
        underlying => 'frxGBPUSD',
        date_start => $now,
        duration   => '5t',
        currency   => 'USD',
        payout     => 10,
        barrier    => 'S0P',
    });
    is $c->pricing_engine->risk_markup->amount,       -0.1,  'tie adjustment floored at -0.1';
    is $c->pricing_engine->probability->amount,       0.5,   'theo prob floored at 0.5 for CALL';
    is $c->pricing_engine->commission_markup->amount, 0.025, 'commission is 2.5%';
};

subtest 'tick expiry fx PUT' => sub {
    my $c = produce_contract({
        bet_type   => 'FLASHD',
        underlying => 'frxGBPUSD',
        date_start => $now,
        duration   => '5t',
        currency   => 'USD',
        payout     => 10,
        barrier    => 'S0P',
    });
    is $c->pricing_engine->risk_markup->amount,       -0.1,  'tie adjustment floored at -0.1';
    is $c->pricing_engine->probability->amount,       0.5,   'theo prob floored at 0.5 for PUT';
    is $c->pricing_engine->commission_markup->amount, 0.025, 'commission is 2.5%';
};

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_flat',
    {
        symbol        => 'WLDUSD',
        recorded_date => Date::Utility->new,
    });

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('index', {symbol => 'WLDUSD'});

@ticks = map { {epoch => $now->epoch + $_, quote => 100 + rand(10)} } (1 .. 20);
$mocked->mock('_latest_ticks', sub { \@ticks });

my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'WLDUSD',
        epoch      => '2014-12-24 00:00:00',
    },
);

subtest 'tick expiry smart fx' => sub {
    my $c = produce_contract({
        bet_type   => 'FLASHU',
        underlying => 'WLDUSD',
        date_start => $now,
        duration   => '5t',
        currency   => 'USD',
        payout     => 10,
        barrier    => 'S0P',
    });
    cmp_ok $c->pricing_engine->risk_markup->amount, ">",  -0.1, 'tie adjustment floored at -0.1';
    cmp_ok $c->pricing_engine->probability->amount, ">=", 0.5,  'theo prob floored at 0.5';
    is $c->pricing_engine->commission_markup->amount, 0.02, 'commission is 2%';
};

sub get_contract {
    return produce_contract({
        bet_type   => 'FLASHU',
        underlying => 'WLDUSD',
        date_start => $now,
        duration   => '5t',
        currency   => 'USD',
        payout     => 10,
        barrier    => 'S0P',
    });
}

sub mock_value {
    my ($name, $base_value) = @_;

    $mocked->mock(
        $name,
        sub {
            my $self = shift;
            Math::Util::CalculatedValue::Validatable->new({
                name        => $name,
                description => 'mocked value for $name',
                set_by      => __PACKAGE__,
                base_amount => $base_value,
            });
        });

}
subtest 'tick expiry markup adjustment' => sub {

    $mocked->unmock_all();
    my @ticks = map { {epoch => $now->epoch + $_, quote => 100 + ($_ / 1000)} } (1 .. 20);
    $mocked->mock('_latest_ticks', sub { \@ticks });
    my $coef = YAML::CacheLoader::LoadFile('/home/git/regentmarkets/bom/config/files/tick_trade_coefficients.yml')->{'WLDUSD'};

    mock_value 'vol_proxy', $coef->{y_max} + 0.00001;
    my $c             = get_contract;
    my $c_risk_markup = $c->pricing_engine->risk_markup->amount;
    $mocked->unmock('vol_proxy');
    my $c2 = get_contract;
    is $c_risk_markup - $c2->pricing_engine->risk_markup->amount, 0.0325284449939016, 'risk markup adjustment applied correctly';

    mock_value 'vol_proxy', 0.0000001;
    my $c3             = get_contract;
    my $c3_risk_markup = $c3->pricing_engine->risk_markup->amount;
    $mocked->unmock('vol_proxy');
    my $c4 = get_contract;
    is $c3_risk_markup - $c4->pricing_engine->risk_markup->amount, 0.0138547785256561, 'risk markup adjustment applied correctly';

    mock_value 'trend_proxy', 4.0;
    my $c5             = get_contract;
    my $c5_risk_markup = $c5->pricing_engine->risk_markup->amount;
    $mocked->unmock('trend_proxy');
    my $c6 = get_contract;
    is $c5_risk_markup - $c6->pricing_engine->risk_markup->amount, 0.0309575476863407, 'risk markup adjustment applied correctly';

    mock_value 'trend_proxy', -4.0;
    my $c7             = get_contract;
    my $c7_risk_markup = $c7->pricing_engine->risk_markup->amount;
    $mocked->unmock('trend_proxy');
    my $c8 = get_contract;
    is $c7_risk_markup - $c8->pricing_engine->risk_markup->amount, 0.0309575476863407, 'risk markup adjustment applied correctly';
    }
