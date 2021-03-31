#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::Fatal;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Config::Runtime;

use BOM::Product::ContractFactory qw(produce_contract);
use Finance::Contract::Longcode qw(shortcode_to_parameters);
use Date::Utility;
use Test::MockModule;

use Test::Fatal;

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

subtest 'pricing new - general' => sub {
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
    is $c->code,            'MULTUP', 'code is MULTUP';
    is $c->pricing_code,    'MULTUP', 'pricing_code is MULTUP';
    is $c->other_side_code, undef,    'other_side_code is undef';
    ok !$c->pricing_engine,      'pricing_engine is undef';
    ok !$c->pricing_engine_name, 'pricing_engine_name is undef';
    is $c->multiplier, 10,  'multiplier is 10';
    is $c->ask_price,  100, 'ask_price is 100';
    ok !$c->take_profit, 'take_profit is undef';
    isa_ok $c->stop_out, 'BOM::Product::LimitOrder';
    is $c->stop_out->order_type, 'stop_out';
    is $c->stop_out->order_date->epoch, $c->date_pricing->epoch;
    is $c->stop_out->order_amount,  -100;
    is $c->stop_out->basis_spot,    '100.00';
    is $c->stop_out->barrier_value, '90.00';

    $args->{limit_order} = {
        'take_profit' => 50,
    };
    $c = produce_contract($args);
    isa_ok $c->take_profit, 'BOM::Product::LimitOrder';
    is $c->take_profit->order_type, 'take_profit';
    is $c->take_profit->order_date->epoch, $c->date_pricing->epoch;
    is $c->take_profit->order_amount,  50;
    is $c->take_profit->basis_spot,    '100.00';
    is $c->take_profit->barrier_value, '105.00';

    $args->{limit_order} = {
        'take_profit' => 0,
    };
    $c = produce_contract($args);
    ok !$c->is_valid_to_buy, 'invalid to buy';
    is $c->primary_validation_error->message, 'take profit too low', 'message - take profit too low';
    is $c->primary_validation_error->message_to_client->[0], 'Please enter a take profit amount that\'s higher than [_1].',
        'message - Please enter a take profit amount that\'s higher than [_1].';
    is $c->primary_validation_error->message_to_client->[1], '0.10';
};

subtest 'non-pricing new' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100']);
    my $args = {
        bet_type     => 'MULTUP',
        underlying   => 'R_100',
        date_start   => $now,
        date_pricing => $now->epoch + 1,
        amount_type  => 'stake',
        amount       => 100,
        multiplier   => 10,
        currency     => 'USD',
    };
    my $c = produce_contract($args);
    ok !$c->pricing_new, 'non pricing_new';
    my $error = exception {
        $c->stop_out
    };
    isa_ok $error, 'BOM::Product::Exception';
    is $error->message_to_client->[0], 'Cannot validate contract.', 'contract is invalid because stop_out is undef';

    $args->{limit_order} = {
        stop_out => {
            order_type   => 'stop_out',
            order_amount => -100,
            order_date   => $now->epoch,
            basis_spot   => '100.00',
        }};

    $c = produce_contract($args);
    is $c->stop_out->order_type, 'stop_out';
    is $c->stop_out->order_date->epoch, $c->date_start->epoch;
    is $c->stop_out->order_amount,  -100;
    is $c->stop_out->basis_spot,    '100.00';
    is $c->stop_out->barrier_value, '90.00';
};

subtest 'shortcode' => sub {
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
    is $c->shortcode, 'MULTUP_R_100_100.00_10_' . $now->epoch . '_' . $c->date_expiry->epoch . '_0_0.00', 'shortcode populated correctly';
    lives_ok { produce_contract(shortcode_to_parameters($c->shortcode, $c->currency)) } 'can produce contract properly';
    $args->{cancellation} = '1h';
    $c = produce_contract($args);
    is $c->shortcode, 'MULTUP_R_100_100.00_10_' . $now->epoch . '_' . $c->date_expiry->epoch . '_1h_0.00', 'shortcode populated correctly';
    lives_ok { produce_contract(shortcode_to_parameters($c->shortcode, $c->currency)) } 'can produce contract properly';
    $args->{limit_order} = {take_profit => 20};
    $c = produce_contract($args);
    is $c->shortcode, 'MULTUP_R_100_100.00_10_' . $now->epoch . '_' . $c->date_expiry->epoch . '_1h_20.00', 'shortcode populated correctly';
    lives_ok { produce_contract(shortcode_to_parameters($c->shortcode, $c->currency)) } 'can produce contract properly';
    $args->{limit_order} = {take_profit => 20.4};
    $c = produce_contract($args);
    is $c->shortcode, 'MULTUP_R_100_100.00_10_' . $now->epoch . '_' . $c->date_expiry->epoch . '_1h_20.40', 'shortcode populated correctly';
    lives_ok { produce_contract(shortcode_to_parameters($c->shortcode, $c->currency)) } 'can produce contract properly';
};

