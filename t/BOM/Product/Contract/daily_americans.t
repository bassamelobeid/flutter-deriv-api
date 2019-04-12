#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::Most tests => 3;
use Test::Exception;
use Test::Warnings;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use Postgres::FeedDB;
use Date::Utility;
use BOM::Product::ContractFactory qw(produce_contract);

initialize_realtime_ticks_db();
my $ul   = create_underlying('FCHI');
my $when = Date::Utility->new('2015-11-08 16:00:00');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => 'USD',
        date   => Date::Utility->new
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_moneyness',
    {
        symbol        => $ul->symbol,
        recorded_date => $when,
    });

my $entry_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => $ul->symbol,
    epoch      => $when->epoch + 1,
    quote      => 10000,
});
BOM::Test::Data::Utility::FeedTestDatabase::create_ohlc_daily({
    underlying => 'FCHI',
    epoch      => $when->truncate_to_day->plus_time_interval('1d')->epoch,
    open       => 10000,
    high       => 12000,
    low        => 10000,
    close      => 10000,
    official   => 1,
});

BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => $ul->symbol,
    epoch      => $when->plus_time_interval('2d')->epoch + 1,
    quote      => 14000,
});
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => $ul->symbol,
    epoch      => $when->plus_time_interval('2d')->epoch + 3600,
    quote      => 13000,
});

BOM::Test::Data::Utility::FeedTestDatabase::create_ohlc_daily({
    underlying => 'FCHI',
    epoch      => $when->truncate_to_day->plus_time_interval('2d')->epoch,
    open       => 10000,
    high       => 15000,
    low        => 10000,
    close      => 10000,
    official   => 1,
});

# OHLC with hit data
my $args = {
    bet_type        => 'ONETOUCH',
    underlying      => $ul,
    date_start      => $when,
    date_expiry     => $ul->calendar->closing_on($ul->exchange, Date::Utility->new('2015-11-09')),
    date_settlement => $ul->calendar->get_exchange_open_times($ul->exchange, Date::Utility->new('2015-11-09'), 'daily_settlement'),
    entry_tick      => $entry_tick,
    currency        => 'USD',
    payout          => 10,
    barrier         => 11000,
};
subtest 'resolve onetouch correctly with no ticks, but OHLC' => sub {
    my $c = produce_contract($args);
    cmp_ok $c->entry_tick->quote,    '==', 10000, 'correct entry tick';
    cmp_ok $c->barrier->as_absolute, '==', 11000, 'correct barrier';
    ok $c->is_expired, 'contract is expired';
    cmp_ok $c->value, '==', $c->payout, 'hit via OHLC - full payout';
};

subtest 'get_high_low_for_contract_period' => sub {

    $args->{barrier}         = '14500';
    $args->{date_expiry}     = $ul->calendar->closing_on($ul->exchange, Date::Utility->new('2015-11-10'));
    $args->{date_settlement} = $ul->calendar->get_exchange_open_times($ul->exchange, Date::Utility->new('2015-11-10'), 'daily_settlement');

    my $c = produce_contract($args);
    my ($high, $low) = @{$c->_ohlc_for_contract_period}{'high','low'};

    cmp_ok $high, '==', 15000, 'correct high low';
    cmp_ok $low,  '==', 10000, 'correct high low';

    ok $c->is_expired, 'contract is expired';
    cmp_ok $c->value, '==', $c->payout, 'hit via OHLC - full payout';

    my $p = $c->build_parameters;
    $p->{date_pricing} = Date::Utility->new('2015-11-10 16:30:00');
    my $c1 = produce_contract($p);

    ($high, $low) = @{$c1->_ohlc_for_contract_period}{'high','low'};

    cmp_ok $high, '==', 14000, 'correct high low';
    cmp_ok $low,  '==', 10000, 'correct high low';

};

1;
