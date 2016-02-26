#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 10;
use Test::Exception;
use Test::NoWarnings;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestMD qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

use BOM::Product::ContractFactory qw(produce_contract);
use Date::Utility;

my $now = Date::Utility->new;
BOM::Test::Data::Utility::UnitTestMD::create_doc('currency', {symbol => 'USD'});
my $params = {
    bet_type         => 'SPREADU',
    underlying       => 'R_100',
    date_start       => $now,
    amount_per_point => 1,
    stop_loss        => 10,
    stop_profit      => 10,
    currency         => 'USD',
    stop_type        => 'point',
};

subtest 'entry tick' => sub {
    lives_ok {
        my $c = produce_contract({
            %$params,
            current_tick => undef,
            spread       => 1
        });
        isa_ok $c, 'BOM::Product::Contract::Spreadu';
        is $c->entry_tick->quote, 0.01, 'entry tick is pip size value if current tick and next tick is undefiend';
        ok($c->primary_validation_error, 'error');
        my $curr_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $now->epoch,
            quote      => 100
        });
        $c = produce_contract({%$params, current_tick => $curr_tick});
        isa_ok $c, 'BOM::Product::Contract::Spreadu';
        is $c->entry_tick->quote, 100, 'current tick if next tick is undefined';
        ok($c->primary_validation_error, 'error');

        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $now->epoch + 2,
            quote      => 104
        });
        $c = produce_contract($params);
        is $c->entry_tick->quote, 104, 'entry tick if it is defined';
        ok(!$c->primary_validation_error, 'no error');
    }
    'spreadup';
};

subtest 'current tick' => sub {
    my $u = Test::MockModule->new('BOM::Market::Underlying');
    $u->mock('get_combined_realtime_tick', sub { undef });
    my $c = produce_contract($params);
    is $c->current_tick->quote, 0.01, 'current tick is pip size value if current tick is undefined';
    ok($c->primary_validation_error, 'error');
};

subtest 'validate amount per point' => sub {
    lives_ok {
        my $c = produce_contract({
            %$params,
            amount_per_point => 0,
            date_pricing     => $now
        });
        my @e;
        ok !$c->is_valid_to_buy;
        like(
            $c->primary_validation_error->message_to_client,
            qr/Amount Per Point must be between 1 and 100 USD/,
            'throw message when amount per point is zero'
        );
        $c = produce_contract({
            %$params,
            amount_per_point => -1,
            date_pricing     => $now
        });
        ok !$c->is_valid_to_buy;
        like(
            $c->primary_validation_error->message_to_client,
            qr/Amount Per Point must be between 1 and 100 USD/,
            'throw message when amount per point is zero'
        );
        $c = produce_contract({
            %$params,
            amount_per_point => 1,
            date_pricing     => $now
        });
        ok $c->is_valid_to_buy;
        $c = produce_contract({
            %$params,
            amount_per_point => 99.9,
            date_pricing     => $now
        });
        ok $c->is_valid_to_buy;
        $c = produce_contract({
            %$params,
            amount_per_point => 100.1,
            date_pricing     => $now
        });
        ok !$c->is_valid_to_buy;
        like(
            $c->primary_validation_error->message_to_client,
            qr/Amount Per Point must be between 1 and 100 USD/,
            'throw message when amount per point is zero'
        );
    }
    'validate amount per point';
};

subtest 'validate stop loss' => sub {
    lives_ok {
        my $c = produce_contract({%$params, spread => 1});
        is $c->spread, 1, 'spread is 1';
        my @e;
        $c = produce_contract({
            %$params,
            spread       => 1,
            stop_loss    => 1.4,
            stop_type    => 'point',
            current_spot => 100,
        });
        ok @e = $c->_validate_stop_loss, 'has error';
        like($e[0]{message_to_client}, qr/Stop Loss must be between 1.5 and 100 points/, 'throws error when stop loss is less than minimum');
        $c = produce_contract({
            %$params,
            spread    => 1,
            stop_loss => 1.5,
            stop_type => 'point'
        });
        ok !$c->_validate_stop_loss, 'no error';
        $c = produce_contract({
            %$params,
            amount_per_point => 2,
            spread           => 1,
            stop_loss        => 2,
            stop_type        => 'dollar',
            current_spot     => 100,
        });
        ok @e = $c->_validate_stop_loss, 'has error';
        like($e[0]{message_to_client}, qr/Stop Loss must be between 3 and 200 USD/, 'throws error when stop loss is less than minimum');
        $c = produce_contract({
            %$params,
            spread       => 1,
            stop_loss    => 200,
            current_spot => 199,
            stop_type    => 'point',
        });
        ok @e = $c->_validate_stop_loss, 'has error';
        like($e[0]{message_to_client}, qr/Stop Loss must be between 1.5 and 199 points/, 'throws error when stop loss is greater than current spot');
    }
    'validate stop loss';
};

