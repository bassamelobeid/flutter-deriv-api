#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::FailWarnings;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

use BOM::Product::ContractFactory qw(produce_contract);
use Date::Utility;
use Test::MockModule;

my $now = Date::Utility->new;

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => 'USD',
        recorded_date => $now
    });

my $mocked = Test::MockModule->new('BOM::Product::Contract::Multup');
# setting commission to zero for easy calculation
$mocked->mock('commission',        sub { return 0 });
$mocked->mock('commission_amount', sub { return 0 });

subtest 'hit stop out' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100'], [90.01, $now->epoch + 1, 'R_100']);
    my $args = {
        bet_type     => 'MULTUP',
        underlying   => 'R_100',
        date_start   => $now,
        date_pricing => $now->epoch + 1,
        amount_type  => 'stake',
        amount       => 100,
        multiplier   => 10,
        currency     => 'USD',
        limit_order  => {
            stop_out => {
                order_type   => 'stop_out',
                order_amount => -100,
                order_date   => $now->epoch,
                basis_spot   => '100.00',
            }}};
    my $c = produce_contract($args);
    ok !$c->is_expired, 'not expired';
    ok !$c->hit_tick,   'no hit tick';

    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100'], [90, $now->epoch + 1, 'R_100']);
    $c = produce_contract($args);
    ok $c->is_expired, 'expired';
    ok $c->hit_tick,   'has hit tick';
    is $c->value,      '0.00', 'value of contract is zero';
    is $c->current_pnl(), '-100.00', 'pnl at -100';

    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100'], [89, $now->epoch + 1, 'R_100']);
    $c = produce_contract($args);
    ok $c->is_expired, 'expired';
    ok $c->hit_tick,   'has hit tick';
    is $c->value,      '0.00', 'value of contract is zero and does not go negative';
    is $c->current_pnl(), '-110.00', 'pnl at -110';

    note('stop out with 0.01 commission');
    $mocked->mock('commission', sub { return 0.01 });
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100'], [91.01, $now->epoch + 1, 'R_100']);
    $c = produce_contract($args);
    ok !$c->is_expired, 'not expired';

    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100'], [91, $now->epoch + 1, 'R_100']);
    $c = produce_contract($args);
    ok $c->is_expired, 'expired';
    ok $c->hit_tick,   'has hit tick';
    is $c->hit_tick->quote, 91, 'hit tick is 91';
    is $c->value, '0.00', 'value of contract is zero';
    is $c->current_pnl(), '-100.00', 'pnl at -100';
};

subtest 'hit take profit' => sub {
    $mocked->mock('commission', sub { return 0 });
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100'], [100.99, $now->epoch + 1, 'R_100']);
    my $args = {
        bet_type     => 'MULTUP',
        underlying   => 'R_100',
        date_start   => $now,
        date_pricing => $now->epoch + 1,
        amount_type  => 'stake',
        amount       => 100,
        multiplier   => 10,
        currency     => 'USD',
        limit_order  => {
            stop_out => {
                order_type   => 'stop_out',
                order_amount => -100,
                order_date   => $now->epoch,
                basis_spot   => '100.00',
            },
            take_profit => {
                order_type   => 'take_profit',
                order_amount => 10,
                order_date   => $now->epoch,
                basis_spot   => '100.00',
            }
        },
    };
    my $c = produce_contract($args);
    ok !$c->is_expired, 'not expired';
    ok !$c->hit_tick,   'no hit tick';

    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100'], [101, $now->epoch + 1, 'R_100']);
    $c = produce_contract($args);
    ok $c->is_expired, 'expired';
    ok $c->hit_tick,   'has hit tick';
    is $c->value,      '110.00', 'value of contract is 110';
    is $c->current_pnl(), '10.00', 'pnl at 10';

    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100'], [101.01, $now->epoch + 1, 'R_100']);
    $c = produce_contract($args);
    ok $c->is_expired, 'expired';
    ok $c->hit_tick,   'has hit tick';
    is $c->value,      '110.10', 'value of contract is 110.1';
    is $c->current_pnl(), '10.10', 'pnl at 10.1';

    note('take profit with 0.01 commission');
    $mocked->mock('commission', sub { return 0.01 });
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100'], [101.99, $now->epoch + 1, 'R_100']);
    $c = produce_contract($args);
    ok !$c->is_expired, 'not expired';

    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100'], [102, $now->epoch + 1, 'R_100']);
    $c = produce_contract($args);
    ok $c->is_expired, 'expired';
    ok $c->hit_tick,   'has hit tick';
    is $c->hit_tick->quote, 102, 'hit tick is 102';
    is $c->value, '110.00', 'value of contract is zero and does not go negative';
    is $c->current_pnl(), '10.00', 'pnl at 10';
};

