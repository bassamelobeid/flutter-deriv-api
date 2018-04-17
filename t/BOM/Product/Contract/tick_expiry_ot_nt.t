#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 2;
use Test::Warnings;
use Test::Exception;
use Test::MockModule;
use File::Spec;
use File::Slurp;

use Date::Utility;
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Platform::Runtime;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
initialize_realtime_ticks_db();

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
        date_pricing => $one_day->plus_time_interval('2s'),
        duration     => '5t',
        currency     => 'USD',
        payout       => 100,
        barrier      => '+2.0'
    };
    my $c = produce_contract($args);
    ok $c->tick_expiry, 'is tick expiry contract';
    is $c->tick_count, 5, 'number of ticks is 5';

    ok !$c->is_expired, 'We are at the same second as the entry tick';

    $args->{barrier} = '+1.0';
    $c = produce_contract($args);
    ok !$c->is_expired, 'We are at the same second as the entry tick';

    for (2 .. 5) {

        my $index = $_;

        $args->{barrier} = '+' . $index . '.0';
        $args->{date_pricing} = $one_day->plus_time_interval(($index * 2) . 's');

        # Before next tick is available
        $c = produce_contract($args);
        ok !$c->is_expired, 'contract did not touch barrier';
        ok !$c->hit_tick,   'no hit tick';
        is $c->current_tick->quote, 101 + ($index - 2) + 1, 'correct current tick' if $index > 2;
        is $c->current_tick->quote, 101 , 'correct current tick' if $index == 2;

        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_100',
            epoch      => $one_day->epoch + $index * 2,
            quote      => 101 + $index
        });

        # After tick become available, hit the barrier test.
        $c = produce_contract($args);
        ok $c->is_expired, 'contract is expired once it touch the barrier';
        ok $c->hit_tick,   'hit tick';
        cmp_ok $c->hit_tick->quote, '==', 101 + $index;
        is $c->current_tick->quote, 101 + $index, 'correct current tick';    
        # Check hit tick against barrier    
        ok $c->hit_tick->quote == $c->barrier->as_absolute;

        # No barrier hit test case
        $args->{barrier} = '-1.0';
        $c = produce_contract($args);
        ok !$c->is_expired, 'contract did not touch barrier';
        ok !$c->hit_tick,   'no hit tick';
        is $c->current_tick->quote, 101 + $index, 'correct current tick';
        ok $c->current_tick->quote > $c->barrier->as_absolute;
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

    $c                    = produce_contract($args);
    ok $c->is_expired, 'Here is the last one, 5th tick after entry tick';
    ok $c->hit_tick,   'hit tick';
    cmp_ok $c->hit_tick->quote, '==', 108;    
    is $c->current_tick->quote, 108, 'correct current tick';

    $args->{barrier} = '-1.0';
    $c = produce_contract($args);
    ok $c->is_expired, 'Here is the last one, 5th tick after entry tick';
    ok !$c->hit_tick,   'no hit tick';
    is $c->current_tick->quote, 108, 'correct current tick';
};

