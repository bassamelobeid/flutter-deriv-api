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
use BOM::Config::Runtime;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

use Test::BOM::UnitTestPrice;

initialize_realtime_ticks_db();

Test::BOM::UnitTestPrice::create_pricing_data('R_100', 'USD', Date::Utility->new('2014-07-10 10:00:00'));

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

subtest 'tick highlow tick stream' => sub {
    my $args = {
        underlying   => 'R_100',
        bet_type     => 'TICKHIGH',
        date_start   => $one_day,
        duration     => '5t',
        date_pricing => $one_day,
        currency     => 'USD',
        payout       => 100,
    };

    my $contract;

#At the second tick of the contract, the contract with 2 as selected tick lost
    my $index = 2;

    $args->{date_pricing} = $one_day->plus_time_interval(($index * 2) . 's');

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $one_day->epoch + $index * 2,
        quote      => 90
    });

    $args->{selected_tick} = 1;
    $contract = produce_contract($args);
    ok !$contract->close_tick, 'contract for selected tick = 1 is not expired yet';
    is scalar @{$contract->tick_stream}, 2, 'All current available ticks';

    $args->{selected_tick} = 2;
    $contract = produce_contract($args);
    is $contract->close_tick->{quote}, 90, 'contract for selected tick = 2 is expired';
    is scalar @{$contract->tick_stream}, 2, 'Only first two ticks are stored';

    $args->{selected_tick} = 3;
    $contract = produce_contract($args);
    ok !$contract->close_tick, 'contract for selected tick = 3 is not expired yet';
    is scalar @{$contract->tick_stream}, 2, 'All current available ticks';

    $args->{selected_tick} = 4;
    $contract = produce_contract($args);
    ok !$contract->close_tick, 'contract for selected tick = 4 is not expired yet';
    is scalar @{$contract->tick_stream}, 2, 'All current available ticks';

    $args->{selected_tick} = 5;
    $contract = produce_contract($args);
    ok !$contract->close_tick, 'contract for selected tick = 5 is not expired yet';
    is scalar @{$contract->tick_stream}, 2, 'All current available ticks';

#At the third tick of the contract, the contract with 3 as selected tick lost
    $index = 3;

    $args->{date_pricing} = $one_day->plus_time_interval(($index * 2) . 's');

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $one_day->epoch + $index * 2,
        quote      => 80
    });

    $args->{selected_tick} = 1;
    $contract = produce_contract($args);
    ok !$contract->close_tick, 'contract for selected tick = 1 is not expired yet';
    is scalar @{$contract->tick_stream}, 3, 'All current available ticks';

    $args->{selected_tick} = 2;
    $contract = produce_contract($args);
    is $contract->close_tick->{quote}, 90, 'contract for selected tick = 2 is expired';
    is scalar @{$contract->tick_stream}, 2, 'Only first two ticks are stored';

    $args->{selected_tick} = 3;
    $contract = produce_contract($args);
    is $contract->close_tick->{quote}, 80, 'contract for selected tick = 3 is expired';
    is scalar @{$contract->tick_stream}, 3, 'Only first three ticks are stored';

    $args->{selected_tick} = 4;
    $contract = produce_contract($args);
    ok !$contract->close_tick, 'contract for selected tick = 4 is not expired yet';
    is scalar @{$contract->tick_stream}, 3, 'All current available ticks';

    $args->{selected_tick} = 5;
    $contract = produce_contract($args);
    ok !$contract->close_tick, 'contract for selected tick = 5 is not expired yet';
    is scalar @{$contract->tick_stream}, 3, 'All current available ticks';

#At the fourth tick of the contract, the contract with 1 as the selected tick lost
    $index = 4;

    $args->{date_pricing} = $one_day->plus_time_interval(($index * 2) . 's');

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $one_day->epoch + $index * 2,
        quote      => 150
    });

    $args->{selected_tick} = 1;
    $contract = produce_contract($args);
    is $contract->close_tick->{quote}, 150, 'contract for selected tick = 1 is expired';
    is scalar @{$contract->tick_stream}, 4, 'Only first 4 ticks are stored';

    $args->{selected_tick} = 2;
    $contract = produce_contract($args);
    is $contract->close_tick->{quote}, 90, 'contract for selected tick = 2 is expired';
    is scalar @{$contract->tick_stream}, 2, 'Only first two ticks are stored';

    $args->{selected_tick} = 3;
    $contract = produce_contract($args);
    is $contract->close_tick->{quote}, 80, 'contract for selected tick = 3 is expired';
    is scalar @{$contract->tick_stream}, 3, 'Only first three ticks are stored';

    $args->{selected_tick} = 4;
    $contract = produce_contract($args);
    ok !$contract->close_tick, 'contract for selected tick = 4 is not expired yet';
    is scalar @{$contract->tick_stream}, 4, 'All current available ticks';

    $args->{selected_tick} = 5;
    $contract = produce_contract($args);
    ok !$contract->close_tick, 'contract for selected tick = 5 is not expired yet';
    is scalar @{$contract->tick_stream}, 4, 'All current available ticks';

#At the fifth tick of the contract, all contracts expired
    #
    $index = 5;

    $args->{date_pricing} = $one_day->plus_time_interval(($index * 2) . 's');

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $one_day->epoch + $index * 2,
        quote      => 60
    });

    $args->{selected_tick} = 1;
    $contract = produce_contract($args);
    is $contract->close_tick->{quote}, 150, 'contract for selected tick = 1 is expired';
    is scalar @{$contract->tick_stream}, 4, 'Only first 4 ticks are stored';

    $args->{selected_tick} = 2;
    $contract = produce_contract($args);
    is $contract->close_tick->{quote}, 90, 'contract for selected tick = 2 is expired';
    is scalar @{$contract->tick_stream}, 2, 'Only first two ticks are stored';

    $args->{selected_tick} = 3;
    $contract = produce_contract($args);
    is $contract->close_tick->{quote}, 80, 'contract for selected tick = 3 is expired';
    is scalar @{$contract->tick_stream}, 3, 'Only first three ticks are stored';

    $args->{selected_tick} = 4;
    $contract = produce_contract($args);
    ok $contract->is_expired, 'contract for selected tick = 4 is expired';
    is scalar @{$contract->tick_stream}, 5, 'All available ticks';

    $args->{selected_tick} = 5;
    $contract = produce_contract($args);
    is $contract->close_tick->{quote}, 60, 'contract for selected tick = 5 is expired';
    is scalar @{$contract->tick_stream}, 5, 'All available ticks';

};

