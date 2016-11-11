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
                expected_return => 3,
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
                expected_return => 1,
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

#key is "contract type_pip diff" and value is ask_price, expected high and low barriers.
#for single barrier contracts, value is ask_price, expected barrier.
my $expected = {
    'CALL_1000'       => [100, 98.05],
    'CALL_0'          => [100, 98.04],
    # 'PUT_1000'        => [100, 102.01],
    # 'PUT_0'           => [100, 102],
    # 'NOTOUCH_0'       => [110, 110, 59.9],
    # 'NOTOUCH_0'       => [110, 110, 59.9],
    # 'ONETOUCH_200'    => [110, 110, 59.9],
};

my $underlying = create_underlying('frxEURUSD');

foreach my $key (sort { $a cmp $b } keys $expected) {
    my @exp = @{$expected->{$key}};
    my ($bet_type, $pip_diff) = split '_', $key;

    $contract_args->{bet_type} = $bet_type;

    if ( grep { $bet_type eq $_ } qw(CALL CALLE PUT PUTE ONETOUCH NOTOUCH)  ) {
        $contract_args->{barrier} = 'S' . $pip_diff . 'P';
    } else {
        $contract_args->{high_barrier} = 'S' . $pip_diff . 'P' if $pip_diff ne '0';
        $contract_args->{low_barrier} = 'S-' . $pip_diff . 'P' if $pip_diff ne '0';
    }

    my $c = produce_contract($contract_args);
    is roundnear(0.01, $c->ask_price), $exp[0], "correct ask price for $key";
    $DB::single=1;

    is roundnear(0.01, $c->barriers_for_pricing->{barrier1}), $exp[1], "correct first barrier for $key";
    is roundnear(0.01, $c->barriers_for_pricing->{barrier2}), $exp[2], "correct second barrier for $key" if defined $exp[2];

    $DB::single=1;
    $contract_args->{tentative_events} = [];
    $c = produce_contract($contract_args);
    is abs(roundnear(0.01, 100 - $c->barriers_for_pricing->{barrier1})), $underlying->pip_size * $pip_diff, "without events - correct first barrier for $key";
    is abs(roundnear(0.01, 100 - $c->barriers_for_pricing->{barrier2})), $underlying->pip_size * $pip_diff, "without events - correct second barrier for $key" if defined $exp[2];
    delete $contract_args->{tentative_events};
}

done_testing();

