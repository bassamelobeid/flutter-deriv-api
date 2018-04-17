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

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $one_day->epoch + 2 * 2,
        quote      => 103
    });

    $args->{date_pricing} = $one_day->plus_time_interval('4s');
    $c = produce_contract($args);
    ok $c->is_expired, 'contract is expired once it touch the barrier';



    $args->{barrier} = '-1.0';

    $c = produce_contract($args);
    ok !$c->is_expired, 'contract did not touch barrier';

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $one_day->epoch + 3 * 2,
        quote      => 104
    });

    $args->{barrier} = '+3.0';
    $args->{date_pricing} = $one_day->plus_time_interval('6s');
    $c = produce_contract($args);
    ok $c->is_expired, 'contract is expired once it touch the barrier';

    $args->{barrier} = '-1.0';

    $c = produce_contract($args);
    ok !$c->is_expired, 'contract did not touch barrier';

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $one_day->epoch + 4 * 2,
        quote      => 105
    });

    $args->{barrier} = '+4.0';
    $args->{date_pricing} = $one_day->plus_time_interval('8s');
    $c = produce_contract($args);
    ok $c->is_expired, 'contract is expired once it touch the barrier';

    $args->{barrier} = '-1.0';

    $c = produce_contract($args);
    ok !$c->is_expired, 'contract did not touch barrier';

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $one_day->epoch + 5 * 2,
        quote      => 106
    });

    $args->{barrier} = '+4.0';
    $args->{date_pricing} = $one_day->plus_time_interval('10s');
    $c = produce_contract($args);
    ok $c->is_expired, 'contract is expired once it touch the barrier';

    $args->{barrier} = '-1.0';

    $c = produce_contract($args);
    ok !$c->is_expired, 'contract did not touch barrier';

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $one_day->epoch + 6 * 2,
        quote      => 107
    });

    $args->{barrier} = '+5.0';
    $args->{date_pricing} = $one_day->plus_time_interval('12s');
    $c = produce_contract($args);
    ok $c->is_expired, 'Here is the last one, 5th tick after entry tick';

    $args->{barrier} = '-1.0';

    $c = produce_contract($args);
    ok $c->is_expired, 'Here is the last one, 5th tick after entry tick';    
};