subtest 'shortcode to parameters' => sub {
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
        cancellation => '1h',
        limit_order  => {take_profit => 25.5},
    };
    my $c      = produce_contract($args);
    my $params = shortcode_to_parameters($c->shortcode, $c->currency);
    $params->{date_pricing} = $c->date_start->plus_time_interval('1h1s');
    $params->{limit_order}  = {
        stop_out => {
            order_type   => 'stop_out',
            order_amount => -100,
            order_date   => $now->epoch,
            basis_spot   => '100.00',
        },
        take_profit => {
            order_type   => 'take_profit',
            order_amount => 15,
            order_date   => $now->epoch + 100,
            basis_spot   => '100.00',
        },
    };
    my $c2 = produce_contract($params);
    is $c->cancellation_price, $c2->cancellation_price, 'same deal cancellation price';
    ok $c->take_profit->order_amount != $c2->take_profit->order_amount, 'take profit amount different';
};

subtest 'trying to pass in date_expiry or duration' => sub {
    my $args = {
        bet_type    => 'MULTUP',
        underlying  => 'R_100',
        amount_type => 'stake',
        amount      => 100,
        multiplier  => 10,
        currency    => 'USD',
    };
    my $error = exception { produce_contract({%$args, duration => '60s'}) };
    isa_ok $error, 'BOM::Product::Exception';
    is $error->message_to_client->[0], 'Invalid input (duration or date_expiry) for this contract type ([_1]).', 'throws exception with duration';

    $error = exception { produce_contract({%$args, date_expiry => $now->plus_time_interval(1)}) };
    isa_ok $error, 'BOM::Product::Exception';
    is $error->message_to_client->[0], 'Invalid input (duration or date_expiry) for this contract type ([_1]).', 'throws exception with duration';
};

subtest 'deal cancellation' => sub {
    my $args = {
        date_start   => $now,
        date_pricing => $now,
        bet_type     => 'MULTUP',
        underlying   => 'R_100',
        amount_type  => 'stake',
        amount       => 100,
        multiplier   => 10,
        currency     => 'USD',
        cancellation => '1h',
    };

    my $c = produce_contract($args);
    is $c->cancellation_price, 4.48, 'cost of cancellation is 4.48';
    is $c->cancellation_expiry->epoch, $now->plus_time_interval('1h')->epoch, 'cancellation expiry is correct';
    is $c->ask_price, 104.48, 'ask price is 104.48';
    ok !$c->is_cancelled, 'not cancelled';
    ok $c->is_valid_to_cancel, 'valid to cancel';

    delete $args->{cancellation};
    $c = produce_contract($args);
    is $c->cancellation_price, '0.00', 'zero cost of cancellation';
    ok !$c->cancellation_expiry, 'cancellation expiry is undef';
    is $c->ask_price, 100, 'ask price is 100 as per user input';
    ok !$c->is_cancelled,       'not cancelled';
    ok !$c->is_valid_to_cancel, 'invalid to cancel';
    is $c->primary_validation_error->message, 'Deal cancellation not purchased', 'error - Deal cancellation not purchased';
    is $c->primary_validation_error->message_to_client->[0],
        'This contract does not include deal cancellation. Your contract can only be cancelled when you select deal cancellation in your purchase.',
        'message_to_client - This contract does not include deal cancellation. Your contract can only be cancelled when you select deal cancellation in your purchase.';

    $args->{cancellation} = '1h';
    $args->{date_pricing} = $now->plus_time_interval('1h');
    $args->{limit_order}  = {
        stop_out => {
            order_type   => 'stop_out',
            order_amount => -100,
            order_date   => $now->epoch,
            basis_spot   => '100.00',
        }};
    $c = produce_contract($args);
    ok $c->is_valid_to_cancel, 'is valid to cancel';

    $args->{date_pricing} = $now->plus_time_interval('1h1s');
    $c = produce_contract($args);
    ok !$c->is_valid_to_cancel, 'invalid to cancel';
    is $c->primary_validation_error->message, 'Deal cancellation expired', 'error - Deal cancellation expired';
    is $c->primary_validation_error->message_to_client->[0],
        'Deal cancellation period has expired. Your contract can only be cancelled while deal cancellation is active.',
        'message_to_client - Deal cancellation period has expired. Your contract can only be cancelled while deal cancellation is active.';

    # when contract is sold
    $args->{is_sold} = 1;
    $c = produce_contract($args);
    ok !$c->is_valid_to_cancel, 'invalid to cancel';
    is $c->primary_validation_error->message, 'Contract is sold', 'error - Contract is sold';
    is $c->primary_validation_error->message_to_client->[0], 'This contract has been sold.',;
};

subtest 'minmum stake' => sub {
    my $args = {
        bet_type    => 'MULTUP',
        underlying  => 'R_100',
        amount_type => 'stake',
        amount      => 0.9,
        multiplier  => 10,
        currency    => 'USD',
    };
    my $error = exception { produce_contract($args) };
    is $error->message_to_client->[0], 'Please enter a stake amount that\'s at least [_1].', 'message to client - Stake must be at least [_1] 1.';
    is $error->message_to_client->[1], '1.00';

    $args->{amount} = 0;
    $error = exception { produce_contract($args) };
    is $error->message_to_client->[0], 'Please enter a stake amount that\'s at least [_1].', 'message to client - Stake must be at least [_1] 1.';
    is $error->message_to_client->[1], '1.00';
};

