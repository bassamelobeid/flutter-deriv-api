#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 5;
use Test::Warnings;
use Test::Exception;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

use Date::Utility;
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Product::Contract::Ticklow;

initialize_realtime_ticks_db();
my $now = Date::Utility->new('10-Mar-2015');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => 'USD',
        date   => Date::Utility->new
    });
my $args = {
    bet_type      => 'TICKLOW',
    underlying    => 'R_100',
    selected_tick => 1,
    date_start    => $now,
    date_pricing  => $now,
    duration      => '5t',
    currency      => 'USD',
    payout        => 10,
};

my $c = produce_contract($args);

subtest 'Test that contract can be created correctly' => sub {
    lives_ok {
        my $c = produce_contract($args);
        is $c->code,            'TICKLOW';
        is $c->pricing_code,    'TICKLOW';
        is $c->sentiment,       'low';
        is $c->other_side_code, 'TICKHIGH';
        is $c->category->code, 'highlowticks';
        is_deeply $c->supported_expiries, ['tick'];
        isa_ok $c, 'BOM::Product::Contract::Ticklow';
        is $c->pricing_engine_name, 'Pricing::Engine::HighLowTicks';
        isa_ok $c->greek_engine,    'BOM::Product::Pricing::Greeks::Digits';
        ok $c->tick_expiry;
        is $c->tick_count,      5;
        is $c->ticks_to_expiry, 5;
        is $c->selected_tick,   1;
    }
    'Ensure that contract is produced with the correct parameters';
};

subtest 'Test that when the selected tick reflects the lowest tick, a payout is given' => sub {

    my $quote = 100.000;
    for (0 .. 4) {
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            quote      => $quote,
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

subtest 'Test that when any one of the minimum ticks is selected, a payout is given' => sub {

    $now                   = Date::Utility->new('11-Mar-2015');
    $args->{date_start}    = $now;
    $args->{date_pricing}  = $now;
    $args->{selected_tick} = 1;

    # Five ticks of the same size, so all of these are the lowest, and hence, winning ticks
    my $quote = 100.000;
    for (0 .. 4) {
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            quote      => $quote,
            epoch      => $now->epoch + $_,
        });
    }

    lives_ok {
        $args->{date_pricing} = $now->plus_time_interval('4s');
        my $c = produce_contract({%$args, selected_tick => 1});
        ok !$c->exit_tick,  'first tick is next tick';
        ok !$c->is_expired, 'not expired';
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $now->epoch + 5,
            quote      => 100.00,
        });
        $c = produce_contract({%$args, selected_tick => 1});
        is $c->exit_tick->quote, 100.00, 'correct exit tick';
        ok $c->is_expired, 'expired';
        cmp_ok $c->value, '==', $c->payout, 'full payout';

        $c = produce_contract({%$args, selected_tick => 2});
        is $c->exit_tick->quote, 100.00, 'correct exit tick';
        ok $c->is_expired, 'expired';
        cmp_ok $c->value, '==', $c->payout, 'full payout';

        $c = produce_contract({%$args, selected_tick => 3});
        is $c->exit_tick->quote, 100.00, 'correct exit tick';
        ok $c->is_expired, 'expired';
        cmp_ok $c->value, '==', $c->payout, 'full payout';

        $c = produce_contract({%$args, selected_tick => 4});
        is $c->exit_tick->quote, 100.00, 'correct exit tick';
        ok $c->is_expired, 'expired';
        cmp_ok $c->value, '==', $c->payout, 'full payout';

        $c = produce_contract({%$args, selected_tick => 5});
        is $c->exit_tick->quote, 100.00, 'correct exit tick';
        ok $c->is_expired, 'expired';
        cmp_ok $c->value, '==', $c->payout, 'full payout';
    }
    'check expiry';
};

subtest 'Test that when the selected tick reflects the highest tick, no payout is given' => sub {

    $now                   = Date::Utility->new('11-Mar-2015');
    $args->{date_start}    = $now;
    $args->{date_pricing}  = $now;
    $args->{selected_tick} = 5;

    my $quote = 100.000;
    for (0 .. 4) {
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            quote      => $quote,
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
        is $c->value, 0, 'payout is 0 as contract is lost';
    }
    'check expiry';
};
