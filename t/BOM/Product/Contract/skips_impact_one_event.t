#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;
use Date::Utility;

use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);

initialize_realtime_ticks_db();

subtest 'skips economic event with impact 1 in volatility calculation' => sub {
    my $now        = Date::Utility->new('2016-10-17 10:00:00');
    my $event_date = $now->minus_time_interval('15m');
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'economic_events',
        {
            recorded_date => $event_date,
            events        => [{
                    symbol       => 'USD',
                    impact       => 5,
                    release_date => $event_date->epoch,
                    event_name   => 'Construction Spending m/m'
                },
                {
                    symbol       => 'USD',
                    impact       => 1,
                    release_date => $event_date->epoch,
                    event_name   => 'CB Leading Index m/m'
                },
            ]});
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            symbol        => 'frxUSDJPY',
            recorded_date => $now,
        });
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'currency',
        {
            symbol        => $_,
            recorded_date => $now
        }) for qw(USD JPY JPY-USD);

    my $c = produce_contract({
        underlying   => 'frxUSDJPY',
        bet_type     => 'CALL',
        date_start   => $now,
        date_pricing => $now,
        duration     => '1h',
        barrier      => 'S0P',
        currency     => 'USD',
        payout       => 1,
    });
    is scalar(@{$c->_applicable_economic_events}),                2, 'two economic events recorded';
    is scalar(@{$c->economic_events_for_volatility_calculation}), 1, 'one economic event left for volatility calculation';
    my $e = $c->economic_events_for_volatility_calculation->[0];
    is $e->{impact}, 5, 'impact 5';
    is $e->{event_name}, 'Construction Spending m/m', 'correct event name';
};

done_testing();
