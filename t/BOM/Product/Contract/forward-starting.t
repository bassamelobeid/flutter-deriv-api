#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Warnings;
use Test::Exception;
use Test::MockTime qw(set_absolute_time);
use Time::HiRes qw(sleep);

use BOM::Product::ContractFactory qw(produce_contract make_similar_contract);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

use Date::Utility;

my $now = Date::Utility->new;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'index',
    {
        symbol        => 'RDBULL',
        recorded_date => $now->minus_time_interval('5m'),
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $now->minus_time_interval('5m'),
    }) for qw(USD JPY JPY-USD);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $now->minus_time_interval('5m'),
    });

subtest 'forward starting with payout/stake' => sub {
    my $c = produce_contract({
        bet_type     => 'CALL',
        underlying   => 'frxUSDJPY',
        duration     => '10m',
        barrier      => 'S0P',
        currency     => 'USD',
        amount_type  => 'payout',
        amount       => 10,
        date_pricing => $now->epoch - 300,
        date_start   => $now
    });
    ok $c->is_forward_starting;
    is $c->payout, 10, 'payout of 10';
};

subtest 'forward starting with stake' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            epoch      => $_,
            underlying => 'frxUSDJPY',
            quote      => 100
        }) for ($now->epoch - 300, $now->epoch + 299);
    my $c = produce_contract({
        bet_type     => 'CALL',
        underlying   => 'frxUSDJPY',
        duration     => '10m',
        barrier      => 'S0P',
        currency     => 'USD',
        amount_type  => 'stake',
        amount       => 10,
        date_pricing => $now->epoch - 300,
        date_start   => $now
    });
    ok $c->is_forward_starting;
    cmp_ok $c->payout, ">", 10, 'payout is > 10';
};

subtest 'forward starting on random daily' => sub {
    $now = Date::Utility->new->truncate_to_day;
    my $c = produce_contract({
        bet_type     => 'CALL',
        underlying   => 'RDBULL',
        duration     => '10m',
        barrier      => 'S0P',
        currency     => 'USD',
        amount_type  => 'payout',
        amount       => 10,
        date_pricing => $now->epoch - 300,
        date_start   => $now
    });
    ok $c->is_forward_starting;
    ok $c->_validate_start_and_expiry_date;
    my @err = $c->_validate_start_and_expiry_date;
    is_deeply($err[0]->{message_to_client}, ['Trading is not available from [_1] to [_2].', '00:00:00', '00:01:00']);
    $c = produce_contract({
        bet_type     => 'CALL',
        underlying   => 'RDBULL',
        duration     => '10m',
        barrier      => 'S0P',
        currency     => 'USD',
        amount_type  => 'payout',
        amount       => 10,
        date_pricing => $now->epoch - 300,
        date_start   => $now->epoch + 301
    });
    ok !$c->_validate_start_and_expiry_date;
};

subtest 'end of day blockout period for random nightly and random daily' => sub {
    $now = Date::Utility->new->truncate_to_day->plus_time_interval('23h49m');
    my $c = produce_contract({
        bet_type     => 'CALL',
        underlying   => 'RDBULL',
        duration     => '10m',
        barrier      => 'S0P',
        currency     => 'USD',
        amount_type  => 'payout',
        amount       => 10,
        date_pricing => $now->epoch,
        date_start   => $now->epoch,
    });
    ok $c->_validate_start_and_expiry_date, 'throw error if contract ends in 1m before expiry';
    is_deeply(($c->_validate_start_and_expiry_date)[0]->{message_to_client},
        ['Contract may not expire between [_1] and [_2].', '23:59:00', '23:59:59']);
    my $valid_c = make_similar_contract($c, {duration => '9m59s'});
    ok !$valid_c->_validate_start_and_expiry_date;
};

subtest 'basis_tick for forward starting contract' => sub {
    # flush everything to make sure we start fresh
    Cache::RedisDB->flushall;
    BOM::Test::Data::Utility::FeedTestDatabase->instance->truncate_tables;
    # date_pricing is set to a specific time so that we can check conditions easier.
    my $date_pricing = Date::Utility->new('2016-08-15');
    my $date_start   = $date_pricing->plus_time_interval('15m');

    foreach my $data ([$date_pricing->epoch, 100], [$date_start->epoch, 101], [$date_start->epoch + 1, 102]) {
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            epoch      => $data->[0],
            underlying => 'frxUSDJPY',
            quote      => $data->[1],
        });
    }

    my $expected_shortcode = 'CALL_FRXUSDJPY_10.00_1471220100F_1471221000_S0P_0';
    my $args               = {
        bet_type     => 'CALL',
        underlying   => 'frxUSDJPY',
        date_start   => $date_start,
        date_pricing => $date_pricing,
        duration     => '15m',
        barrier      => 'S0P',
        currency     => 'USD',
        payout       => 10,
    };
    my $c = produce_contract($args);
    ok $c->pricing_new, 'is pricing new';
    is $c->_basis_tick->quote, 100, 'basis tick is current tick at date pricing';
    is $c->_basis_tick->epoch, $date_pricing->epoch, 'basis tick epoch is correct';
    is $c->shortcode, $expected_shortcode, 'shortcode is correct';

    $args->{date_pricing}               = $date_pricing->plus_time_interval('5m');
    $args->{starts_as_forward_starting} = 1;                                         #to simulate reprice of an existing forward starting contract
    $c                                  = produce_contract($args);
    ok $c->pricing_new, 'pricing new return before contract starts';
    is $c->_basis_tick->quote, 100, 'basis tick is current tick at date pricing';
    is $c->_basis_tick->epoch, $date_pricing->epoch, 'basis tick epoch is correct';

    $c = produce_contract($c->shortcode, 'USD');
    ok $c->starts_as_forward_starting, 'starts as forward starting';
    ok !$c->pricing_new, 'not pricing new';
    is $c->_basis_tick->quote, 101, 'basis tick is tick at start';
    is $c->_basis_tick->epoch, $date_start->epoch, 'correct epoch for tick';
    is $c->shortcode, $expected_shortcode, 'shortcode is correct';
};

subtest 'forward starting on Forex when previous day is a holiday' => sub {
    my $now = Date::Utility->new('2017-12-22');
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'holiday',
        {
            calendar => {
                Date::Utility->new('2017-12-25')->epoch => {
                    'chritmas' => ['FOREX'],
                }
            },
            recorded_date => $now->minus_time_interval('5m'),
        });
    my $c = produce_contract({
        bet_type     => 'CALL',
        underlying   => 'frxUSDJPY',
        date_pricing => $now,
        date_start   => Date::Utility->new('2017-12-26 00:00:00'),
        duration     => '1h',
        barrier      => 'S0P',
        currency     => 'USD',
        payout       => 10
    });

    my $err;
    ok $err = $c->_validate_start_and_expiry_date(), 'got an error';
    is $err->{message}, 'blackout period [symbol: frxUSDJPY] [from: 1514246400] [to: 1514247000]', 'correct error message';
};

done_testing();
