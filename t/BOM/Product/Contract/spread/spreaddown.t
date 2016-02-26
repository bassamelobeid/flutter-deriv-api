#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 4;
use Test::Exception;
use Test::NoWarnings;

use BOM::Test::Data::Utility::UnitTestMD qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

use BOM::Product::ContractFactory qw(produce_contract);
use Date::Utility;

my $now = Date::Utility->new();
BOM::Test::Data::Utility::UnitTestMD::create_doc('currency', {symbol => 'USD'});
my $params = {
    spread           => 2,
    bet_type         => 'SPREADD',
    currency         => 'USD',
    underlying       => 'R_100',
    date_start       => $now,
    stop_loss        => 10,
    stop_profit      => 25,
    amount_per_point => 2,
    stop_type        => 'point',
};
subtest 'spread up' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $now->epoch,
        quote      => 100
    });
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $now->epoch + 1,
        quote      => 102
    });
    lives_ok {
        $params->{date_pricing} = $now->epoch + 1;
        my $c = produce_contract($params);
        cmp_ok $c->ask_price, '==', 20.00, 'correct ask price';
        cmp_ok $c->barrier->as_absolute, '==', 101, 'barrier with correct pipsize';
        ok !$c->is_expired, 'not expired';
        $params->{date_pricing} = $now->epoch + 2;
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $now->epoch + 2,
            quote      => 104
        });
        $c = produce_contract($params);
        cmp_ok $c->barrier->as_absolute, '==', 101, 'barrier with correct pipsize';
        ok $c->current_value, 'current value is defined';
        ok !$c->is_expired, 'position not expired';
        cmp_ok $c->sell_level, '==', 105, 'sell level is 105';
        cmp_ok $c->current_value->{dollar}, '==', -8, 'current value is -8';
        cmp_ok $c->current_value->{point},  '==', -4, 'current value in point is -4';
        cmp_ok $c->bid_price, '==', 12, 'bid_price is 12';
    }
    'general checks';

    lives_ok {
        $params->{date_pricing} = $now->epoch + 3;
        my $c = produce_contract($params);
        is $c->entry_tick->quote, 102, 'entry tick is 102';
        cmp_ok $c->barrier->as_absolute, '==', 101.00, 'barrier is 101.00';
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $now->epoch + 3,
            quote      => 110
        });
        is $c->current_tick->quote, 110, 'current tick is 110';
        ok $c->is_expired;
        is $c->breaching_tick->quote, 110, 'breaching tick is 110';
        is $c->breaching_tick->epoch, $now->epoch + 3, 'correct breaching tick epoch';
        cmp_ok $c->stop_loss_level, '==', 111.00, 'stop loss level is 111.00';
        cmp_ok $c->exit_level,      '==', 111.00, 'exit level is 111.00';
        cmp_ok $c->value,           '==', -20,    'value is -20';

        $params->{date_pricing} = $now->epoch + 4;
        $c = produce_contract($params);
        is $c->entry_tick->quote, 102, 'entry tick is 102';
        cmp_ok $c->barrier->as_absolute, '==', 101.00, 'barrier is 101.00';
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $now->epoch + 4,
            quote      => 111
        });
        is $c->current_tick->quote, 111, 'current tick is 110';
        ok $c->is_expired;
        # always the first hit tick
        is $c->breaching_tick->quote, 110, 'breaching tick is 110';
        is $c->breaching_tick->epoch, $now->epoch + 3, 'correct breaching tick epoch';
        cmp_ok $c->stop_loss_level, '==', 111.00, 'stop loss level is 111.00';
        cmp_ok $c->exit_level,      '==', 111.00, 'exit level is 111.00';
        cmp_ok $c->value,           '==', -20,    'value is -20';
    }
    'hit stop loss';

    lives_ok {
        $params->{date_start}   = $now->epoch + 4;
        $params->{date_pricing} = $now->epoch + 6;
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $now->epoch + 5,
            quote      => 93
        });
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $now->epoch + 6,
            quote      => 66
        });
        my $c = produce_contract($params);
        is $c->entry_tick->quote, 93, 'entry tick is 93';
        cmp_ok $c->barrier->as_absolute, '==', 92.00, 'barrier is 92.00';
        cmp_ok $c->stop_profit_level, '==', 67.00, 'stop profit level 67.00';
        ok $c->is_expired;
        is $c->breaching_tick->quote, 66, 'breaching tick is 68';
        is $c->breaching_tick->epoch, $now->epoch + 6, 'correct braching tick epoch';
        cmp_ok $c->value,      '==', 50, 'value is 50';
        cmp_ok $c->exit_level, '==', 67, 'exit level 67';

        $params->{date_pricing} = $now->epoch + 7;
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $now->epoch + 7,
            quote      => 67
        });
        $c = produce_contract($params);
        is $c->entry_tick->quote, 93, 'entry tick is 93';
        cmp_ok $c->barrier->as_absolute, '==', 92.00, 'barrier is 92.00';
        cmp_ok $c->stop_profit_level, '==', 67.00, 'stop profit level 67.00';
        ok $c->is_expired;
        # always the first hit tick
        is $c->breaching_tick->quote, 66, 'breaching tick is 66';
        is $c->breaching_tick->epoch, $now->epoch + 6, 'correct braching tick epoch';
        cmp_ok $c->value,      '==', 50, 'value is 50';
        cmp_ok $c->exit_level, '==', 67, 'exit level 67';

    }
    'hit stop profit';
};

subtest 'value and point_value checks' => sub {
    my $new_now = $now->plus_time_interval('8s');
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $new_now->epoch,
        quote      => 118.1234
    });
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $new_now->epoch + 2,
        quote      => 110.9434
    });
    my $params = {
        spread           => 2,
        bet_type         => 'SPREADD',
        currency         => 'USD',
        underlying       => 'R_100',
        date_start       => $new_now->epoch - 1,
        stop_loss        => 10,
        stop_profit      => 25,
        amount_per_point => 100,
        stop_type        => 'point',
        date_pricing     => $new_now->epoch + 2,
    };
    my $c = produce_contract($params);
    is($c->entry_tick->quote,    118.1234, 'entry tick 118.1234');
    is($c->barrier->as_absolute, 117.12,   'barrier 119.12');
    ok $c->current_value;
    is($c->value,          518.00, 'correct value');
    is($c->point_value,    5.18,   'correct point value');
    is($c->deposit_amount, 1000,   'correct deposit amount');
    is($c->ask_price,      1000,   'correct ask price');
};

subtest 'past expiry' => sub {
    $params->{stop_loss}   = 100;
    $params->{stop_profit} = 100;
    $params->{spread}      = 2;
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $now->epoch + 86400 * 365 + 1,
        quote      => 128
    });
    $params->{date_pricing} = $params->{date_start} + 86400 * 365;    # one second after expiry
    my $c = produce_contract($params);
    ok !$c->is_expired, 'not expired';
    $params->{date_pricing} = $params->{date_start} + 86400 * 365 + 1;    # one second after expiry
    $c = produce_contract($params);
    cmp_ok $c->date_pricing->epoch, ">", $c->date_expiry->epoch, "past expiry";
    cmp_ok $c->date_expiry->epoch,     '==', $c->date_start->plus_time_interval('365d')->epoch, 'expiry is 365d after start';
    cmp_ok $c->date_settlement->epoch, '==', $c->date_start->plus_time_interval('365d')->epoch, 'settlement is 365d after start';
    ok $c->is_expired, 'is expired after contract past expiry time';
    cmp_ok $c->exit_level, '==', 129, 'exit_level at expiry';
};
