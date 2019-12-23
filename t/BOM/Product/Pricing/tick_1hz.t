#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;

use BOM::Product::ContractFactory qw(produce_contract);
use Date::Utility;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

my $now = Date::Utility->new('2019-12-18');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc('currency', {recorded_date => $now, symbol => 'USD'});
BOM::Test::Data::Utility::UnitTestMarketData::create_doc('index', {recorded_date => $now, symbol => $_}) for qw(1HZ100V 1HZ10V R_100);
my $tick =BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => '1HZ10V',
    epoch => $now->epoch,
    quote => 100
    });

subtest 'tick expiry for 1HZ' => sub {
    my $args = {
        underlying => '1HZ10V',
        bet_type => 'CALL',
        duration => '5t',
        amount => 10,
        amount_type => 'payout',
        currency => 'USD',
        barrier => 'S0P',
        current_tick => $tick,
    };
    my $c = produce_contract($args);
    ok $c->underlying->generation_interval->seconds == 1, 'generation_interval is 1';
    ok $c->timeinyears->amount * 86400 * 365 == 5, 'correct contract duration';
    is $c->theo_probability->amount, 0.499992057416873, 'correct theo';

    $args->{underlying} = '1HZ100V';
    $c = produce_contract($args);
    ok $c->underlying->generation_interval->seconds == 1, 'generation_interval is 1';
    ok $c->timeinyears->amount * 86400 * 365 == 5, 'correct contract duration';
    is $c->theo_probability->amount, 0.499920574169252, 'correct theo';

    $args->{underlying} = 'R_100';
    $c = produce_contract($args);
    ok $c->underlying->generation_interval->seconds == 2, 'generation_interval is 2';
    ok $c->timeinyears->amount * 86400 * 365 == 10, 'correct contract duration';
    is $c->theo_probability->amount, 0.499887674913696, 'correct theo';
};

done_testing();
