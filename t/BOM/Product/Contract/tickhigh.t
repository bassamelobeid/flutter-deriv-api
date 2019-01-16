#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 6;
use Test::Warnings;
use Test::Exception;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

use Date::Utility;
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Product::Contract::Tickhigh;

initialize_realtime_ticks_db();
my $now = Date::Utility->new('10-Mar-2015');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => 'USD',
        date   => Date::Utility->new
    });
my $args = {
    bet_type      => 'TICKHIGH',
    underlying    => 'R_100',
    selected_tick => 5,
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
        is $c->code,         'TICKHIGH';
        is $c->pricing_code, 'TICKHIGH';
        is $c->sentiment,    'high';
        is $c->category->code, 'highlowticks';
        is_deeply $c->supported_expiries, ['tick'];
        isa_ok $c, 'BOM::Product::Contract::Tickhigh';
        is $c->pricing_engine_name, 'Pricing::Engine::HighLow::Ticks';
        isa_ok $c->greek_engine,    'BOM::Product::Pricing::Greeks::ZeroGreek';
        ok $c->tick_expiry;
        is $c->tick_count,      5;
        is $c->ticks_to_expiry, 5;
        is $c->selected_tick,   5;
    }
    'Ensure that contract is produced with the correct parameters';
};

subtest 'Test for condition where last tick is the highest' => sub {

    my $quote = 100.000;
    for my $i (0 .. 4) {
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            quote      => $quote,
            epoch      => $now->epoch + $i,
        });
        $quote += 0.01;

        lives_ok {
            $args->{date_pricing} = $now->plus_time_interval($i . 's');
            my $c = produce_contract($args);
            ok !$c->exit_tick,  'first tick is next tick';
            ok !$c->is_expired, 'not expired';
            cmp_ok $c->value, '==', 0, 'full payout';
        }
        'check that ticks before expiry are created properly';
    }

    lives_ok {
        $args->{date_pricing} = $now->plus_time_interval('5s');
        my $c = produce_contract($args);
        ok !$c->exit_tick, 'first tick is next tick';
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $now->epoch + 5,
            quote      => 100.1,
        });

        $c = produce_contract({%$args, selected_tick => 5});
        is $c->exit_tick->quote,     100.1,    'correct exit tick';
        is $c->barrier->as_absolute, '100.10', 'correct barrier';
        ok $c->is_expired, 'expired';
        cmp_ok $c->value, '==', $c->payout, 'full payout';
    }
    'check that last tick is the winning tick';
};

subtest 'Test for condition where first tick is the highest' => sub {

    $now                  = Date::Utility->new('11-Mar-2015');
    $args->{date_start}   = $now;
    $args->{date_pricing} = $now;

    my $quote = 100.1;
    for my $i (0 .. 4) {
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            quote      => $quote,
            epoch      => $now->epoch + $i,
        });
        $quote -= 0.01;

        if ($i < 4) {
            lives_ok {
                $args->{date_pricing} = $now->plus_time_interval($i . 's');
                my $c = produce_contract($args);
                ok !$c->exit_tick,  'first tick is next tick';
                ok !$c->is_expired, 'not expired';
                $c = produce_contract($args);
                cmp_ok $c->value, '==', 0, 'full payout';
            }
            'check ticks before expiry';
        }
    }

    lives_ok {
        $args->{date_pricing} = $now->plus_time_interval('4s');
        my $c = produce_contract($args);
        ok !$c->exit_tick, 'first tick is next tick';
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $now->epoch + 5,
            quote      => 100.00,
        });
        $c = produce_contract({%$args, selected_tick => 1});
        is $c->exit_tick->quote, 100.00, 'correct exit tick';
        ok $c->is_expired, 'expired';
        cmp_ok $c->value, '==', $c->payout, 'full payout';
    }
    'check that first tick is the winning tick';

    lives_ok {
        $args->{date_pricing} = $now->plus_time_interval('4s');
        $c = produce_contract({%$args, selected_tick => 2});
        is $c->exit_tick->quote, 100.00, 'correct exit tick';
        ok $c->is_expired, 'expired';
        cmp_ok $c->value, '==', 0, 'payout is 0 as contract is lost';
    }
    'second tick is losing tick';

    lives_ok {
        $args->{date_pricing} = $now->plus_time_interval('4s');
        $c = produce_contract({%$args, selected_tick => 3});
        is $c->exit_tick->quote, 100.00, 'correct exit tick';
        ok $c->is_expired, 'expired';
        cmp_ok $c->value, '==', 0, 'payout is 0 as contract is lost';
    }
    'third tick is losing tick';

    lives_ok {
        $args->{date_pricing} = $now->plus_time_interval('4s');
        $c = produce_contract({%$args, selected_tick => 4});
        is $c->exit_tick->quote, 100.00, 'correct exit tick';
        ok $c->is_expired, 'expired';
        cmp_ok $c->value, '==', 0, 'payout is 0 as contract is lost';
    }
    'fourth tick is losing tick';

    lives_ok {
        $args->{date_pricing} = $now->plus_time_interval('4s');
        $c = produce_contract({%$args, selected_tick => 5});
        is $c->exit_tick->quote, 100.00, 'correct exit tick';
        ok $c->is_expired, 'expired';
        cmp_ok $c->value, '==', 0, 'payout is 0 as contract is lost';
    }
    'last tick is losing tick';
};

