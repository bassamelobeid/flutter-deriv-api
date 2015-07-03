#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 2;
use Test::Exception;
use Test::NoWarnings;

use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

use BOM::Product::ContractFactory qw(produce_contract);
use Date::Utility;

my $now = Date::Utility->new();
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('exchange', {symbol => 'RANDOM'});
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('currency', {symbol => 'USD'});
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_flat',
    {
        symbol        => 'R_100',
        recorded_date => $now
    });

subtest 'spread up' => sub {
    my $params = {
        bet_type         => 'SPREADU',
        currency         => 'USD',
        underlying       => 'R_100',
        date_start       => $now,
        stop_loss        => 10,
        stop_profit      => 25,
        amount_per_point => 2,
        stop_type        => 'point',
    };
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $now->epoch,
        quote      => 100
    });
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $now->epoch + 1,
        quote      => 101
    });
    lives_ok {
        $params->{date_pricing} = $now->epoch + 1;
        my $c = produce_contract($params);
        cmp_ok $c->ask_price, '==', 20.00, 'correct ask price';
        cmp_ok $c->barrier->as_absolute, '==', 102, 'barrier with correct pipsize';
        ok !$c->is_expired, 'not expired';
        $params->{date_pricing} = $now->epoch + 2;
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $now->epoch + 2,
            quote      => 104
        });
        $c = produce_contract($params);
        cmp_ok $c->barrier->as_absolute, '==', 102, 'barrier with correct pipsize';
        ok $c->current_value, 'current value is defined';
        ok !$c->is_expired, 'position not expired';
        cmp_ok $c->current_value, '==', 4,  'current value is positive 4';
        cmp_ok $c->bid_price,     '==', 22, 'bid_price is 22';
    }
    'general checks';

    lives_ok {
        $params->{date_pricing} = $now->epoch + 3;
        my $c = produce_contract($params);
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $now->epoch + 3,
            quote      => 92
        });
        ok $c->is_expired;
        cmp_ok $c->value, '==', -20, 'value is -20';
    }
    'hit stop loss';

    lives_ok {
        $params->{date_start}   = $now->epoch + 3;
        $params->{date_pricing} = $now->epoch + 5;
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $now->epoch + 4,
            quote      => 93
        });
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $now->epoch + 5,
            quote      => 119
        });
        my $c = produce_contract($params);
        ok $c->is_expired;
        cmp_ok $c->value, '==', 50, 'value is 50';
    }
    'hit stop profit';
};
