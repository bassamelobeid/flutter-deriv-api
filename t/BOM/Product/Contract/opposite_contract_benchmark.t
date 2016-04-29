#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Time::HiRes;
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);

use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Market::Underlying;
use Date::Utility;
use Time::Duration::Concise;

my $pricing_date = Date::Utility->new('2012-11-08 20:00:00');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $pricing_date
    }) for qw(USD JPY JPY-USD);
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $pricing_date
    });

BOM::Platform::Runtime->instance->app_config->system->directory->feed('/home/git/regentmarkets/bom/t/data/feed/');
BOM::Test::Data::Utility::FeedTestDatabase::setup_ticks('frxUSDJPY/8-Nov-12.dump');

my $at = BOM::Market::AggTicks->new;
$at->flush;
$at->fill_from_historical_feed({
    underlying   => BOM::Market::Underlying->new('frxUSDJPY'),
    ending_epoch => $pricing_date->epoch,
    interval     => Time::Duration::Concise->new(interval => '6h'),
});

my $bet_params = {
    underlying  => 'frxUSDJPY',
    bet_type    => 'CALL',
    barrier     => 'S0P',
    currency    => 'USD',
    payout      => 100,
    date_start  => $pricing_date,
    pricing_new => 1,
    duration    => '5h',
    backtest    => 1,
};

# does not count because we need to build the lazy build stuffs?
my $does_not_count = produce_contract($bet_params);
$does_not_count->ask_probability;

sub current {
    my $bet_params = shift;

    my $c = produce_contract($bet_params);
    $c->ask_probability;

    $bet_params->{bet_type} = $c->other_side_code;
    my $opp_c = produce_contract($bet_params);
    $opp_c->ask_probability;
}

sub improved {
    my $bet_params = shift;

    my $c = produce_contract($bet_params);
    $c->ask_probability;
    $c->opposite_contract->ask_probability;
}

my $t1 = Time::HiRes::time;
improved($bet_params) for (1 .. 100);
my $improved_time = Time::HiRes::time - $t1;

$t1 = Time::HiRes::time;
current($bet_params) for (1 .. 100);
my $current_time = Time::HiRes::time - $t1;

ok $current_time > $improved_time, 'improved is faster';
note("Time to compute both side with current implementation $current_time");
note("Time to compute both side with improved implementation $improved_time");
ok(($current_time - $improved_time) / $current_time > 0.2, 'faster by at least 20%');
done_testing();
