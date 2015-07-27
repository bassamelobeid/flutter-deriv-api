#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 7;
use Test::Exception;
use Test::NoWarnings;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

use BOM::Product::ContractFactory qw(produce_contract);
use Date::Utility;

my $now = Date::Utility->new;
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('exchange', {symbol => 'RANDOM'});
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('currency', {symbol => 'USD'});
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_flat',
    {
        symbol        => 'R_100',
        recorded_date => $now
    });

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
        my $c = produce_contract({%$params, current_tick => undef});
        isa_ok $c, 'BOM::Product::Contract::Spreadu';
        is $c->entry_tick->quote, 0.01, 'entry tick is pip size value if current tick and next tick is undefiend';
        ok(($c->all_errors)[0], 'error');
        my $curr_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $now->epoch,
            quote      => 100
        });
        $c = produce_contract({%$params, current_tick => $curr_tick});
        isa_ok $c, 'BOM::Product::Contract::Spreadu';
        is $c->entry_tick->quote, 100, 'current tick if next tick is undefined';
        ok(($c->all_errors)[0], 'error');

        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $now->epoch + 2,
            quote      => 104
        });
        $c = produce_contract($params);
        is $c->entry_tick->quote, 104, 'entry tick if it is defined';
        ok(!($c->all_errors)[0], 'no error');
    }
    'spreadup';
};

subtest 'current tick' => sub {
    my $u = Test::MockModule->new('BOM::Market::Underlying');
    $u->mock('get_combined_realtime_tick', sub { undef });
    my $c = produce_contract($params);
    is $c->current_tick->quote, 0.01, 'current tick is pip size value if current tick is undefined';
    ok(($c->all_errors)[0], 'error');
};

subtest 'validate amount per point' => sub {
    lives_ok {
        my $c = produce_contract({%$params, amount_per_point => 0});
        my @e;
        ok @e = $c->_validate_amount_per_point, 'has error';
        like($e[0]{message_to_client}, qr/at least USD 1/, 'throw message when amount per point is zero');
        $c = produce_contract({%$params, amount_per_point => -1});
        ok @e = $c->_validate_amount_per_point, 'has error';
        like($e[0]{message_to_client}, qr/at least USD 1/, 'throw message when amount per point is zero');
        $c = produce_contract({%$params, amount_per_point => 1});
        ok !$c->_validate_amount_per_point, 'no error';
        $c = produce_contract({%$params, amount_per_point => 100});
        ok !$c->_validate_amount_per_point, 'no error when amount per point is 100';
        $c = produce_contract({%$params, amount_per_point => 100.1});
        ok @e = $c->_validate_amount_per_point, 'has error';
        like($e[0]{message}, qr/Amount per point .* greater than limit/, 'throw message when amount per point is greater than 100');
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
            spread    => 1,
            stop_loss => 1.9,
            stop_type => 'point'
        });
        ok @e = $c->_validate_stop_loss, 'has error';
        like($e[0]{message_to_client}, qr/Stop Loss must be at least 2 points/, 'throws error when stop loss is less than minimum');
        $c = produce_contract({
            %$params,
            spread    => 1,
            stop_loss => 2,
            stop_type => 'point'
        });
        ok !$c->_validate_stop_loss, 'no error';
        $c = produce_contract({
            %$params,
            amount_per_point => 2,
            spread           => 1,
            stop_loss        => 2,
            stop_type        => 'dollar'
        });
        ok @e = $c->_validate_stop_loss, 'has error';
        like($e[0]{message_to_client}, qr/Stop Loss must be at least USD 4/, 'throws error when stop loss is less than minimum');
        $c = produce_contract({
            %$params,
            spread       => 1,
            stop_loss    => 200,
            current_spot => 199
        });
        ok @e = $c->_validate_stop_loss, 'has error';
        like($e[0]{message_to_client}, qr/Stop Loss must not be greater than spot price/, 'throws error when stop loss is greater than current spot');
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
        like($e[0]{message_to_client}, qr/Stop Profit must not be greater than 5 points/, 'throws error when stop profit is more than 5x stop loss');
        $c = produce_contract({
            %$params,
            stop_loss   => 1,
            stop_profit => 6,
            stop_type   => 'dollar'
        });
        ok @e = $c->_validate_stop_profit, 'has error';
        like($e[0]{message_to_client}, qr/Stop Profit must not be greater than USD 5/, 'throws error when stop profit is more than 5x stop loss');
        $c = produce_contract({%$params, stop_profit => 0});
        ok @e = $c->_validate_stop_profit, 'has error';
        like($e[0]{message}, qr/Negative entry on stop_profit/, 'throws error when stop profit is zero');
        $c = produce_contract({%$params, stop_profit => -1});
        ok @e = $c->_validate_stop_profit, 'has error';
        like($e[0]{message}, qr/Negative entry on stop_profit/, 'throws error when stop profit is negative');
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
    is $c->ask_price, 20.00, 'ask is 20.00';
    like(
        $c->longcode,
        qr/with stop loss of <strong>10 points<\/strong> and stop profit of <strong>10 points<\/strong>/,
        'correct longcode for stop_type: point'
    );
    is $c->shortcode, 'SPREADU_R_100_2_' . $now->epoch . '_10_10_POINT';
    $c = produce_contract({
        %$params,
        stop_type        => 'dollar',
        amount_per_point => 2,
        stop_loss        => 10
    });
    is $c->ask_price, 10.00, 'ask is 10.00';
    like(
        $c->longcode,
        qr/with stop loss of <strong>USD 10<\/strong> and stop profit of <strong>USD 10<\/strong>/,
        'correct longcode for stop_type: dollar'
    );
    is $c->shortcode, 'SPREADU_R_100_2_' . $now->epoch . '_10_10_DOLLAR';
};