subtest 'Test for condition with two winning ticks' => sub {

    $now                   = Date::Utility->new('12-Mar-2015');
    $args->{date_start}    = $now;
    $args->{date_pricing}  = $now;
    $args->{selected_tick} = 1;

    my @quotes = (102.2, 102.4, 102.5, 102.5, 102.5, 102.4);

    # Insert ticks
    foreach my $i (0 .. $#quotes) {
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            quote      => $quotes[$i],
            epoch      => $now->epoch + $i,
        });
    }

    lives_ok {
        $args->{date_pricing} = $now->plus_time_interval('5s');
        my $c = produce_contract($args);
        ok $c->exit_tick, 'reached exit tick';
        $c = produce_contract($args);
        is $c->exit_tick->quote, 102.4, 'correct exit tick';
        cmp_ok $c->value, '==', 0, 'payout is 0 as contract is lost';
    }
    'check first tick';

    lives_ok {
        $args->{date_pricing} = $now->plus_time_interval('5s');
        $c = produce_contract({%$args, selected_tick => 2});
        is $c->exit_tick->quote, 102.4, 'correct exit tick';
        ok $c->is_expired, 'expired';
        cmp_ok $c->value, '==', $c->payout, 'full payout';
    }
    'check second tick';

    lives_ok {
        $args->{date_pricing} = $now->plus_time_interval('5s');
        $c = produce_contract({%$args, selected_tick => 3});
        is $c->exit_tick->quote, 102.4, 'correct exit tick';
        ok $c->is_expired, 'expired';
        cmp_ok $c->value, '==', $c->payout, 'payout is 0 as contract is lost';
    }
    'check third tick';

    lives_ok {
        $args->{date_pricing} = $now->plus_time_interval('5s');
        $c = produce_contract({%$args, selected_tick => 4});
        is $c->exit_tick->quote, 102.4, 'correct exit tick';
        ok $c->is_expired, 'expired';
        cmp_ok $c->value, '==', $c->payout, 'full payout';
    }
    'check fourth tick';

    lives_ok {
        $args->{date_pricing} = $now->plus_time_interval('5s');
        $c = produce_contract({%$args, selected_tick => 5});
        is $c->exit_tick->quote, 102.4, 'correct exit tick';
        ok $c->is_expired, 'expired';
        cmp_ok $c->value, '==', 0, 'payout is 0 as contract is lost';
    }
    'check fifth tick';
};

subtest 'Where the second tick is higher than the selected first tick, the contract is lost' => sub {
    $now                   = Date::Utility->new('13-Mar-2015');
    $args->{date_start}    = $now;
    $args->{date_pricing}  = $now;
    $args->{selected_tick} = 1;

    my @quotes = (102.23, 102.12, 102.25);

    foreach my $i (0 .. $#quotes) {
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            quote      => $quotes[$i],
            epoch      => $now->epoch + $i,
        });
    }

    lives_ok {
        $args->{date_pricing} = $now->plus_time_interval('0s');
        my $c = produce_contract($args);
        ok !$c->exit_tick, 'first tick is next tick';
        $c = produce_contract({%$args, selected_tick => 1});
        cmp_ok $c->value, '==', 0, 'full payout';
    }
    'check first tick';

    lives_ok {
        $args->{date_pricing} = $now->plus_time_interval('1s');
        my $c = produce_contract({%$args, selected_tick => 1});
        ok !$c->exit_tick, 'first tick is next tick';
        $c = produce_contract({%$args, selected_tick => 1});
        cmp_ok $c->value, '==', 0, 'full payout';
    }
    'check second tick';
};
