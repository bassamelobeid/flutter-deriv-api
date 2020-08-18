use strict;
use warnings;

use 5.010;
use Test::Most;
use Test::Warnings;
use Test::Warnings qw/warning/;
use Test::Warn;
use YAML::XS;

use Date::Utility;

use BOM::Product::ContractFactory qw(produce_contract);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

initialize_realtime_ticks_db();

#lets cover a whole week + next week's first day
my @expiry_dates = (
    Date::Utility->new('2016-05-09'), Date::Utility->new('2016-05-10'), Date::Utility->new('2016-05-11'), Date::Utility->new('2016-05-12'),
    Date::Utility->new('2016-05-13'), Date::Utility->new('2016-05-16'));

my $surfaces = YAML::XS::LoadFile('/home/git/regentmarkets/bom/t/BOM/Product/Volatility/vol_compare_data.yml');
my $expected = YAML::XS::LoadFile('/home/git/regentmarkets/bom/t/BOM/Product/Volatility/vol_compare_expected_vol.yml');

my $counter = 0;

for my $expiry (@expiry_dates) {
    my $start_date = $expiry->minus_time_interval('8d');
    my $end_of_day = $expiry->plus_time_interval('23h59m59s');
    if ($end_of_day->day_of_week == 5) {
        $end_of_day = $expiry->plus_time_interval('21h');
    }

    my @dates;
    my @ticks;
    while ($start_date->is_before($end_of_day)) {
        push @dates, $start_date;
        push @ticks, [100, $start_date->epoch, 'frxUSDJPY'];
        $start_date = $start_date->plus_time_interval('4h');
    }
    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(@ticks);

    foreach my $date (@dates) {
        warning { price_contracts($date, $end_of_day, $expected) }, qr/No basis tick for/;
    }
}

sub price_contracts {
    my ($date_start, $date_expiry, $expected) = @_;

    return                                                            if ($date_expiry->epoch - $date_start->epoch < (12 * 60 * 60));
    die "Could not load volatility surface for " . $date_start->epoch if not defined $surfaces->{$date_start->epoch};

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            recorded_date => $date_start,
            surface       => $surfaces->{$date_start->epoch}->{surface},
            symbol        => 'frxUSDJPY',
        });

    Quant::Framework::Utils::Test::create_doc(
        'currency',
        {
            symbol           => $_,
            recorded_date    => $date_start,
            chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
        }) for (qw/JPY USD JPY-USD/);

    my $c = produce_contract({
        bet_type     => 'CALL',
        underlying   => 'frxUSDJPY',
        barrier      => 'S0P',
        currency     => 'USD',
        payout       => 100,
        date_expiry  => $date_expiry,
        date_start   => $date_start,
        date_pricing => $date_start,
    });

    my $callspread = produce_contract({
        bet_type     => 'CALLSPREAD',
        underlying   => 'frxUSDJPY',
        duration     => '2h',
        high_barrier => 100.11,
        low_barrier  => 99.01,
        currency     => 'USD',
        payout       => 100,
        date_expiry  => $date_expiry,
        date_start   => $date_start,
        date_pricing => $date_start,
    });

    my $pricing_vol_call                     = $c->pricing_vol;
    my $high_barrier_pricing_vol_callspread  = $callspread->pricing_vol_for_two_barriers->{high_barrier_vol};
    my $low_barrier_pricing_vol_callspread   = $callspread->pricing_vol_for_two_barriers->{low_barrier_vol};
    my $expected_pricing_vol_call            = $expected->{CALL}[$counter];
    my $expected_high_pricing_vol_callspread = $expected->{CALLSPREAD}{high_barrier_vol}[$counter];
    my $expected_low_pricing_vol_callspread  = $expected->{CALLSPREAD}{low_barrier_vol}[$counter];
    ok abs($pricing_vol_call - $expected_pricing_vol_call) < 1e-15,
        "correct pricing_vol for CALL " . $date_start->datetime . " to " . $date_expiry->datetime
        or note "had $pricing_vol_call expected $expected_pricing_vol_call";

    ok abs($high_barrier_pricing_vol_callspread - $expected_high_pricing_vol_callspread) < 1e-15,
        "correct pricing_vol for CALLSPREAD " . $date_start->datetime . " to " . $date_expiry->datetime
        or note "had high_barrier $high_barrier_pricing_vol_callspread expected $expected_high_pricing_vol_callspread";

    ok abs($low_barrier_pricing_vol_callspread - $expected_low_pricing_vol_callspread) < 1e-15,
        "correct pricing_vol for CALLSPREAD " . $date_start->datetime . " to " . $date_expiry->datetime
        or note "had low_barrier $low_barrier_pricing_vol_callspread expected $expected_low_pricing_vol_callspread";
    $counter++;
}

done_testing;