subtest 'validate stop profit' => sub {
    lives_ok {
        my $c = produce_contract({
            %$params,
            stop_loss   => 1,
            stop_profit => 5
        });
        ok !$c->_validate_stop_profit, 'no error';
        my @e;
        $c = produce_contract({
            %$params,
            stop_loss   => 1,
            stop_profit => 6
        });
        ok @e = $c->_validate_stop_profit, 'has error';
        like($e[0]{message_to_client}, qr/Stop Profit must be between 1 and 5 points/, 'throws error when stop profit is more than 5x stop loss');
        $c = produce_contract({
            %$params,
            stop_loss   => 1,
            stop_profit => 6,
            stop_type   => 'dollar'
        });
        ok @e = $c->_validate_stop_profit, 'has error';
        like($e[0]{message_to_client}, qr/Stop Profit must be between 1 and 5 USD/, 'throws error when stop profit is more than 5x stop loss');
        $c = produce_contract({%$params, stop_profit => 0});
        ok @e = $c->_validate_stop_profit, 'has error';
        like($e[0]{message_to_client}, qr/Stop Profit must be between 1 and 50 points/, 'throws error when stop profit is zero');
        $c = produce_contract({%$params, stop_profit => -1});
        ok @e = $c->_validate_stop_profit, 'has error';
        like($e[0]{message_to_client}, qr/Stop Profit must be between 1 and 50 points/, 'throws error when stop profit is negative');
    }
    'validate stop profit';
};

subtest 'stop type' => sub {
    my $c = produce_contract({
        %$params,
        stop_type        => 'point',
        amount_per_point => 2,
        stop_loss        => 10
    });
    is $c->ask_price, 20, 'ask is 20';
    like($c->longcode, qr/with stop loss of 10 points and stop profit of 10 points/, 'correct longcode for stop_type: point and stop_loss of 10');
    $c = produce_contract({
        %$params,
        stop_type        => 'point',
        amount_per_point => 2,
        stop_loss        => 1,
        bet_type         => 'SPREADU'
    });
    like(
        $c->longcode,
        qr/with stop loss of 1 points and stop profit of 10 points/,
        '[SPREADU] correct longcode for stop_type: point and stop_loss of 1'
    );
    $c = produce_contract({
        %$params,
        stop_type        => 'point',
        amount_per_point => 2,
        stop_loss        => 1,
        bet_type         => 'SPREADD'
    });
    like(
        $c->longcode,
        qr/with stop loss of 1 points and stop profit of 10 points/,
        '[SPREADD] correct longcode for stop_type: point and stop_loss of 1'
    );
    $c = produce_contract({
        %$params,
        stop_type        => 'dollar',
        amount_per_point => 2,
        stop_loss        => 10
    });
    is $c->ask_price, 10, 'ask is 10';
    like($c->longcode, qr/with stop loss of USD 10 and stop profit of USD 10/, 'correct longcode for stop_type: dollar');
    is $c->shortcode, 'SPREADU_R_100_2_' . $now->epoch . '_10_10_DOLLAR';

    # decimals longcode
    $c = produce_contract({
        %$params,
        bet_type  => 'SPREADU',
        stop_type => 'point',
        stop_loss => 0.6,
    });
    like($c->longcode, qr/with stop loss of 0\.6 points and stop profit of 10 points/, 'correct longcode decimals stop_loss');
    $c = produce_contract({
        %$params,
        bet_type  => 'SPREADD',
        stop_type => 'point',
        stop_loss => 0.6,
    });
    like($c->longcode, qr/with stop loss of 0\.6 points and stop profit of 10 points/, 'correct longcode for decimals stop_loss');
};

subtest 'category' => sub {
    my $c = produce_contract({
        %$params,
        stop_type        => 'point',
        amount_per_point => 2,
        stop_loss        => 10
    });
    ok !$c->supported_expiries, 'no expiry concept';
    is_deeply $c->supported_start_types, ['spot'], 'spot';
    ok !$c->is_path_dependent,      'non path dependent';
    ok !$c->allow_forward_starting, 'non forward-starting';
    ok !$c->two_barriers,           'non two barriers';
};

subtest 'payout' => sub {
    my $c = produce_contract({
        %$params,
        stop_type        => 'point',
        amount_per_point => 2,
        stop_profit      => 10,
    });
    cmp_ok $c->payout, '==', 20, 'correct payout with stop_type as point';
    $c = produce_contract({
        %$params,
        stop_type        => 'dollar',
        amount_per_point => 2,
        stop_profit      => 10,
    });
    cmp_ok $c->payout, '==', 10, 'correct payout with stop_type as dollar';
};

subtest 'spread constants' => sub {
    my $c = produce_contract($params);
    ok $c->is_spread, 'is_spread';
    ok !$c->fixed_expiry,        'not fixed_expiry';
    ok !$c->tick_expiry,         'not tick_expiry';
    ok !$c->is_atm_bet,          'not is_atm_bet';
    ok !$c->expiry_daily,        'not expiry_daily';
    ok !$c->pricing_engine_name, 'pricing engine name is \'\'';
};
