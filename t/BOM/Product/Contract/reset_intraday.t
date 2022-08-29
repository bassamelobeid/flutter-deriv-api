#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 4;
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
initialize_realtime_ticks_db();

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'randomindex',
    {
        symbol => 'R_100',
        date   => Date::Utility->new
    });
my $one_day = Date::Utility->new('2014-07-10 10:00:00');

for (0 .. 10) {
    my $epoch = $one_day->epoch + $_ * 60;
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $epoch,
        quote      => 100 + $_
    });
}

subtest 'intraday reset' => sub {
    my $args = {
        underlying   => 'R_100',
        bet_type     => 'RESETCALL',
        date_start   => $one_day,
        date_pricing => $one_day->plus_time_interval('4s'),
        duration     => '5m',
        currency     => 'USD',
        payout       => 100,
        barrier      => 'S0P',
    };
    my $c = produce_contract($args);
    ok $c->is_intraday, 'is tick expiry contract';

    ok !$c->exit_tick,  'exit tick is undef';
    ok !$c->is_expired, 'not expired yet';

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $one_day->epoch + 60 * 11,
        quote      => 111
    });

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $one_day->epoch + 60 * 12,
        quote      => 112
    });

    delete $args->{date_pricing};
    my $c2 = produce_contract($args);
    ok $c2->is_expired, 'contract is expired once exit tick is obtained';
    is $c2->exit_tick->quote,     105,      'exit tick is correct';
    is $c2->barrier->as_absolute, '101.00', 'barrier is correct';
};

subtest 'intraday barrier reset is correct' => sub {
    my $args = {
        underlying   => 'R_100',
        bet_type     => 'RESETPUT',
        date_start   => $one_day,
        date_pricing => $one_day->plus_time_interval('4s'),
        duration     => '5m',
        currency     => 'USD',
        payout       => 100,
        barrier      => 'S0P',
    };
    my $c = produce_contract($args);

    is $c->reset_time, 1404986580, 'reset time is correct';

    $args->{date_pricing} = $one_day->plus_time_interval('149s');
    $c = produce_contract($args);
    is $c->barrier->as_absolute, '101.00', 'prior to barrier reset.';

    $args->{date_pricing} = $one_day->plus_time_interval('150s');
    $c = produce_contract($args);
    is $c->barrier->as_absolute, '101.00', 'prior to barrier reset.';

    $args->{date_pricing} = $one_day->plus_time_interval('200s');
    $c = produce_contract($args);
    is $c->barrier->as_absolute, '103.00', 'barrier reset works as expected.';
};

subtest 'validation' => sub {
    my $args = {
        underlying   => 'R_100',
        bet_type     => 'RESETPUT',
        date_start   => $one_day,
        date_pricing => $one_day,
        duration     => '5m',
        currency     => 'USD',
        payout       => 100,
        barrier      => 'S20P',
    };

    my $c = produce_contract($args);

    ok !$c->is_valid_to_buy, 'not valid to buy';
    is $c->primary_validation_error->message, 'Non atm barrier for reset contract is not allowed.', 'error message checked';

    my $args_fixed_expiry = {
        underlying   => 'R_100',
        bet_type     => 'RESETPUT',
        date_start   => $one_day,
        date_pricing => $one_day,
        fixed_expiry => 1,
        date_expiry  => $one_day->plus_time_interval('5m'),
        currency     => 'USD',
        payout       => 100,
        barrier      => 'S0P',
    };

    $c = produce_contract($args_fixed_expiry);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    is $c->primary_validation_error->message, 'Fixed expiry for reset contract is not allowed.', 'error message checked';
};
