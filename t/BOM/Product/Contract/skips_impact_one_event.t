#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Warnings;
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
                    release_date => $event_date->epoch,
                    event_name   => 'Construction Spending m/m',
                    custom       => {
                        DIRECT => {
                            vol_change => 0.5,
                        }}
                },
                {
                    symbol       => 'USD',
                    release_date => $event_date->epoch,
                    event_name   => 'CB Leading Index m/m test'
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
    is scalar(@{$c->_applicable_economic_events}),                1, 'two economic events recorded';
    is scalar(@{$c->economic_events_for_volatility_calculation}), 1, 'one economic event left for volatility calculation';
    my $e = $c->economic_events_for_volatility_calculation->[0];
    is $e->{vol_change}, 0.5, 'vol_change 0.5';
    is $e->{release_epoch}, $event_date->epoch, 'correct event time';
};

done_testing();
