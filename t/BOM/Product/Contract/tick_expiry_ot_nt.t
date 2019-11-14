#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 3;
use Test::Warnings;
use Test::Exception;
use Test::MockModule;
use File::Spec;
use File::Slurp;

use Date::Utility;
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Config::Runtime;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

use Test::BOM::UnitTestPrice;

initialize_realtime_ticks_db();

Test::BOM::UnitTestPrice::create_pricing_data('R_100', 'USD', Date::Utility->new('2014-07-10 10:00:00'));

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'randomindex',
    {
        symbol => 'R_100',
        date   => Date::Utility->new
    });
my $one_day = Date::Utility->new('2014-07-10 10:00:00');

for (0 .. 1) {
    my $epoch = $one_day->epoch + $_ * 2;
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $epoch,
        quote      => 100 + $_
    });
}

subtest 'tick expiry one touch no touch' => sub {
    my $args = {
        underlying   => 'R_100',
        bet_type     => 'ONETOUCH',
        date_start   => $one_day,
        duration     => '5t',
        date_pricing => $one_day,
        currency     => 'USD',
        payout       => 100,
        barrier      => '+2.0'
    };

# Here we simulate proposal by using duration instead of tick_expiry and tick_count

    my $c = produce_contract($args);
    ok $c->tick_expiry, 'is tick expiry contract';
    is $c->tick_count, 5, 'number of ticks is 5';

    #Let's check the date Expiry
    is $c->date_expiry->epoch, 1404986410, 'expected date expiry';
    is $c->date_start->epoch,  1404986400, 'expected date start';

    # Here we simulate the proposal open contract by using tick_expiry and tick_count
    $args->{date_pricing} = $one_day->plus_time_interval('2s');
    $args->{barrier}      = '+1.0';
    $c                    = produce_contract($args);
    ok !$c->is_expired, 'We are at the same second as the entry tick';

    #Let's check the date Expiry
    is $c->date_expiry->epoch, 1404986410, 'expected date expiry';
    is $c->date_start->epoch,  1404986400, 'expected date start';
    is $c->entry_tick->quote,  101,        'correct entry tick';

    my %expected_bid_price = (
        2 => 42.24,
        3 => 32.91,
        4 => 16.86,
        5 => 53.94,
    );

    for (2 .. 5) {

        my $index = $_;

        $args->{barrier}      = '+' . $index . '.0';
        $args->{date_pricing} = $one_day->plus_time_interval(($index * 2) . 's');

        # Before next tick is available
        $c = produce_contract($args);
        ok !$c->is_expired, 'contract did not touch barrier';
        ok !$c->hit_tick,   'no hit tick';
        is $c->current_tick->quote, 101 + ($index - 2) + 1, 'correct current tick' if $index > 2;
        is $c->current_tick->quote, 101, 'correct current tick' if $index == 2;

        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $one_day->epoch + $index * 2,
            quote      => 101 + $index
        });

        # After tick become available, hit the barrier test.
        $c = produce_contract($args);
        ok $c->is_expired, 'contract is expired once it touch the barrier';

        ok $c->hit_tick, 'hit tick';
        cmp_ok $c->hit_tick->quote, '==', 101 + $index;
        is $c->current_tick->quote, 101 + $index, 'correct current tick';
        # Check hit tick against barrier
        ok $c->hit_tick->quote == $c->barrier->as_absolute;

        is $c->date_expiry->epoch, 1404986410, 'checking date expiry';
        cmp_ok $c->bid_price, '==', 100, 'checking bid price, and should be equal to payout';

        is $c->is_valid_to_sell, 1, 'is_valid_to_sell';

        # No barrier hit test case
        $args->{barrier} = '+' . ($index + 0.02);
        $c = produce_contract($args);
        ok !$c->is_expired, 'contract did not touch barrier';
        ok !$c->hit_tick,   'no hit tick';
        is $c->current_tick->quote, 101 + $index, 'correct current tick';
        ok $c->current_tick->quote < $c->barrier->as_absolute;

        is $c->date_expiry->epoch, 1404986410, 'checking date expiry';
        is $c->bid_price, $expected_bid_price{$index}, 'checking bid price';
    }

    #Here we are at right before the last tick
    $args->{barrier}      = '+7.0';
    $args->{date_pricing} = $one_day->plus_time_interval('12s');

    $c = produce_contract($args);
    ok !$c->is_expired, 'contract did not touch barrier and not expired, this is right before our last tick';
    ok !$c->hit_tick,   'no hit tick';
    is $c->current_tick->quote, 106, 'correct current tick';

    # And here is the last tick
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $one_day->epoch + 6 * 2,
        quote      => 108
    });

    is $c->date_expiry->epoch, 1404986410, 'checking date expiry';

    $c = produce_contract($args);
    ok $c->is_expired, 'Here is the last one, 5th tick after entry tick';
    ok $c->hit_tick,   'hit tick';
    ok $c->exit_tick,  'exit tick';
    cmp_ok $c->exit_tick->quote, '==', 108;
    cmp_ok $c->hit_tick->quote,  '==', 108;
    is $c->current_tick->quote,  108,  'correct current tick';

    is $c->date_expiry->epoch, 1404986412, 'checking date expiry --';

    cmp_ok $c->bid_price, '==', 100.00, 'Correct bid price at expiry';

    is $c->is_valid_to_sell, 1, 'is_valid_to_sell';

    $args->{barrier} = '-1.0';
    $c = produce_contract($args);
    ok $c->is_expired, 'Here is the last one, 5th tick after entry tick';
    ok !$c->hit_tick, 'no hit tick';
    is $c->current_tick->quote, 108, 'correct current tick';

    cmp_ok $c->bid_price, '==', 0, 'Correct bid price at expiry in case of no hit';

    is $c->is_valid_to_sell, 1, 'is_valid_to_sell';