subtest 'take profit cap and precision' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100']);
    my $args = {
        bet_type    => 'MULTUP',
        underlying  => 'R_100',
        amount_type => 'stake',
        amount      => 10,
        multiplier  => 10,
        currency    => 'USD',
        limit_order => {
            take_profit => 10000 + 0.01,
        },
    };
    my $c     = produce_contract($args);
    my $error = exception { $c->is_valid_to_buy };
    is $error->message_to_client->[0], 'Please enter a take profit amount that\'s lower than [_1].';
    is $error->message_to_client->[1], '90.00', 'max at 90.00';

    $args->{limit_order}->{take_profit} = 0.000001;
    $c = produce_contract($args);
    ok !$c->is_valid_to_buy, 'invalid to buy';
    is $c->primary_validation_error->message, 'too many decimal places', 'message - too many decimal places';
    is $c->primary_validation_error->message_to_client->[0], 'Only [_1] decimal places allowed.';
    is $c->primary_validation_error->message_to_client->[1], 2;
};

subtest 'stop loss cap' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100']);
    my $args = {
        bet_type    => 'MULTUP',
        underlying  => 'R_100',
        amount_type => 'stake',
        amount      => 10,
        multiplier  => 10,
        currency    => 'USD',
        limit_order => {
            stop_loss => 11,
        },
    };
    my $c = produce_contract($args);
    ok !$c->is_valid_to_buy, 'invalid to buy';
    is $c->primary_validation_error->message, 'stop loss too high', 'message - stop loss too high';
    is $c->primary_validation_error->message_to_client->[0], 'Invalid stop loss. Stop loss cannot be more than [_1].';
    is $c->primary_validation_error->message_to_client->[1], '10.00';

    my $mocked_lo = Test::MockModule->new('BOM::Product::Contract::Multup');
    $mocked_lo->mock(
        '_multiplier_config',
        sub {
            return {
                multiplier_range            => [10],
                commission                  => 5.0366490434625e-05,
                cancellation_commission     => 0.05,
                cancellation_duration_range => ['5m', '10m', '15m', '30m', '60m'],
                stop_out_level              => 10
            };
        });

    $c = produce_contract($args);

    ok !$c->is_valid_to_buy, 'invalid to buy';
    is $c->primary_validation_error->message, 'stop loss too high', 'message - stop loss too high';
    is $c->primary_validation_error->message_to_client->[0], 'Invalid stop loss. Stop loss cannot be more than [_1].';
    is $c->primary_validation_error->message_to_client->[1], '9.00';

    $mocked_lo->unmock_all;
    $mocked->unmock_all;
    $args->{limit_order}->{stop_loss} = 0.09;
    $c = produce_contract($args);
    ok !$c->is_valid_to_buy, 'invalid to buy';
    is $c->primary_validation_error->message, 'stop loss too low', 'message - stop loss too low';
    is $c->primary_validation_error->message_to_client->[0], 'Please enter a stop loss amount that\'s higher than [_1].';
    is $c->primary_validation_error->message_to_client->[1], '0.10';

    $args->{limit_order}->{stop_loss} = 0.1;
    $c = produce_contract($args);
    ok $c->is_valid_to_buy, 'valid to buy';

    $args->{amount}                   = 100;
    $args->{limit_order}->{stop_loss} = 0.11;
    $c                                = produce_contract($args);
    ok !$c->is_valid_to_buy, 'invalid to buy';
    is $c->primary_validation_error->message, 'stop loss lower than pnl', 'message - stop loss lower than pnl';
    is $c->primary_validation_error->message_to_client->[0], 'Invalid stop loss. Stop loss must be higher than commission ([_1]).';
    is $c->primary_validation_error->message_to_client->[1], '0.50';
};

# setting commission to zero for easy calculation
$mocked->mock('commission',        sub { return 0 });
$mocked->mock('commission_amount', sub { return 0 });

subtest 'entry tick inconsistency check' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
        [100, $now->epoch - 1, 'R_100'],
        [101, $now->epoch,     'R_100'],
        [102, $now->epoch + 1, 'R_100']);
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
            }
        },
    };
    my $c = produce_contract($args);
    ok $c->entry_tick, 'entry tick is defined';
    is $c->entry_tick->epoch, $now->epoch - 1, 'entry tick epoch is one second before date start';
    is $c->entry_tick->quote + 0, $c->basis_spot + 0, 'entry tick is same as basis spot';
};

