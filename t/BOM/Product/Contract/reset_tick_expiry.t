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
initialize_realtime_ticks_db();

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'randomindex',
    {
        symbol => 'R_100',
        date   => Date::Utility->new
    });
my $one_day = Date::Utility->new('2014-07-10 10:00:00');

for (0 .. 5) {
    my $epoch = $one_day->epoch + $_ * 2;
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $epoch,
        quote      => 100 + $_
    });
}

subtest 'tick expiry reset' => sub {
    my $args = {
        underlying   => 'R_100',
        bet_type     => 'RESETCALL',
        date_start   => $one_day,
        date_pricing => $one_day->plus_time_interval('4s'),
        duration     => '5t',
        currency     => 'USD',
        payout       => 100,
        barrier      => 'S0P',
    };
    my $c = produce_contract($args);
    ok $c->tick_expiry, 'is tick expiry contract';
    is $c->tick_count, 5, 'number of ticks is 5';
    ok !$c->exit_tick,  'exit tick is undef when we only have 5 ticks';
    ok !$c->is_expired, 'not expired when exit tick is undef';

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $one_day->epoch + 6 * 2,
        quote      => 111
    });

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $one_day->epoch + 7 * 2,
        quote      => 112
    });

    delete $args->{date_pricing};
    my $c2 = produce_contract($args);
    ok $c2->is_expired, 'contract is expired once exit tick is obtained';
    is $c2->exit_tick->quote, 111, 'exit tick is the 6th tick after contract start time';
};

subtest 'barrier reset is correct' => sub {
    my $args = {
        underlying   => 'R_100',
        bet_type     => 'RESETPUT',
        date_start   => $one_day,
        date_pricing => $one_day->plus_time_interval('3s'),
        duration     => '5t',
        currency     => 'USD',
        payout       => 100,
        barrier      => 'S0P'
    };

    my $c = produce_contract($args);
    is $c->barrier->as_absolute, '101.00', 'prior to barrier reset 0sec';

    $args->{date_pricing} = $one_day->plus_time_interval('3s');
    $c = produce_contract($args);
    is $c->barrier->as_absolute, '101.00', 'prior to barrier reset 3secs';

    $args->{date_pricing} = $one_day->plus_time_interval('5s');
    $c = produce_contract($args);
    is $c->barrier->as_absolute, '101.00', 'prior to barrier reset 5secs';

    $args->{date_pricing} = $one_day->plus_time_interval('6s');
    $c = produce_contract($args);
    is $c->barrier->as_absolute, '101.00', 'prior to barrier reset';

    $args->{date_pricing} = $one_day->plus_time_interval('7s');
    $c = produce_contract($args);
    is $c->barrier->as_absolute, '103.00', 'prior to barrier reset';

    $args->{date_pricing} = $one_day->plus_time_interval('8s');
    $c = produce_contract($args);
    is $c->barrier->as_absolute, '103.00', 'barrier resets as expected';

    is $c->reset_time, 1404986406, 'reset time is correct';

    # Let's test even no of tick as well
    $args->{duration}     = '6t';
    $args->{date_pricing} = $one_day->plus_time_interval('3s');
    $c                    = produce_contract($args);
    is $c->barrier->as_absolute, '101.00', 'prior to barrier reset 3secs';

    $args->{date_pricing} = $one_day->plus_time_interval('5s');
    $c = produce_contract($args);
    is $c->barrier->as_absolute, '101.00', 'prior to barrier reset 5secs';

    $args->{date_pricing} = $one_day->plus_time_interval('6s');
    $c = produce_contract($args);
    is $c->barrier->as_absolute, '101.00', 'prior to barrier reset';

    $args->{date_pricing} = $one_day->plus_time_interval('7s');
    $c = produce_contract($args);
    is $c->barrier->as_absolute, '101.00', 'prior to barrier reset';

    $args->{date_pricing} = $one_day->plus_time_interval('8s');
    $c = produce_contract($args);
    is $c->barrier->as_absolute, '104.00', 'barrier resets as expected';
};