subtest 'hit stop loss' => sub {
    $mocked->mock('commission', sub { return 0 });
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100'], [90.51, $now->epoch + 1, 'R_100']);
    my $args = {
        bet_type     => 'MULTUP',
        underlying   => 'R_100',
        date_start   => $now,
        date_pricing => $now->epoch + 1,
        amount_type  => 'stake',
        amount       => 100,
        multiplier   => 10,
        currency     => 'USD',
        limit_order  => {
            stop_out => {
                order_type   => 'stop_out',
                order_amount => -100,
                order_date   => $now->epoch,
                basis_spot   => '100.00',
            },
            stop_loss => {
                order_type   => 'stop_loss',
                order_amount => -95,
                order_date   => $now->epoch,
                basis_spot   => '100.00',
            }}};
    my $c = produce_contract($args);
    ok !$c->is_expired, 'not expired';
    ok !$c->hit_tick,   'no hit tick';

    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100'], [90.50, $now->epoch + 1, 'R_100']);
    $c = produce_contract($args);
    ok $c->is_expired, 'expired';
    ok $c->hit_tick,   'has hit tick';
    is $c->hit_tick->quote, 90.50, 'hit tick is 90.50';
    is $c->value, '5.00', 'value of contract is 5.00';
    is $c->current_pnl(), '-95.00', 'pnl at -95.00';

    note('stop out with 0.01 commission');
    $mocked->mock('commission', sub { return 0.01 });
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100'], [91.51, $now->epoch + 1, 'R_100']);
    $c = produce_contract($args);
    ok !$c->is_expired, 'not expired';

    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100'], [91.49, $now->epoch + 1, 'R_100']);
    $c = produce_contract($args);
    ok $c->is_expired, 'expired';
    ok $c->hit_tick,   'has hit tick';
    is $c->hit_tick->quote, 91.49, 'hit tick is 91.49';
    is $c->value, '4.90', 'value of contract is 4.90';
    is $c->current_pnl(), '-95.10', 'pnl at -95.10';
};

$mocked->mock('commission', sub { return 0 });

subtest 'sell late' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
        [100, $now->epoch,     'R_100'],
        [101, $now->epoch + 1, 'R_100'],
        [90,  $now->epoch + 2, 'R_100']);
    my $args = {
        bet_type     => 'MULTUP',
        underlying   => 'R_100',
        date_start   => $now,
        date_pricing => $now->epoch + 2,
        amount_type  => 'stake',
        amount       => 100,
        multiplier   => 10,
        currency     => 'USD',
        sell_time    => $now->epoch + 2,
        limit_order  => {
            stop_out => {
                order_type   => 'stop_out',
                order_amount => -100,
                order_date   => $now->epoch,
                basis_spot   => '100.00',
            },
            take_profit => {
                order_type   => 'take_profit',
                order_amount => 10,
                order_date   => $now->epoch,
                basis_spot   => '100.00',
            }
        },
    };
    my $c = produce_contract($args);
    ok $c->is_expired, 'expired';
    ok $c->hit_tick,   'has hit tick';
    is $c->hit_tick->quote, 101, 'hit tick is 101';
    is $c->value, '110.00', 'value is 110';
    is $c->current_pnl(), '10.00', 'pnl at 10';
};