subtest 'close tick inconsistency check' => sub {
    subtest 'sell early' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100, $now->epoch,     'R_100'],
            [102, $now->epoch + 1, 'R_100'],
            [104, $now->epoch + 2, 'R_100'],
            [105, $now->epoch + 3, 'R_100'],
        );
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
                }
            },
        };
        my $c = produce_contract($args);
        ok !$c->close_tick, 'close tick is undef is contract is not sold';
        $args->{is_sold}    = 1;
        $args->{sell_price} = 120;
        $args->{sell_time}  = $now->epoch + 2;

        $c = produce_contract($args);
        ok $c->close_tick, 'close tick is defined';
        is $c->close_tick->epoch, $now->epoch + 1, 'close epoch is correct';
        is $c->close_tick->quote + 0, 102, 'close quote is correct';

        $args->{sell_price} = 140;
        $c = produce_contract($args);
        ok $c->close_tick, 'close tick is defined';
        is $c->close_tick->epoch, $now->epoch + 2, 'close epoch is correct';
        is $c->close_tick->quote + 0, 104, 'close quote is correct';
    };

    subtest 'hit order' => sub {
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
            [100, $now->epoch,     'R_100'],
            [102, $now->epoch + 1, 'R_100'],
            [104, $now->epoch + 2, 'R_100'],
            [105, $now->epoch + 3, 'R_100'],
        );
        my $args = {
            is_sold      => 1,
            bet_type     => 'MULTUP',
            underlying   => 'R_100',
            date_start   => $now,
            date_pricing => $now->epoch + 3,
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
                    order_amount => 19,
                    order_date   => $now->epoch,
                    basis_spot   => '100.00',
                }
            },
        };
        my $c = produce_contract($args);
        ok $c->close_tick, 'close tick is defined';
        is $c->close_tick->epoch, $now->epoch + 1, 'close epoch is correct';
        is $c->close_tick->quote + 0, 102, 'close quote is correct';
    };
};

subtest 'sell at a loss on active deal cancellation' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
        [100, $now->epoch,        'R_100'],
        [102, $now->epoch + 1,    'R_100'],
        [99,  $now->epoch + 2,    'R_100'],
        [105, $now->epoch + 3,    'R_100'],
        [98,  $now->epoch + 3601, 'R_100'],
    );
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
            }
        },
        cancellation => '1h',
    };
    my $c = produce_contract($args);
    ok $c->current_pnl < 0, 'negative pnl';
    ok !$c->is_valid_to_sell, 'invalid to sell';
    is $c->primary_validation_error->message, 'cancel is better', 'message - cancel is better';
    is $c->primary_validation_error->message_to_client,
        'The spot price has moved. We have not closed this contract because your profit is negative and deal cancellation is active. Cancel your contract to get your full stake back.',
        'message_to_client - The spot price has moved. We have not closed this contract because your profit is negative and deal cancellation is active. Cancel your contract to get your full stake back.';

    $args->{date_pricing} = $now->epoch + 3;
    $c = produce_contract($args);
    ok $c->current_pnl > 0, 'positive pnl';
    ok $c->is_valid_to_sell, 'valid to sell when pnl is positive';

    $args->{date_pricing} = $now->epoch + 3601;
    $c = produce_contract($args);
    ok $c->current_pnl < 0, 'negative pnl';
    ok $c->is_valid_to_sell, 'valid to sell with negative pnl after expiry of deal cancellation';
};

subtest 'deal cancellation duration check' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100'], [102, $now->epoch + 1, 'R_100'],);
    my $args = {
        bet_type     => 'MULTUP',
        underlying   => 'R_100',
        date_start   => $now,
        date_pricing => $now,
        amount_type  => 'stake',
        amount       => 100,
        multiplier   => 10,
        currency     => 'USD',
        cancellation => '1',
    };
    my $c = produce_contract($args);
    ok !$c->is_valid_to_buy, 'invalid to buy';
    is $c->primary_validation_error->message_to_client, 'Deal cancellation is not offered at this duration.',
        'message_to_client - Deal cancellation is not offered at this duration.';

    $args->{cancellation} = '1s';
    $c = produce_contract($args);
    ok !$c->is_valid_to_buy, 'invalid to buy';
    is $c->primary_validation_error->message_to_client, 'Deal cancellation is not offered at this duration.',
        'message_to_client - Deal cancellation is not offered at this duration.';

    $args->{cancellation} = '0d';
    $c = produce_contract($args);
    ok !$c->is_valid_to_buy, 'invalid to buy';
    is $c->primary_validation_error->message_to_client, 'Deal cancellation is not offered at this duration.',
        'message_to_client - Deal cancellation is not offered at this duration.';

    $args->{cancellation} = '5m';
    $c = produce_contract($args);
    ok $c->is_valid_to_buy, 'valid to buy 5m cancellation option';

    $args->{cancellation} = '60m';
    $c = produce_contract($args);
    ok $c->is_valid_to_buy, 'valid to buy 60m cancellation option';

    $args->{cancellation} = '1h';
    $c = produce_contract($args);
    ok $c->is_valid_to_buy, 'valid to buy 1h cancellation option';
};

