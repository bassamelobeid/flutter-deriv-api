#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 5;
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

subtest 'input validity' => sub {
    my $c = produce_contract({%$params});
    ok !($c->all_errors)[0], 'no error';
    foreach my $attr (qw(amount_per_point stop_loss stop_profit)) {
        $c = produce_contract({%$params, $attr => -1});
        ok (($c->all_errors)[0], "error if $attr is negative");
        like (($c->all_errors)[0]->message_to_client, qr/must be greater than zero/, 'correct message');
        $c = produce_contract({%$params, $attr => 0});
        ok (($c->all_errors)[0], "error if $attr is zero");
        like (($c->all_errors)[0]->message_to_client, qr/must be greater than zero/, 'correct message');
    }
};

subtest 'stop type' => sub {
    my $c = produce_contract({%$params, stop_type => 'point', amount_per_point => 2, stop_loss => 10});
    is $c->ask_price, 20.00, 'ask is 20.00';
    like ($c->longcode, qr/with stop loss of 10 points and limit of 10 points/, 'correct longcode for stop_type: point');
    is $c->shortcode, 'SPREADU_R_100_2_'.$now->epoch.'_10_10_POINT';
    $c = produce_contract({%$params, stop_type => 'dollar', amount_per_point => 2, stop_loss => 10});
    is $c->ask_price, 10.00, 'ask is 10.00';
    like ($c->longcode, qr/with stop loss of USD 10 and limit of USD 10/, 'correct longcode for stop_type: dollar');
    is $c->shortcode, 'SPREADU_R_100_2_'.$now->epoch.'_10_10_DOLLAR';
};
