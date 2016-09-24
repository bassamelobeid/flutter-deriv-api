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
initialize_realtime_ticks_db();

subtest 'inefficient period' => sub {
    my $now = Date::Utility->new('2016-09-19 19:59:59');
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            symbol        => 'frxUSDJPY',
            recorded_date => $now
        });
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc('currency', {symbol => $_, recorded_date => $now}) for qw(USD JPY JPY-USD);
    my $fake = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxAUDUSD',
        epoch      => $now->epoch
    });
    my $bet_params = {
        bet_type     => 'CALL',
        underlying   => 'frxUSDJPY',
        q_rate       => 0,
        r_rate       => 0,
        barrier      => 'S0P',
        currency     => 'USD',
        payout       => 10,
        current_tick => $fake,
        date_pricing => $now,
        date_start   => $now,
        duration     => '2m',
    };
    note('price at 2016-09-19 19:59:59');
    my $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy';
    $bet_params->{date_start} = $bet_params->{date_pricing} = $now->plus_time_interval('1s');
    note('price at 2016-09-19 20:00:00');
    $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'valid to buy';
    like($c->primary_validation_error->message_to_client, qr/Trading is temporarily suspended/, 'throws error');
    $bet_params->{underlying} = 'R_100';
    note('set underlying to R_100. Makes sure only forex is affected.');
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy';
    $bet_params->{underlying} = 'frxUSDJPY';
    $bet_params->{duration}   = '1d';
    note('set underlying to frxUSDJPY and duration to 1 day');
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy';

    note('set duration to five ticks.');
    $bet_params->{duration} = '5t';
    $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid';
    like($c->primary_validation_error->message_to_client, qr/Trading is temporarily suspended/, 'throws error');
};

done_testing();