subtest 'is valid to buy/sell' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100']);
    my $args = {
        bet_type     => 'MULTUP',
        underlying   => 'R_100',
        date_start   => $now,
        date_pricing => $now,
        amount_type  => 'stake',
        amount       => 100,
        multiplier   => 10,
        currency     => 'USD',
    };
    my $c = produce_contract($args);
    ok $c->is_valid_to_buy, 'valid to buy';

    $args->{limit_order} = {take_profit => -1};
    $c = produce_contract($args);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    is $c->primary_validation_error->message, 'take profit too low', 'take profit too low';
    is $c->primary_validation_error->message_to_client->[0], 'Please enter a take profit amount that\'s higher than [_1].';
    is $c->primary_validation_error->message_to_client->[1], '0.10';

    $args->{limit_order} = {take_profit => 0};
    $c = produce_contract($args);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    is $c->primary_validation_error->message, 'take profit too low', 'take profit too low';
    is $c->primary_validation_error->message_to_client->[0], 'Please enter a take profit amount that\'s higher than [_1].';
    is $c->primary_validation_error->message_to_client->[1], '0.10';

    $args->{limit_order} = {stop_loss => -1};
    $c = produce_contract($args);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    is $c->primary_validation_error->message, 'stop loss too low', 'stop loss too low';
    is $c->primary_validation_error->message_to_client->[0], 'Please enter a stop loss amount that\'s higher than [_1].';
    is $c->primary_validation_error->message_to_client->[1], '0.10';

    $args->{limit_order} = {stop_loss => 0};
    $c = produce_contract($args);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    is $c->primary_validation_error->message, 'stop loss too low', 'stop loss too low';
    is $c->primary_validation_error->message_to_client->[0], 'Please enter a stop loss amount that\'s higher than [_1].';
    is $c->primary_validation_error->message_to_client->[1], '0.10';
};

subtest 'bid price after expiry' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
        [100,   $now->epoch,     'R_100'],
        [101,   $now->epoch + 1, 'R_100'],
        [100.9, $now->epoch + 2, 'R_100']);
    my $args = {
        bet_type     => 'MULTUP',
        underlying   => 'R_100',
        date_start   => $now,
        date_pricing => $now->epoch + 2,
        amount_type  => 'stake',
        amount       => 100,
        multiplier   => 10,
        currency     => 'USD',
        limit_order  => {
            stop_out => {
                order_type   => 'stop_out',
                order_amount => -100,
                order_date   => $now->epoch,
                basis_spot   => '100.00',
            },
            take_profit => {
                order_type   => 'take_profit',
                order_amount => 10,
                order_date   => $now->epoch,
                basis_spot   => '100.00',
            }
        },
    };
    my $c = produce_contract($args);
    ok $c->is_expired, 'expired';
    ok $c->hit_tick,   'has hit tick';
    is $c->value,      '110.00', 'value of contract is 110';
    ok $c->bid_price == $c->value, 'bid price == value after expiry';
};

subtest 'stop loss less than commission' => sub {
    $mocked->unmock_all;
    $mocked->mock('commission', sub { return 0.0005 });
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100'], [90, $now->epoch + 1, 'R_100']);
    my $args = {
        date_start   => $now,
        date_pricing => $now,
        bet_type     => 'MULTUP',
        underlying   => 'R_100',
        amount_type  => 'stake',
        amount       => 100,
        multiplier   => 10,
        currency     => 'USD',
        limit_order  => {stop_loss => 0.4},
    };

    my $c = produce_contract($args);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    is $c->primary_validation_error->message, 'stop loss lower than pnl', 'stop loss lower than pnl';
    is $c->primary_validation_error->message_to_client->[0], 'Invalid stop loss. Stop loss must be higher than commission ([_1]).';
    is $c->primary_validation_error->message_to_client->[1], '0.50';
};

subtest 'deal cancellation active hit stop out' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100'], [90, $now->epoch + 1, 'R_100']);
    my $args = {
        date_start   => $now,
        date_pricing => $now->epoch + 1,
        bet_type     => 'MULTUP',
        underlying   => 'R_100',
        amount_type  => 'stake',
        amount       => 100,
        multiplier   => 10,
        currency     => 'USD',
        limit_order  => {
            stop_out => {
                order_type   => 'stop_out',
                order_amount => -100,
                order_date   => $now->epoch,
                basis_spot   => '100.00',
            },
        },
        cancellation => '1h',
    };

    my $c = produce_contract($args);
    ok $c->is_expired,       'contract expired';
    ok $c->hit_tick,         'has hit tick';
    ok $c->is_valid_to_sell, 'valid to sell';
    is $c->hit_tick->quote, 90, 'hit tick quote 90';
    is $c->value, '100.00', 'value of contract is 100.00';
    is $c->bid_price + 0, $c->cancel_price, 'bid price of contract equals to cancel price';

    $args->{is_sold}   = 1;
    $args->{sell_time} = $args->{date_pricing};
    $c                 = produce_contract($args);
    ok $c->is_expired,   'contract expired';
    ok $c->is_cancelled, 'contract cancelled';
    is $c->value,        '100.00', 'value of contract is 100.00';
    is $c->bid_price + 0, $c->cancel_price, 'bid price of contract equals to cancel price';

    # status still unchanged as date pricing moved passed cancellation expiry
    $args->{date_pricing} = $now->epoch + 3601;
    $c = produce_contract($args);
    ok $c->is_expired,   'contract expired';
    ok $c->is_cancelled, 'contract cancelled';
    is $c->value,        '100.00', 'value of contract is 100.00';
    is $c->bid_price + 0, $c->cancel_price, 'bid price of contract equals to cancel price';
};

