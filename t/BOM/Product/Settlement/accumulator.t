#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::Fatal;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase   qw(:init);
use BOM::Config::Runtime;

use BOM::Product::ContractFactory qw(produce_contract);
use Finance::Contract::Longcode   qw(shortcode_to_parameters);
use Date::Utility;

my $now    = Date::Utility->new;
my $symbol = 'R_100';

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => 'USD',
        recorded_date => $now
    });

my $args = {
    bet_type          => 'ACCU',
    underlying        => $symbol,
    date_start        => $now,
    amount_type       => 'stake',
    amount            => 100,
    growth_rate       => 0.01,
    currency          => 'USD',
    growth_frequency  => 1,
    growth_start_step => 1,
    tick_size_barrier => 0.02,
};

subtest 'hit barrier' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
        [100, $now->epoch,     $symbol],
        [100, $now->epoch + 1, $symbol],
        [100, $now->epoch + 2, $symbol]);

    my $c = produce_contract($args);
    ok !$c->is_expired, 'not expired';
    ok !$c->hit_tick,   'no hit tick';

    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
        [100, $now->epoch,     $symbol],
        [100, $now->epoch + 1, $symbol],
        [98,  $now->epoch + 2, $symbol]);

    $c = produce_contract($args);
    ok $c->is_expired, 'has expired';
    ok $c->hit_tick,   'has hit_tick';
    is $c->hit_tick->epoch, $now->epoch + 2,       'currect hit tick';
    is $c->hit_tick->epoch, $c->close_tick->epoch, 'hit tick == close tick';
    is $c->value,           '0',                   'correct value';
    is $c->pnl,             '-100.00',             'correct pnl';
    ok $c->is_valid_to_sell, 'valid to sell';
    is $c->entry_tick->epoch,      $now->epoch + 1, 'currect entry_tick';
    is $c->tick_count_after_entry, 1,               'no ticks after entry_tick';
    is scalar @{$c->tick_stream},  2,               'two ticks available from enty tick';
};

subtest 'hit take profit' => sub {
    $args->{limit_order} = {
        take_profit => {
            order_amount => 2,
            order_date   => $now->epoch,
        }};
    $args->{date_pricing} = $now->plus_time_interval('4s');

    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
        [100, $now->epoch,     $symbol],
        [100, $now->epoch + 1, $symbol],
        [100, $now->epoch + 2, $symbol],
        [100, $now->epoch + 3, $symbol],
    );

    my $c = produce_contract($args);
    ok !$c->is_expired, 'not expired';

    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
        [100, $now->epoch,     $symbol],
        [100, $now->epoch + 1, $symbol],
        [100, $now->epoch + 2, $symbol],
        [100, $now->epoch + 3, $symbol],
        [100, $now->epoch + 4, $symbol],
    );

    $c = produce_contract($args);
    ok $c->is_expired, 'has expired';
    is $c->value, '102.01', 'correct value';
    is $c->pnl,   '2.01',   'correct pnl';
    ok $c->is_valid_to_sell, 'valid to sell';

    delete $args->{date_pricing};
    delete $args->{limit_order};
};

subtest 'hit take profit and barrier at the same time' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
        [100, $now->epoch,     $symbol],
        [100, $now->epoch + 1, $symbol],
        [100, $now->epoch + 2, $symbol],
        [100, $now->epoch + 3, $symbol],
        [95,  $now->epoch + 4, $symbol]);

    $args->{limit_order} = {
        take_profit => {
            order_amount => 2,
            order_date   => $now->epoch,
        }};
    $args->{date_pricing} = $now->plus_time_interval('4s');

    my $c = produce_contract($args);
    ok $c->is_expired, 'has expired';
    ok $c->hit_tick,   'has hit_tick';
    ok $c->exit_tick,  'has exit_tick';
    is $c->hit_tick->epoch, $c->close_tick->epoch, 'exit tick == close tick';
    is $c->hit_tick->epoch, $now->epoch + 4,       'correct hit tick';
    is $c->value,           '0',                   'correct value';
    is $c->pnl,             '-100.00',             'correct pnl';
    delete $args->{limit_order};
};

subtest 'hit tick expiry' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
        [100,  $now->epoch,     $symbol],
        [99,   $now->epoch + 1, $symbol],
        [97.1, $now->epoch + 2, $symbol],
        [99,   $now->epoch + 3, $symbol],
        [100,  $now->epoch + 4, $symbol]);

    $args->{duration}     = '3t';
    $args->{date_pricing} = $now->plus_time_interval('4s');
    my $c = produce_contract($args);
    ok $c->is_expired, 'has expired';
    ok $c->exit_tick,  'has exit_tick';
    ok !$c->hit_tick,  'no hit_tick';
    is $c->exit_tick->epoch, $c->close_tick->epoch, 'exit tick == close tick';
    is $c->value,            '102.01',              'correct value';
    is $c->pnl,              '2.01',                'correct pnl';
    ok $c->is_valid_to_sell, 'valid to sell';
    is $c->entry_tick->epoch,      $now->epoch + 1, 'currect entry_tick';
    is $c->tick_count_after_entry, 3,               '3 ticks after entry_tick';
    is scalar @{$c->tick_stream},  4,               'one tick available from enty tick';
};

subtest 'hit tick expiry and barrier at the same time' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
        [100, $now->epoch,     $symbol],
        [100, $now->epoch + 1, $symbol],
        [100, $now->epoch + 2, $symbol],
        [100, $now->epoch + 3, $symbol],
        [95,  $now->epoch + 4, $symbol]);

    $args->{duration}     = '3t';
    $args->{date_pricing} = $now->plus_time_interval('4s');

    my $c = produce_contract($args);
    ok $c->is_expired, 'has expired';
    ok $c->exit_tick,  'has exit_tick';
    is $c->value, '0',       'correct value';
    is $c->pnl,   '-100.00', 'correct pnl';
    ok $c->is_valid_to_sell, 'valid to sell';

    delete $args->{limit_order};
    delete $args->{duration};
};

subtest 'close tick' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
        [100,   $now->epoch,     $symbol],
        [100.1, $now->epoch + 1, $symbol],
        [100.2, $now->epoch + 2, $symbol],
        [100.3, $now->epoch + 3, $symbol],
        [100.4, $now->epoch + 4, $symbol]);

    $args->{date_pricing} = $now->plus_time_interval('4s');
    $args->{is_sold}      = 1;
    $args->{sell_time}    = $now->epoch + 3;

    subtest 'sell at sell_time tick' => sub {
        $args->{sell_price} = 101.00;
        my $c = produce_contract($args);
        ok !$c->exit_tick,        'no exit_tick';
        ok !$c->is_valid_to_sell, 'is not valid to sell';
        is $c->close_tick->quote,      '100.3', 'correct close tick';
        is $c->tick_count_after_entry, 2,       'correct number of ticks after entry tick';
    };
    subtest 'sell at previous tick' => sub {
        $args->{sell_price} = 100.00;
        my $c = produce_contract($args);
        ok !$c->exit_tick,        'no exit_tick';
        ok !$c->is_valid_to_sell, 'is not valid to sell';
        is $c->close_tick->quote,      '100.2', 'correct close tick';
        is $c->tick_count_after_entry, 1,       'correct number of ticks after entry tick';
    };

    delete $args->{date_pricing};
    delete $args->{is_sold};
    delete $args->{sell_time};
};

done_testing();