subtest 'deal cancellation suspension' => sub {
    my $suspend = BOM::Config::Runtime->instance->app_config->quants->suspend_deal_cancellation->synthetic_index;
    BOM::Config::Runtime->instance->app_config->quants->suspend_deal_cancellation->synthetic_index(1);
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100'], [102, $now->epoch + 1, 'R_100'],);
    my $args = {
        bet_type     => 'MULTUP',
        underlying   => 'R_100',
        date_start   => $now,
        date_pricing => $now,
        amount_type  => 'stake',
        amount       => 100,
        multiplier   => 10,
        currency     => 'USD',
        cancellation => '1h',
    };
    my $c = produce_contract($args);
    ok !$c->is_valid_to_buy, 'invalid to buy';
    is $c->primary_validation_error->message_to_client, 'Deal cancellation is not available at this moment.',
        'message_to_client - Deal cancellation is not available at this moment.';

    delete $args->{cancellation};
    $c = produce_contract($args);
    ok $c->is_valid_to_buy, 'valid to buy';

    BOM::Config::Runtime->instance->app_config->quants->suspend_deal_cancellation->synthetic_index($suspend);
};

subtest 'deal cancellation with fx' => sub {
    my $mocked_decimate = Test::MockModule->new('BOM::Market::DataDecimate');
    $mocked_decimate->mock(
        'get',
        sub {
            [map { {epoch => $_, decimate_epoch => $_, quote => 100 + 0.005 * $_} } (0 .. 80)];
        });
    my $now = Date::Utility->new('10-Mar-2015');
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc('economic_events', {recorded_date => $now});
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'currency',
        {
            recorded_date => $now,
            symbol        => $_,
        }) for qw( USD JPY JPY-USD );
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            symbol        => $_,
            recorded_date => $now
        }) for qw (frxUSDJPY frxAUDCAD frxUSDCAD frxAUDUSD);
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'frxUSDJPY'], [102, $now->epoch + 1, 'frxUSDJPY'],);
    my $args = {
        bet_type     => 'MULTUP',
        underlying   => 'frxUSDJPY',
        date_start   => $now,
        date_pricing => $now,
        amount_type  => 'stake',
        amount       => 100,
        multiplier   => 50,
        currency     => 'USD',
        cancellation => '1h',
    };
    my $c = produce_contract($args);
    is $c->ask_price,          105.49, 'ask price is 105.49';
    is $c->cancellation_price, '5.49', 'cost of cancellation is 5.49';
};

subtest 'commission multiplier' => sub {
    $mocked->unmock_all;

    note 'dst time';
    my $now  = Date::Utility->new('2020-03-09');
    my $args = {
        bet_type     => 'MULTUP',
        underlying   => 'frxUSDJPY',
        date_start   => $now,
        date_pricing => $now,
        amount_type  => 'stake',
        amount       => 100,
        multiplier   => 10,
        currency     => 'USD',
    };
    my $c = produce_contract($args);
    is $c->commission,            0.0002094, 'commission is at 0.0002094';
    is $c->commission_multiplier, 1.047,     'commission multiplier is 1.047';

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'economic_events',
        {
            recorded_date => $now,
            events        => [{
                    impact       => 5,
                    event_name   => 'test',
                    symbol       => 'USD',
                    source       => 'testff',
                    release_date => $now->plus_time_interval('1m59s')->epoch
                }]});

    note "symbol $args->{underlying}";
    $c = produce_contract($args);
    is $c->commission,            0.0006, 'commission is at 0.0006';
    is $c->commission_multiplier, 3,      'commission multiplier is 3';

    # same commission multiplier applied to frxAUDJPY because of the dominant USD currency
    $args->{underlying} = 'frxAUDJPY';
    note "symbol $args->{underlying}";
    $c = produce_contract($args);
    is $c->commission,            0.0009, 'commission is at 0.0009';
    is $c->commission_multiplier, 3,      'commission multiplier is 3';

    $args->{underlying} = 'R_100';
    note "symbol $args->{underlying}";
    $c = produce_contract($args);
    is $c->commission,            0.000503664904346249, 'commission is at 0.000503664904346249';
    is $c->commission_multiplier, 1,                    'commission multiplier is 1';

    note "AUD event does not affect frxUSDJPY";
    my $new_now = $now->plus_time_interval('1h');
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'economic_events',
        {
            recorded_date => $new_now,
            events        => [{
                    impact       => 5,
                    event_name   => 'test',
                    symbol       => 'AUD',
                    source       => 'testff',
                    release_date => $new_now->minus_time_interval('1m59s')->epoch
                }]});

    $args->{date_start} = $args->{date_pricing} = $new_now;
    $args->{underlying} = 'frxUSDJPY';
    $c                  = produce_contract($args);
    is $c->commission,            0.0002172, 'commission is at 0.0002172';
    is $c->commission_multiplier, 1.086,     'commission multiplier is 1.086';

    $args->{underlying} = 'frxAUDJPY';
    note "AUD event affects $args->{underlying}";
    note "symbol $args->{underlying}";
    $c = produce_contract($args);
    is $c->commission,            0.0009, 'commission is at 0.0009';
    is $c->commission_multiplier, 3,      'commission multiplier is 3';

    note "AUD event does not affect $args->{underlying} when it is out of range";
    $args->{date_start} = $args->{date_pricing} = $new_now->plus_time_interval('1m');
    $c = produce_contract($args);
    is $c->commission,            0.0003279, 'commission is at 0.0003279';
    is $c->commission_multiplier, 1.093,     'commission multiplier is 1.093';
};

