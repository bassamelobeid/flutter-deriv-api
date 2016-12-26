#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 8;

use Format::Util::Numbers qw(roundnear);
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Product::Contract::Strike;
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use Postgres::FeedDB::Spot::Tick;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
initialize_realtime_ticks_db();

my $now = Date::Utility->new('2014-09-23');

my @codes = qw(
    T_FLASHU_FRXGBPUSD_120s_S0P_c_USD_EN
    T_ONETOUCH_FRXGBPUSD_18000s_S6P_c_USD_EN
    T_DOUBLEUP_FRXGBPUSD_1411603199_S0P_c_USD_RU
    T_CALL_FRXGBPUSD_1411603199_16091_c_USD_RU
    T_RANGE_FRXGBPUSD_1411603199_16200_15079_c_USD_EN
    T_UPORDOWN_FRXGBPUSD_1411603199_16215_15851_c_USD_EN
    T_INTRADU_FRXGBPUSD_300s_S0P_c_USD_EN
    T_DIGITMATCH_R-50_7t_5_c_USD_EN
);

my @expected = (0.5, 0.876, 0.498, 0.475089218874021, 0.669, 0.321054315020547, 0.5, 0.1);

my $count = 0;
foreach my $code (@codes) {
    my ($channel, $shortcode, $currency) = $code =~ /^(T|P)_([A-Za-z0-9-_]+)_c_([A-Z]{3})_([A-Z]{2}(?:_[A-Z]{2})?)$/;

    my @bits      = split /_/,  $shortcode;
    my @tiny_bits = split /\-/, $bits[0];
    my %bet_args;
    $bet_args{bet_type} = $tiny_bits[0];

    # Maybe some kind of forward starting bet with a time.
    my $start_time = $tiny_bits[1] || $now;
    $bet_args{date_start} = ($start_time == $now) ? $now : $start_time;
    $bet_args{date_pricing} = $bet_args{date_start};

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'currency',
        {
            symbol        => $_,
            recorded_date => $now,
        }) for (qw/GBP USD GBP-USD/);

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            symbol        => 'frxGBPUSD',
            recorded_date => $now,
        });

    my $symbol = $bits[1];
    $symbol =~ s/-/_/g;
    my $underlying = create_underlying($symbol);
    my $what_is_two = ($bits[2] =~ /[st]$/) ? 'duration' : 'date_expiry';
    $bet_args{$what_is_two} = $bits[2];
    $bet_args{underlying} = $underlying;

    if (defined $bits[4]) {
        $bet_args{high_barrier} = BOM::Product::Contract::Strike->strike_string($bits[3], $underlying, $bet_args{bet_type}, $bet_args{date_start});
        $bet_args{low_barrier}  = BOM::Product::Contract::Strike->strike_string($bits[4], $underlying, $bet_args{bet_type}, $bet_args{date_start});
    } elsif (defined $bits[3]) {
        $bet_args{barrier} = BOM::Product::Contract::Strike->strike_string($bits[3], $underlying, $bet_args{bet_type}, $bet_args{date_start});
    }
    $bet_args{payout}     = 250;
    $bet_args{currency}   = $currency;
    $bet_args{entry_tick} = $bet_args{current_tick} = Postgres::FeedDB::Spot::Tick->new({
        symbol => $underlying->symbol,
        epoch  => $start_time->epoch + 300,
        quote  => 1.6084
    });
    $bet_args{q_rate}      = 0;
    $bet_args{r_rate}      = 0;
    $bet_args{pricing_vol} = 0.1;
    $bet_args{atm_vols}    = {
        fordom => 0.1,
        domqqq => 0.1,
        forqqq => 0.1
    };

    my $contract = produce_contract(\%bet_args);

    is(roundnear(0.001, $contract->theo_probability->amount), roundnear(0.001, $expected[$count]), 'bs probability for [' . $contract->code . ']');
    $count++;
}
