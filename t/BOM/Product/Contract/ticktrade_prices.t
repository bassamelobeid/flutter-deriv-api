#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 12;

use BOM::Product::ContractFactory qw(produce_contract);
use Format::Util::Numbers qw(roundnear);

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
initialize_realtime_ticks_db();

my $now = Date::Utility->new('2014-11-11');

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => 'USD',
        recorded_date => $now,
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'index',
    {
        symbol        => 'R_100',
        recorded_date => $now,
        rates         => {365 => 0},
    });
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'R_100',
    epoch      => $now->epoch,
    quote      => 1000
});

my $params = {
    underlying => 'R_100',
    duration   => '5t',
    currency   => 'USD',
    payout     => 100,
    barrier    => 'S0P',
};

my $c = produce_contract({
    %$params,
    date_start   => $now,
    date_pricing => $now,
    bet_type     => 'FLASHU'
});
is $c->pricing_engine_name, 'Pricing::Engine::EuropeanDigitalSlope', 'correct pricing engine';
is roundnear(0.0001, $c->bs_probability->amount), 0.4999, 'bs probability is 0.4999';
is $c->commission_markup->amount, 0.015, 'total markup is 0.015';

$c = produce_contract({
    %$params,
    date_start   => $now,
    date_pricing => $now,
    bet_type     => 'FLASHD',
});
is $c->pricing_engine_name, 'Pricing::Engine::EuropeanDigitalSlope', 'correct pricing engine';
is roundnear(0.0001, $c->bs_probability->amount), 0.5001, 'bs probability is 0.5001';
is $c->commission_markup->amount, 0.015, 'total markup is 0.015';

delete $params->{barrier};

$c = produce_contract({
    %$params,
    date_start   => $now,
    date_pricing => $now,
    bet_type     => 'ASIANU',
});
is $c->pricing_engine_name, 'Pricing::Engine::Asian', 'correct pricing engine';
is roundnear(0.0001, $c->bs_probability->amount), 0.4999, 'correct bs probability';
is $c->commission_markup->amount, 0.015, 'correct total markup';

$c = produce_contract({
    %$params,
    date_start   => $now,
    date_pricing => $now,
    bet_type     => 'ASIAND',
});
is $c->pricing_engine_name, 'Pricing::Engine::Asian', 'correct pricing engine';
is roundnear(0.0001, $c->bs_probability->amount), 0.5001, 'correct bs probability';
is $c->commission_markup->amount, 0.015, 'correct total markup';