subtest 'deal cancellation with TP and blackout condition' => sub {
    my $now = Date::Utility->new('2020-06-05 10:00:00');
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
        cancellation => '1h',
        limit_order  => {take_profit => 10},
    };
    my $c = produce_contract($args);
    ok !$c->is_valid_to_buy, 'invalid to buy';
    is $c->primary_validation_error->message, 'deal cancellation set with take profit', 'message';
    is $c->primary_validation_error->message_to_client,
        'You may use either take profit or deal cancellation, but not both. Please select either one.', 'message to client';

    delete $args->{limit_order};
    $now = Date::Utility->new('2020-11-02 21:00:00');
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100']);
    $args->{date_start} = $args->{date_pricing} = $now;
    $c = produce_contract($args);
    ok $c->is_valid_to_buy, 'valid to buy for synthetic index';

    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'frxUSDJPY']);
    $args->{underlying} = 'frxUSDJPY';
    $args->{multiplier} = 50;
    $c                  = produce_contract($args);
    ok !$c->is_valid_to_buy, 'invalid to buy';
    is $c->primary_validation_error->message, 'deal cancellation blackout period', 'message';
    is $c->primary_validation_error->message_to_client->[0], 'Deal cancellation is not available from [_1] to [_2].', 'message to client';
    is $c->primary_validation_error->message_to_client->[1], '2020-11-02 21:00:00',                                   'message to client';
    is $c->primary_validation_error->message_to_client->[2], '2020-11-02 23:59:59',                                   'message to client';
};

subtest 'variable deal cancellation price with variable stop out level' => sub {
    my $mocked_lo = Test::MockModule->new('BOM::Product::Contract::Multup');
    $mocked_lo->mock(
        '_multiplier_config',
        sub {
            return {
                multiplier_range            => [200],
                commission                  => 5.0366490434625e-05,
                cancellation_commission     => 0.05,
                cancellation_duration_range => ['5m', '10m', '15m', '30m', '60m'],
                stop_out_level              => 10
            };
        });

    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100']);
    my $args = {
        bet_type     => 'MULTUP',
        underlying   => 'R_100',
        date_start   => $now,
        date_pricing => $now,
        amount_type  => 'stake',
        amount       => 100,
        multiplier   => 200,
        currency     => 'USD',
        cancellation => '1h',
    };
    my $c  = produce_contract($args);
    my $c1 = $c->cancellation_price;

    $mocked_lo->mock(
        '_multiplier_config',
        sub {
            return {
                multiplier_range            => [200],
                commission                  => 5.0366490434625e-05,
                cancellation_commission     => 0.05,
                cancellation_duration_range => ['5m', '10m', '15m', '30m', '60m'],
                stop_out_level              => 99
            };
        });
    $c = produce_contract($args);
    my $c2 = $c->cancellation_price;
    ok $c1 > $c2, 'price should be lower if contract is more likely to stop out';
    $mocked_lo->unmock_all();
};

subtest 'rollover blackout' => sub {
    subtest 'is valid to buy' => sub {
        my $non_dst = Date::Utility->new('2020-03-02 22:00:01');
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $non_dst->epoch, 'R_100']);
        my $args = {
            bet_type     => 'MULTUP',
            underlying   => 'R_100',
            date_start   => $non_dst,
            date_pricing => $non_dst,
            amount_type  => 'stake',
            amount       => 100,
            multiplier   => 100,
            currency     => 'USD',
        };
        my $c = produce_contract($args);
        ok $c->is_valid_to_buy, 'valid to buy for synthetic indices';

        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $non_dst->epoch, 'frxUSDJPY']);
        $args->{underlying} = 'frxUSDJPY';
        $args->{multiplier} = 100;

        $c = produce_contract($args);
        ok !$c->is_valid_to_buy, 'not valid to buy';
        is $c->primary_validation_error->message, 'multiplier option blackout period during volsurface rollover', 'blackout period for multiplier';
        is $c->primary_validation_error->message_to_client->[0], 'Trading is not available from [_1] to [_2].';
        is $c->primary_validation_error->message_to_client->[1], '21:55:00';
        is $c->primary_validation_error->message_to_client->[2], '22:30:00';

        my $after_rollover = Date::Utility->new('2020-03-02 22:30:01');
        $args->{date_pricing} = $args->{date_start} = $after_rollover;
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $after_rollover->epoch, 'frxUSDJPY']);
        $c = produce_contract($args);
        ok $c->is_valid_to_buy, 'valid to buy after blackout';

        my $dst = Date::Utility->new('2020-03-09 21:00:01');
        $args->{date_pricing} = $args->{date_start} = $dst;
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $dst->epoch, 'frxUSDJPY']);

        $c = produce_contract($args);
        ok !$c->is_valid_to_buy, 'not valid to buy';
        is $c->primary_validation_error->message, 'multiplier option blackout period during volsurface rollover', 'blackout period for multiplier';
        is $c->primary_validation_error->message_to_client->[0], 'Trading is not available from [_1] to [_2].';
        is $c->primary_validation_error->message_to_client->[1], '20:55:00';
        is $c->primary_validation_error->message_to_client->[2], '21:30:00';

        $after_rollover = Date::Utility->new('2020-03-09 21:30:01');
        $args->{date_pricing} = $args->{date_start} = $after_rollover;
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $after_rollover->epoch, 'frxUSDJPY']);
        $c = produce_contract($args);
        ok $c->is_valid_to_buy, 'valid to buy after blackout';
    };

    subtest 'is valid to sell' => sub {
        my $non_dst = Date::Utility->new('2020-03-02 22:00:01');
        my $ds      = $non_dst->minus_time_interval('1s');
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([101.02, $ds->epoch, 'frxUSDJPY'], [100, $non_dst->epoch, 'frxUSDJPY']);
        my $args = {
            bet_type     => 'MULTUP',
            underlying   => 'frxUSDJPY',
            date_start   => $ds,
            date_pricing => $non_dst,
            amount_type  => 'stake',
            amount       => 100,
            multiplier   => 200,
            currency     => 'USD',
            limit_order  => {
                stop_out => {
                    order_type   => 'stop_out',
                    order_amount => -100,
                    order_date   => $ds->epoch,
                    basis_spot   => '100.00',
                }
            },
        };
        my $c = produce_contract($args);
        ok $c->is_valid_to_sell, 'valid to sell during blackout for forex ';
    };
};