# Let check the hit tick is correct when backprice
    $args->{barrier} = '+2.0';

    $c = produce_contract($args);

    ok $c->hit_tick, 'hit tick';
    cmp_ok $c->hit_tick->quote, '==', 103;
};

subtest 'tick expiry touchnotouch settlement conditions' => sub {
    my $now  = Date::Utility->new;
    my $args = {
        underlying => 'R_100',
        bet_type   => 'ONETOUCH',
        date_start => $now,
        duration   => '5t',
        currency   => 'USD',
        payout     => 100,
        barrier    => '+2.0'
    };

    my @test_data = (
        [[[$now->epoch + 2, 100], [$now->epoch + 4, 102]], 1, 'expired on first tick'],
        [[(map { [$now->epoch + $_, 100] } (2, 4)), [$now->epoch + 6, 102]], 1, 'expired on second tick'],
        [[(map { [$now->epoch + $_, 100] } (2, 4, 6)), [$now->epoch + 8, 102]], 1, 'expired on fourth tick'],
        [[(map { [$now->epoch + $_, 100] } (2, 4, 6, 8, 10))], 0, 'expired worthless'],
    );
    foreach my $d (@test_data) {
        BOM::Test::Data::Utility::FeedTestDatabase->instance->truncate_tables;
        my $ticks           = $d->[0];
        my $expected_output = $d->[1];
        my $test_comment    = $d->[2];
        note($test_comment);
        my $date_pricing;
        foreach my $t (@$ticks) {
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
                underlying => $args->{underlying},
                epoch      => $t->[0],
                quote      => $t->[1],
            });
            $date_pricing = $t->[0];
        }
        $args->{date_pricing} = $date_pricing;
        my $c = produce_contract($args);
        is $c->is_expired, $expected_output, $test_comment;
        if ($expected_output) {
            is $c->barrier->as_absolute, '102.00', 'barrier 102.00';
            ok $c->hit_tick, 'has hit tick';
            is $c->hit_tick->quote, '102', 'hit tick 102.00';
            is $c->hit_tick->epoch, $date_pricing, 'hit time ' . $date_pricing;
        }
    }
};

