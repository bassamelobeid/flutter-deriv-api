#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use Date::Utility;
use BOM::Product::ContractFactory qw(produce_contract);

subtest 'is_in_quiet_period' => sub {
    my $non_dst = Date::Utility->new('2017-04-03');
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc('economic_events', {recorded_date => $non_dst});
    my $traded_start  = $non_dst->truncate_to_day->plus_time_interval('7h');
    my $traded_end    = $non_dst->truncate_to_day->plus_time_interval('21h');
    my $contract_args = {
        bet_type     => 'CALL',
        underlying   => 'frxEURUSD',
        date_start   => $traded_start,
        date_pricing => $traded_start,
        duration     => '1h',
        barrier      => 'S0P',
        currency     => 'USD',
        payout       => 100,
    };
    my $c = produce_contract($contract_args);
    ok $c->pricing_engine->is_in_quiet_period($traded_start->minus_time_interval('1s')), 'quiet period if it is 1 second before traded period';
    ok !$c->pricing_engine->is_in_quiet_period($traded_start), 'not in quiet period if it is in the actively traded period';
    is $c->pricing_engine->long_term_average_vol, 0.07, '7% long term average vol for non-quiet period';
    $c = produce_contract({
            %$contract_args,
            date_start   => $traded_end->plus_time_interval('1s'),
            date_pricing => $traded_end->plus_time_interval('1s')});
    ok $c->pricing_engine->is_in_quiet_period($traded_end->plus_time_interval('1s')), 'quiet period if it is 1 second after traded period';
    is $c->pricing_engine->long_term_average_vol, 0.035, '3.5% long term average vol for quiet period';

    # JPY related pairs
    my $jpy_traded_start = $non_dst->truncate_to_day;
    $contract_args->{underlying} = 'frxUSDJPY';
    $c = produce_contract($contract_args);
    ok $c->pricing_engine->is_in_quiet_period($jpy_traded_start->minus_time_interval('1s')), 'quiet period if it is 1 second before traded period';

};

done_testing();
