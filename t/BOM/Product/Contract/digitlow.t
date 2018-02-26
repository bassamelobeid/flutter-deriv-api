#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 2;
use Test::Warnings;
use Test::Exception;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

use Date::Utility;
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Product::Contract::Digitlow;

initialize_realtime_ticks_db();
my $now = Date::Utility->new('10-Mar-2015');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => 'USD',
        date   => Date::Utility->new
    });

my $args = {
    bet_type     => 'DIGITLOW',
    underlying   => 'R_100',
    selected_tick => 1,
    date_start   => $now,
    date_pricing => $now,
    duration     => '5t',
    currency     => 'USD',
    payout       => 10,
};

my $c = produce_contract($args);

subtest 'digits test it all' => sub {
    lives_ok {
        my $c = produce_contract($args);
        is $c->code,            'DIGITLOW';
        is $c->pricing_code,    'DIGITLOW';
        is $c->sentiment,       'low';
        is $c->other_side_code, 'DIGITHIGH';
        is $c->category->code, 'digits';
        is_deeply $c->supported_expiries, ['tick'];
        isa_ok $c, 'BOM::Product::Contract::Digitlow';
        is $c->pricing_engine_name, 'Pricing::Engine::Digits';
        isa_ok $c->greek_engine,    'BOM::Product::Pricing::Greeks::Digits';
        ok $c->tick_expiry;
        is $c->tick_count,      5;
        is $c->ticks_to_expiry, 5;
        is $c->selected_tick,   1;
    }
    'Ensure that contract is produced with the correct parameters';

    my $quote = 100.000;
    for (0 .. 4) {
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            quote => $quote,
            epoch      => $now->epoch + $_,
        });
        $quote += 0.002;
    }

    lives_ok {
        $args->{date_pricing} = $now->plus_time_interval('4s');
        my $c = produce_contract($args);
        ok !$c->exit_tick,  'first tick is next tick';
        ok !$c->is_expired, 'not expired';
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $now->epoch + 5,
            quote      => 100.01,
        });
        $c = produce_contract($args);
        is $c->exit_tick->quote, 100.01, 'correct exit tick';
        ok $c->is_expired, 'expired';
        cmp_ok $c->value, '==', $c->payout, 'full payout';
    }
    'check expiry';
};