subtest 'deal cancellation on crash/boom' => sub {
    my $now = Date::Utility->new;
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([101.02, $now->epoch, 'CRASH1000']);
    my $args = {
        bet_type     => 'MULTUP',
        underlying   => 'CRASH1000',
        date_start   => $now,
        date_pricing => $now,
        amount_type  => 'stake',
        amount       => 100,
        multiplier   => 200,
        currency     => 'USD',
    };
    my $c = produce_contract($args);
    ok $c->is_valid_to_buy, 'valid to buy';

    $args->{multiplier} = 10;
    $c = produce_contract($args);
    ok !$c->is_valid_to_buy, 'invalid to buy';
    is $c->primary_validation_error->message, 'multiplier out of range', 'multiplier out of range';
    is $c->primary_validation_error->message_to_client->[0], 'Multiplier is not in acceptable range. Accepts [_1].',
        'message to client - Multiplier is not in acceptable range. Accepts [_1].';

    $args->{multiplier}   = 100;
    $args->{cancellation} = '1h';
    $c                    = produce_contract($args);
    ok !$c->is_valid_to_buy, 'invalid to buy';
    is $c->primary_validation_error->message, 'deal cancellation not available', 'deal cancellation not available';
    is $c->primary_validation_error->message_to_client, 'Deal cancellation is not available for this asset.',
        'message to client - Deal cancellation is not available for this asset.';

    delete $args->{cancellation};
    $args->{underlying} = 'BOOM1000';
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([101.02, $now->epoch, 'BOOM1000']);
    $args->{multiplier} = 10;
    $c = produce_contract($args);
    ok !$c->is_valid_to_buy, 'invalid to buy';
    is $c->primary_validation_error->message, 'multiplier out of range', 'multiplier out of range';
    is $c->primary_validation_error->message_to_client->[0], 'Multiplier is not in acceptable range. Accepts [_1].',
        'message to client - Multiplier is not in acceptable range. Accepts [_1].';

    $args->{multiplier}   = 100;
    $args->{cancellation} = '1h';
    $c                    = produce_contract($args);
    ok !$c->is_valid_to_buy, 'invalid to buy';
    is $c->primary_validation_error->message, 'deal cancellation not available', 'deal cancellation not available';
    is $c->primary_validation_error->message_to_client, 'Deal cancellation is not available for this asset.',
        'message to client - Deal cancellation is not available for this asset.';
};

subtest 'deal cancellation on step index' => sub {
    my $now = Date::Utility->new;
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([101.02, $now->epoch, 'stpRNG']);
    my $args = {
        bet_type     => 'MULTUP',
        underlying   => 'stpRNG',
        date_start   => $now,
        date_pricing => $now,
        amount_type  => 'stake',
        amount       => 100,
        multiplier   => 500,
        currency     => 'USD',
    };
    my $c = produce_contract($args);
    ok $c->is_valid_to_buy, 'valid to buy';

    $args->{multiplier} = 10;
    $c = produce_contract($args);
    ok !$c->is_valid_to_buy, 'invalid to buy';
    is $c->primary_validation_error->message, 'multiplier out of range', 'multiplier out of range';
    is $c->primary_validation_error->message_to_client->[0], 'Multiplier is not in acceptable range. Accepts [_1].',
        'message to client - Multiplier is not in acceptable range. Accepts [_1].';

    $args->{multiplier}   = 500;
    $args->{cancellation} = '1h';
    $c                    = produce_contract($args);
    ok !$c->is_valid_to_buy, 'invalid to buy';
    is $c->primary_validation_error->message, 'deal cancellation not available', 'deal cancellation not available';
    is $c->primary_validation_error->message_to_client, 'Deal cancellation is not available for this asset.',
        'message to client - Deal cancellation is not available for this asset.';

    delete $args->{cancellation};
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([101.02, $now->epoch, 'stpRNG']);
    $args->{multiplier} = 10;
    $c = produce_contract($args);
    ok !$c->is_valid_to_buy, 'invalid to buy';
    is $c->primary_validation_error->message, 'multiplier out of range', 'multiplier out of range';
    is $c->primary_validation_error->message_to_client->[0], 'Multiplier is not in acceptable range. Accepts [_1].',
        'message to client - Multiplier is not in acceptable range. Accepts [_1].';

    $args->{multiplier}   = 500;
    $args->{cancellation} = '1h';
    $c                    = produce_contract($args);
    ok !$c->is_valid_to_buy, 'invalid to buy';
    is $c->primary_validation_error->message, 'deal cancellation not available', 'deal cancellation not available';
    is $c->primary_validation_error->message_to_client, 'Deal cancellation is not available for this asset.',
        'message to client - Deal cancellation is not available for this asset.';
};

