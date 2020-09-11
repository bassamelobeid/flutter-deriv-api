#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

use BOM::Product::ContractFactory qw(produce_contract);
use Date::Utility;
use Test::MockModule;

use Test::Fatal;

my $mocked = Test::MockModule->new('BOM::Product::Contract::Multdown');
# setting commission to zero for easy calculation
$mocked->mock('commission',        sub { return 0 });
$mocked->mock('commission_amount', sub { return 0 });

my $now = Date::Utility->new;

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => 'USD',
        recorded_date => $now
    });

subtest 'pricing new - general' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100']);
    my $args = {
        bet_type     => 'MULTDOWN',
        underlying   => 'R_100',
        date_start   => $now,
        date_pricing => $now,
        amount_type  => 'stake',
        amount       => 100,
        multiplier   => 10,
        currency     => 'USD',
    };
    my $c = produce_contract($args);
    is $c->code,            'MULTDOWN', 'code is MULTDOWN';
    is $c->pricing_code,    'MULTDOWN', 'pricing_code is MULTDOWN';
    is $c->other_side_code, undef,      'other_side_code is undef';
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
    is $c->stop_out->barrier_value, '110.00';

    $args->{limit_order} = {
        'take_profit' => 50,
    };
    $c = produce_contract($args);
    isa_ok $c->take_profit, 'BOM::Product::LimitOrder';
    is $c->take_profit->order_type, 'take_profit';
    is $c->take_profit->order_date->epoch, $c->date_pricing->epoch;
    is $c->take_profit->order_amount,  50;
    is $c->take_profit->basis_spot,    '100.00';
    is $c->take_profit->barrier_value, '95.00';

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
        bet_type     => 'MULTDOWN',
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
    is $c->stop_out->barrier_value, '110.00';
};

subtest 'shortcode' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100']);
    my $args = {
        bet_type     => 'MULTDOWN',
        underlying   => 'R_100',
        date_start   => $now,
        date_pricing => $now,
        amount_type  => 'stake',
        amount       => 100,
        multiplier   => 10,
        currency     => 'USD',
    };
    my $c = produce_contract($args);
    is $c->shortcode, 'MULTDOWN_R_100_100_10_' . $now->epoch . '_' . $c->date_expiry->epoch . '_0_0.00', 'shortcode populated correctly';
};

subtest 'deal cancellation' => sub {
    my $args = {
        date_start   => $now,
        date_pricing => $now,
        bet_type     => 'MULTDOWN',
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
};

subtest 'minmum stake' => sub {
    my $args = {
        bet_type    => 'MULTDOWN',
        underlying  => 'R_100',
        amount_type => 'stake',
        amount      => 0.9,
        multiplier  => 10,
        currency    => 'USD',
    };
    my $error = exception { produce_contract($args) };
    is $error->message_to_client->[0], 'Please enter a stake amount that\'s at least [_1].', 'message to client - Stake must be at least [_1] 1.';
    is $error->message_to_client->[1], '1.00';
};

subtest 'take profit cap' => sub {
    my $args = {
        bet_type    => 'MULTDOWN',
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
};

subtest 'deal cancellation duration check' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100'], [102, $now->epoch + 1, 'R_100'],);
    my $args = {
        bet_type     => 'MULTDOWN',
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
        bet_type     => 'MULTDOWN',
        underlying   => 'frxUSDJPY',
        date_start   => $now,
        date_pricing => $now,
        amount_type  => 'stake',
        amount       => 100,
        multiplier   => 10,
        currency     => 'USD',
        cancellation => '1h',
    };
    my $c = produce_contract($args);
    is $c->ask_price, 101.1, 'ask price is 101.1';
    is $c->cancellation_price , '1.10', 'cost of cancellation is 1.1';
};
done_testing();
