#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 3;
use Test::NoWarnings;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
initialize_realtime_ticks_db();

use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Market::Underlying;
use Date::Utility;

my $now = Date::Utility->new;

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $now
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc('currency', {symbol => $_}) for qw(USD JPY JPY-USD);

my $current_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxUSDJPY',
    epoch      => $now->epoch,
    quote      => 100,
});
my $params = {
    bet_type     => 'CALL',
    underlying   => 'frxUSDJPY',
    duration     => '6h',
    barrier      => 'S0P',
    currency     => 'USD',
    payout       => 100,
    current_tick => $current_tick,
};

subtest 'opposite contract when pricing new' => sub {
    my $c                   = produce_contract($params);
    my $opp_c               = $c->opposite_contract;
    my @attributes_to_check = qw(pricing_vol pricing_spot q_rate r_rate pricing_engine_name pricing_new);
    my @cvs_to_check        = qw(timeindays timeindays);
    my @dates_to_check      = qw(date_start date_pricing date_expiry date_settlement);

    for my $att (@attributes_to_check) {
        is $c->$att, $opp_c->$att, "$att check";
    }

    for my $cv (@cvs_to_check) {
        is $c->$cv->amount, $opp_c->$cv->amount, "$cv check";
    }

    for my $date (@dates_to_check) {
        is $c->$date->epoch, $opp_c->$date->epoch, "$date check";
    }

    is $c->barrier->as_absolute, $opp_c->barrier->as_absolute, 'barrier check';
    is $opp_c->code, $c->other_side_code, 'contract type check';
};

subtest 'opposite contract when repricing an existing contract' => sub {
    my $entry_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => $now->epoch + 1,
        quote      => 101,
    });
    $params->{date_start}   = $now;
    $params->{date_pricing} = $now->epoch + 1;
    $params->{entry_tick}   = $entry_tick;

    my $opp_c = produce_contract($params)->opposite_contract;

    ok $opp_c->pricing_new, 'opposite contract as pricing new';
    is $opp_c->date_start->epoch, $now->epoch + 1, 'forwarded date_start to date_pricing';
    is $opp_c->date_expiry->epoch, Date::Utility->new($params->{date_pricing})->plus_time_interval('5h59m59s')->epoch, 'duration is correct';
    is $opp_c->barrier->as_absolute + 0, 101, 'entry tick present';
};