subtest 'deal cancellation active manual cancellation' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100']);
    my $args = {
        date_start   => $now,
        date_pricing => $now->epoch + 1,
        bet_type     => 'MULTUP',
        underlying   => 'R_100',
        amount_type  => 'stake',
        amount       => 100,
        multiplier   => 10,
        currency     => 'USD',
        limit_order  => {
            stop_out => {
                order_type   => 'stop_out',
                order_amount => -100,
                order_date   => $now->epoch,
                basis_spot   => '100.00',
            },
        },
        cancellation => '1h',
        sell_time    => $now->epoch + 1,
        sell_price   => 100,
        is_sold      => 1,
    };

    my $c = produce_contract($args);
    ok !$c->is_expired, 'not expired';
    ok !$c->hit_tick,   'no hit tick';
    ok $c->is_cancelled, 'is_cancelled is true';

    $args->{sell_price} = 99;
    $c = produce_contract($args);
    ok !$c->is_expired,   'not expired';
    ok !$c->hit_tick,     'no hit tick';
    ok !$c->is_cancelled, 'is_cancelled is false';

    $args->{sell_price} = 100;
    $args->{sell_time}  = $now->plus_time_interval('1h1s');
    $c                  = produce_contract($args);
    ok !$c->is_expired,   'not expired';
    ok !$c->hit_tick,     'no hit tick';
    ok !$c->is_cancelled, 'is_cancelled is false';
};

subtest 'deal cancellation with stop loss' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100'], [90, $now->epoch + 1, 'R_100']);
    my $args = {
        date_start   => $now,
        date_pricing => $now,
        bet_type     => 'MULTUP',
        underlying   => 'R_100',
        amount_type  => 'stake',
        amount       => 100,
        multiplier   => 10,
        currency     => 'USD',
        limit_order  => {
            stop_loss => 1,
        },
        cancellation => '1h',
    };

    my $c = produce_contract($args);
    ok !$c->is_valid_to_buy, 'invalid to buy';
    is $c->primary_validation_error->message_to_client, 'You may use either stop loss or deal cancellation, but not both. Please select either one.',
        'correct message to client';
};

subtest 'past date expiry' => sub {
    my $now     = Date::Utility->new;
    my $pricing = $now->truncate_to_day->plus_time_interval('7d23h59m59s');
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
        [100,    $now->epoch,         'cryBTCUSD'],
        [100.01, $now->epoch + 1,     'cryBTCUSD'],
        [101,    $pricing->epoch - 1, 'cryBTCUSD']);
    my $args = {
        date_start   => $now,
        date_pricing => $pricing->epoch + 1,
        bet_type     => 'MULTUP',
        underlying   => 'cryBTCUSD',
        amount_type  => 'stake',
        amount       => 100,
        multiplier   => 10,
        currency     => 'USD',
        limit_order  => {
            stop_out => {
                order_type   => 'stop_out',
                order_amount => -100,
                order_date   => $now->epoch,
                basis_spot   => '100.00',
            }
        },
    };

    my $c = produce_contract($args);
    ok !$c->is_expired, 'is not expired because of no exit tick';

    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
        [100,    $now->epoch,         'cryBTCUSD'],
        [100.01, $now->epoch + 1,     'cryBTCUSD'],
        [101,    $pricing->epoch - 1, 'cryBTCUSD'],
        [102,    $pricing->epoch + 1, 'cryBTCUSD']);
    $c = produce_contract($args);
    ok !$c->hit_tick, 'not hit tick';
    ok $c->is_expired, 'is expired';
    is $c->exit_tick->epoch, $c->close_tick->epoch, 'exit tick == close tick';
    is $c->value + 0, $c->bid_price + 0, 'value == bid price';
};

done_testing();