subtest 'variable stop out for crash/boom indices' => sub {
    # commission mocked to zero for easier verification
    $mocked->mock('commission',        sub { return 0 });
    $mocked->mock('commission_amount', sub { return 0 });

    subtest 'stop out level check' => sub {
        my $now = Date::Utility->new;
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'CRASH1000']);
        my $args = {
            bet_type     => 'MULTUP',
            underlying   => 'CRASH1000',
            date_start   => $now,
            date_pricing => $now,
            amount_type  => 'stake',
            amount       => 100,
            multiplier   => 100,
            currency     => 'USD',
        };
        my $c = produce_contract($args);
        ok $c->is_valid_to_buy, 'valid to buy';
        is $c->stop_out_level, 10, 'stop out level 10 for multiplier 100';
        is $c->stop_out->barrier_value, "99.100", 'stop out barrie value 99.100';

        $args->{multiplier} = 200;
        $c = produce_contract($args);
        ok $c->is_valid_to_buy, 'valid to buy';
        is $c->stop_out_level, 20, 'stop out level 20 for multiplier 200';
        is $c->stop_out->barrier_value, "99.600", 'stop out barrie value 99.600';

        $args->{multiplier} = 300;
        $c = produce_contract($args);
        ok $c->is_valid_to_buy, 'valid to buy';
        is $c->stop_out_level, 30, 'stop out level 30 for multiplier 300';
        is $c->stop_out->barrier_value, "99.767", 'stop out barrie value 99.767';

        $args->{multiplier} = 400;
        $c = produce_contract($args);
        ok $c->is_valid_to_buy, 'valid to buy';
        is $c->stop_out_level, 50, 'stop out level 50 for multiplier 400';
        is $c->stop_out->barrier_value, "99.875", 'stop out barrie value 99.875';
    };

    subtest 'stop out breached' => sub {
        my $now = Date::Utility->new;
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'CRASH1000'], [99.05, $now->epoch + 1, 'CRASH1000']);
        my $args = {
            bet_type     => 'MULTUP',
            underlying   => 'CRASH1000',
            date_start   => $now,
            date_pricing => $now->epoch + 1,
            amount_type  => 'stake',
            amount       => 100,
            multiplier   => 100,
            currency     => 'USD',
            limit_order  => {
                stop_out => {
                    order_type   => 'stop_out',
                    order_amount => -90,
                    order_date   => $now->epoch,
                    basis_spot   => '100.00',
                }
            },
        };
        my $c = produce_contract($args);
        is $c->stop_out_level, 10, 'stop out level 10 for multiplier 100';
        is $c->stop_out->barrier_value, "99.100", 'stop out barrie value 99.100';
        ok $c->is_expired, 'expired';
        is $c->hit_type,   'stop_out';
        is $c->value,      '5.00', 'contract value 5.00';

        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'CRASH1000'], [98.9, $now->epoch + 1, 'CRASH1000']);
        $c = produce_contract($args);
        is $c->stop_out_level, 10, 'stop out level 10 for multiplier 100';
        is $c->stop_out->barrier_value, "99.100", 'stop out barrie value 99.100';
        ok $c->is_expired, 'expired';
        is $c->hit_type,   'stop_out';
        is $c->value,      '0.00', 'contract value 0. Does not lose more than stake';
    };
};

subtest 'no warnings if spread multiplier is undefined' => sub {
    my $now = Date::Utility->new;
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'frxUSDJPY'], [102, $now->epoch + 1, 'frxUSDJPY'],);
    my $args = {
        bet_type     => 'MULTUP',
        underlying   => 'frxGBPPLN',
        date_start   => $now,
        date_pricing => $now,
        amount_type  => 'stake',
        amount       => 100,
        multiplier   => 50,
        currency     => 'USD',
        cancellation => '1h',
    };
    my $c = produce_contract($args);
    ok !$c->is_valid_to_buy, 'invalid to buy';
    is $c->primary_validation_error->message, 'spread seasonality not defined for frxGBPPLN',
        'message - spread seasonality not defined for frxGBPPLN';
    is $c->primary_validation_error->message_to_client, 'Trading is not offered for this asset.';
};

done_testing();
