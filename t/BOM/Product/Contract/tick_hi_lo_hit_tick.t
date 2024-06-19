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
use BOM::Config::Runtime;

use BOM::Test::Data::Utility::FeedTestDatabase   qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis      qw(initialize_realtime_ticks_db);

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

subtest 'tick highlow hit tick' => sub {
    my $args = {
        underlying    => 'R_100',
        bet_type      => 'TICKHIGH',
        date_start    => $one_day,
        duration      => '5t',
        date_pricing  => $one_day,
        currency      => 'USD',
        payout        => 100,
        selected_tick => 3,
    };

# First case is where we have max after the selected tick

    my $c = produce_contract($args);
    ok $c->tick_expiry, 'is tick expiry contract';
    is $c->tick_count, 5, 'number of ticks is 5';

# Here we simulate the proposal open contract by using tick_expiry and tick_count
    $args->{date_pricing} = $one_day->plus_time_interval('2s');

    $c = produce_contract($args);
    ok $c->tick_expiry, 'is tick expiry contract';
    is $c->tick_count, 5, 'number of ticks is 5';
    ok !$c->is_expired, 'We are at the same second as the entry tick';

    my $index = 2;

    $args->{date_pricing} = $one_day->plus_time_interval(($index * 2) . 's');

    # Before next tick is available
    $c = produce_contract($args);
    ok !$c->is_expired, 'contract did not expired';
    ok !$c->hit_tick,   'no hit tick';
    is $c->current_tick->quote, 101 + ($index - 2) + 1, 'correct current tick' if $index > 2;
    is $c->current_tick->quote, 101,                    'correct current tick' if $index == 2;

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $one_day->epoch + $index * 2,
        quote      => 101 + $index
    });

    # After tick become available, hit the barrier test.
    $c = produce_contract($args);
    ok !$c->is_expired, 'contract not yet expired';

    ok !$c->hit_tick, 'no hit tick yet';

    $index = 3;

    $args->{date_pricing} = $one_day->plus_time_interval(($index * 2) . 's');

    # Before next tick is available
    $c = produce_contract($args);
    ok !$c->is_expired, 'contract did not expired';
    ok !$c->hit_tick,   'no hit tick';
    is $c->current_tick->quote, 101 + ($index - 2) + 1, 'correct current tick' if $index > 2;
    is $c->current_tick->quote, 101,                    'correct current tick' if $index == 2;

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $one_day->epoch + $index * 2,
        quote      => 101 + $index
    });

    # After tick become available, hit the barrier test.
    $c = produce_contract($args);
    ok !$c->is_expired, 'contract not yet expired';

    ok !$c->hit_tick, 'no hit tick yet';

    $index = 4;

    $args->{date_pricing} = $one_day->plus_time_interval(($index * 2) . 's');

    # Before next tick is available
    $c = produce_contract($args);
    ok !$c->is_expired, 'contract did not expired';
    ok !$c->hit_tick,   'no hit tick';
    is $c->current_tick->quote, 101 + ($index - 2) + 1, 'correct current tick' if $index > 2;
    is $c->current_tick->quote, 101,                    'correct current tick' if $index == 2;

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $one_day->epoch + $index * 2,
        quote      => 101 + $index
    });

    # After tick become available, hit the barrier test.
    $c = produce_contract($args);
    ok $c->is_expired, 'contract expired';

    ok $c->hit_tick, 'now we have a hit tick';

# Next case is where we have max before the selected tick
    $args->{date_start}   = $one_day->plus_time_interval('4s');
    $args->{date_pricing} = $one_day->plus_time_interval(($index * 2) . 's');

    # Before next tick is available
    $index = 5;
    $c     = produce_contract($args);
    ok !$c->is_expired, 'contract did not expired';
    ok !$c->hit_tick,   'no hit tick';

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $one_day->epoch + $index * 2,
        quote      => 90
    });

    $c = produce_contract($args);
    ok $c->is_expired, 'contract expired';
    ok $c->hit_tick,   'we have hit tick';

};

