#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 3;
use Test::Exception;
use Test::MockModule;
use JSON qw(decode_json);
use File::Spec;
use File::Slurp;

use Date::Utility;
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Platform::Runtime;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
initialize_realtime_ticks_db();

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
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

subtest 'tick expiry up&down' => sub {
    my $args = {
        underlying   => 'R_100',
        bet_type     => 'FLASHU',
        date_start   => $one_day,
        date_pricing => $one_day->plus_time_interval('4s'),
        duration     => '5t',
        currency     => 'USD',
        payout       => 100
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

my $new_day = $one_day->plus_time_interval('1d');
for (0 .. 4) {
    my $epoch = $new_day->epoch + $_ * 2;
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $epoch,
        quote      => 100 + $_
    });
}

subtest 'tick expiry digits' => sub {
    my $args = {
        underlying   => 'R_100',
        bet_type     => 'DIGITMATCH',
        date_start   => $new_day,
        date_pricing => $new_day->plus_time_interval('4s'),
        duration     => '5t',
        currency     => 'USD',
        payout       => 100,
        barrier      => 8,
    };
    my $c = produce_contract($args);
    ok $c->tick_expiry, 'is tick expiry contract';
    is $c->tick_count, 5, 'number of ticks is 5';
    ok !$c->exit_tick,  'exit tick is undef when we only have 4 ticks';
    ok !$c->is_expired, 'not expired when exit tick is undef';
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $new_day->epoch + 5 * 2,
        quote      => 111
    });
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $new_day->epoch + 6 * 2,
        quote      => 112
    });
    delete $args->{date_pricing};
    my $c2 = produce_contract($args);
    ok $c2->is_expired, 'contract is expired once exit tick is obtained';
    is $c2->exit_tick->quote,     111, 'exit tick is the 6th tick after contract start time';
    is $c2->barrier->as_absolute, 8,   'barrier is 8';
};

subtest 'asian' => sub {
    lives_ok {
        my $time = Date::Utility->new(1310631887);
        my $c = produce_contract('ASIANU_R_75_5_1310631887_2T', 'USD');
        is $c->code, 'ASIANU', 'extracted the right bet type from shortcode';
        is $c->underlying->symbol, 'R_75', 'extracted the right symbol from shortcode';
        is $c->payout, 5, 'correct payout from shortcode';
        is $c->date_start->epoch, 1310631887, 'correct start time';
        is $c->tick_count, 2, 'correct number of ticks';
        ok $c->tick_expiry, 'is a tick expiry contract';
        ok !$c->is_after_expiry, 'is not expired';
        is $c->barrier, undef, 'barrier is undef';

        # add ticks
        for (1 .. 3) {
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
                underlying => 'R_75',
                epoch      => $time->epoch + $_ * 2,
                quote      => 100 + $_,
            });
        }

        $c = produce_contract('ASIANU_R_75_5_1310631887_2T', 'USD');
        ok $c->is_after_expiry, 'is expired';
        is $c->underlying->pip_size, 0.0001, 'underlying pip size';
        cmp_ok $c->barrier->as_absolute, '==', 101.50000, 'correct barrier with one more decimal in pip size';
    }
    'build from shortcode'; 
};

subtest '2000GMT FX Blackout' => sub {
    lives_ok{
        my $time_22GMT = Date::Utility->new('2016-03-09 22:00:00');
        
        #Case 1: FX Tick expiry
        my $arg = {
        underlying   => 'frxUSDJPY',
        bet_type     => 'CALL',
        date_start   => $time_22GMT,
        date_pricing => $time_22GMT,
        duration     => '5t',
        currency     => 'USD',
        payout       => 100,
        };
        my $c = produce_contract($arg);
        ok ($c->_validate_start_date=~"Tick Expiry Blackout")
        
        #Case 2: FX Non-Tick Expiry 
        #my $arg = {
        #underlying   => 'frxUSDJPY',
        #bet_type     => 'CALL',
        #date_start   => $time_22GMT,
        #date_pricing => $time_22GMT,
        #duration     => '2m',
        #currency     => 'USD',
        #payout       => 100,
        #};
        #my $c = produce_contract($arg);
        
        #Case 3: Non-FX Tick Expiry 
        #my $arg = {
        #underlying   => 'R_100',
        #bet_type     => 'CALL',
        #date_start   => $time_22GMT,
        #date_pricing => $time_22GMT,
        #duration     => '5t',
        #currency     => 'USD',
        #payout       => 100,
        #};
        #my $c = produce_contract($arg);
        
        #Case 4: Non-FX Non-Tick Expiry
        #my $arg = {
          # underlying   => 'R_100',
          # bet_type     => 'CALL',
         #  date_start   => $time_22GMT,
        #   date_pricing => $time_22GMT,
        #   duration     => '2m',
        #   currency     => 'USD',
        #   payout       => 100,
        #   };
        #my $c = produce_contract($arg);
};
};
