#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 3;
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
        is $c->code,            'TICKHIGH';
        is $c->pricing_code,    'TICKHIGH';
        is $c->sentiment,       'high';
        is $c->other_side_code, 'TICKLOW';
        is $c->category->code, 'highlowticks';
        is_deeply $c->supported_expiries, ['tick'];
        isa_ok $c, 'BOM::Product::Contract::Tickhigh';
        is $c->pricing_engine_name, 'Pricing::Engine::HighLowTicks';
        isa_ok $c->greek_engine,    'BOM::Product::Pricing::Greeks::Digits';
        ok $c->tick_expiry;
        is $c->tick_count,      5;
        is $c->ticks_to_expiry, 5;
        is $c->selected_tick,   5;
    }
    'Ensure that contract is produced with the correct parameters';
};

subtest 'Test that when the selected tick reflects the highest tick, a payout is given' => sub {

    my $quote = 100.000;
    for my $i (0 .. 4) {
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            quote      => $quote,
            epoch      => $now->epoch + $i,
        });
        $quote += 0.002;

        if ($i < 4) {
            lives_ok {
                $args->{date_pricing} = $now->plus_time_interval($i . 's');
                my $c = produce_contract($args);
                ok !$c->exit_tick,  'first tick is next tick';
                ok !$c->is_expired, 'not expired';
                $c = produce_contract($args);
                #is $c->exit_tick->quote, 100.01, 'correct exit tick';
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
            quote      => 100.01,
        });
        $c = produce_contract($args);
        is $c->exit_tick->quote, 100.01, 'correct exit tick';
        ok $c->is_expired, 'expired';
        cmp_ok $c->value, '==', $c->payout, 'full payout';
    }
    'check expiry';
};

=head2

subtest 'Test that when any one of the maximum ticks is selected, a payout is given' => sub {

    $now                   = Date::Utility->new('11-Mar-2015');
    $args->{date_start}    = $now;
    $args->{date_pricing}  = $now;
    $args->{selected_tick} = 1;

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

subtest 'Test that when the selected tick reflects the lowest tick, no payout is given' => sub {

    $now                   = Date::Utility->new('12-Mar-2015');
    $args->{date_start}    = $now;
    $args->{date_pricing}  = $now;
    $args->{selected_tick} = 1;

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
        my $c = produce_contract({%$args, selected_tick => 1});
        ok !$c->exit_tick,  'first tick is next tick';
        ok !$c->is_expired, 'not expired';
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $now->epoch + 5,
            quote      => 100.01,
        });
        $c = produce_contract({%$args, selected_tick => 1});
        is $c->exit_tick->quote, 100.01, 'correct exit tick';
        ok $c->is_expired, 'expired';
        is $c->value, 0, 'payout is 0 as contract is lost';
    }
    'check expiry';
};

=cut
