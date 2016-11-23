use strict;
use warnings;

use Time::HiRes;
use Test::MockTime qw/:all/;
use Test::Most qw(-Test::Deep);
use Format::Util::Numbers qw(roundnear);
use Test::FailWarnings;
use JSON qw(decode_json);
use BOM::Product::ContractFactory qw(produce_contract);
use Postgres::FeedDB::Spot::Tick;
use Date::Utility;
use BOM::MarketData qw(create_underlying);

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
initialize_realtime_ticks_db();

my $now = Date::Utility->new('2016-03-18 05:00:00');

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $now,
    }) for (qw/USD EUR EUR-USD/);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxEURUSD',
        recorded_date => $now,
    });

set_absolute_time($now->epoch);

my $blackout_start = $now->minus_time_interval('1h');
my $blackout_end   = $now->plus_time_interval('1h');

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'economic_events',
    {
        recorded_date => $now,
        events        => [{
                symbol       => 'USD',
                release_date => $now->epoch,
                blankout     => $blackout_start->epoch,
                blankout_end => $blackout_end->epoch,
                is_tentative => 1,
                expected_return => 20,
                event_name   => 'Test tentative',
                impact       => 5,
            }
        ,
        {
                symbol       => 'EUR',
                release_date => $now->epoch,
                blankout     => $blackout_start->epoch,
                blankout_end => $blackout_end->epoch,
                is_tentative => 1,
                expected_return => 5,
                event_name   => 'Test tentative',
                impact       => 5,
            }
        ],
    });

my $contract_args = {
    underlying   => 'frxEURUSD',
    bet_type     => 'CALL',
    barrier      => 'S0P',
    duration     => '1h',
    payout       => 100,
    currency     => 'USD',
    date_pricing => $now,
    date_start   => $now,
    current_tick => Postgres::FeedDB::Spot::Tick->new({
        symbol => 'frxEURUSD',
        epoch  => $now->epoch,
        quote  => 100,
    })
};

#key is "contract type_pip diff" and value is expected barrier(s)
my $expected = {
    'CALL_0'          => [86.95652],
    'CALL_1000'       => [86.96522],
    'EXPIRYMISS_2000' => [115.023, 86.93913],
    'EXPIRYRANGE_2000'=> [86.97391, 114.977],
    'NOTOUCH_0'       => [115],
    'NOTOUCH_1000'    => [115.0115],
    'ONETOUCH_2000'   => [86.97391],
    'PUT_1000'        => [115.0115],
    'PUT_0'           => [115],
    'RANGE_2500'      => [115.02875, 86.93478],
    'UPORDOWN_2500'   => [86.97826, 114.97125],
};

my $underlying = create_underlying('frxEURUSD');

foreach my $key (sort { $a cmp $b } keys %{$expected}) {
    my @exp = @{$expected->{$key}};
    my ($bet_type, $pip_diff) = split '_', $key;

    $contract_args->{bet_type} = $bet_type;

    if ( grep { $bet_type eq $_ } qw(CALL CALLE PUT PUTE ONETOUCH NOTOUCH)  ) {
        $contract_args->{barrier} = 'S' . $pip_diff . 'P';
    } else {
        $contract_args->{high_barrier} = 'S' . $pip_diff . 'P';
        $contract_args->{low_barrier} = 'S-' . $pip_diff . 'P';
    }

    my $c = produce_contract($contract_args);

    is roundnear(0.00001, $c->barriers_for_pricing->{barrier1}), $exp[0], "correct first barrier for $key";
    is roundnear(0.00001, $c->barriers_for_pricing->{barrier2}), $exp[1], "correct second barrier for $key" if $c->two_barriers;

    #force pricing similar contract without any tentative events
    $contract_args->{tentative_events} = [];
    $c = produce_contract($contract_args);
    is abs(roundnear(0.00001, 100 - $c->barriers_for_pricing->{barrier1})), $underlying->pip_size * $pip_diff, 
        "without events - correct first barrier for $key: ". $c->barriers_for_pricing->{barrier1};

    is abs(roundnear(0.00001, 100 - $c->barriers_for_pricing->{barrier2})), $underlying->pip_size * $pip_diff, 
        "without events - correct second barrier for $key: " . $c->barriers_for_pricing->{barrier2} if $c->two_barriers;

    delete $contract_args->{tentative_events};
}

done_testing();

