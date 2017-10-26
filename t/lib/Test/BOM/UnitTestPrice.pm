package Test::BOM::UnitTestPrice;

use 5.010;
use strict;
use warnings;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use VolSurface::Utils qw(get_strike_for_spot_delta);
use Date::Utility;
use BOM::MarketData qw(create_underlying);
use List::MoreUtils qw(uniq);
use YAML::XS qw(LoadFile);

use BOM::Test;

BEGIN {
    die "wrong env. Can't run test" if (BOM::Test::env !~ /^(qa\d+|development)$/);
}

sub create_pricing_data {
    my ($underlying_symbol, $payout_currency, $for_date) = @_;

    $for_date = Date::Utility->new unless $for_date;
    my $underlying = create_underlying($underlying_symbol);

    my @dividend_symbols;
    my @currencies = ($payout_currency);

    my @quanto_list;
    if ($underlying->market->name eq 'forex') {
        for ($underlying->asset_symbol, $underlying->quoted_currency_symbol) {
            if (my $symbol = _order_symbol($_, $payout_currency)) {
                push @quanto_list, $symbol;
            }
        }
    } elsif ($underlying->market->name eq 'commodities') {
        my $symbol = 'frx' . $underlying->asset_symbol . $payout_currency;
        push @quanto_list, $symbol;
    } elsif ($underlying->market->name ne 'volidx') {
        if (my $symbol = _order_symbol($underlying->quoted_currency_symbol, $payout_currency)) {
            push @quanto_list, $symbol;
        }
    }

    my @underlying_list =
        map { create_underlying($_) } @quanto_list;
    push @underlying_list, $underlying;

    foreach my $underlying (@underlying_list) {
        if (grep { $underlying->volatility_surface_type eq $_ } qw(delta moneyness)) {
            next unless $underlying->volatility_surface_type;
            if ($underlying->symbol eq 'frxBROUSD' or $underlying->symbol eq 'WLDEUR') {
                BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
                    'volsurface_delta',
                    {
                        symbol       => $underlying->symbol,
                        surface_data => {
                            1 => {
                                vol_spread => {50 => 0},
                                smile      => {
                                    25 => 0.1,
                                    50 => 0.1,
                                    75 => 0.1
                                }
                            },
                            365 => {
                                vol_spread => {50 => 0},
                                smile      => {
                                    25 => 0.1,
                                    50 => 0.1,
                                    75 => 0.1
                                }
                            },
                        },
                        recorded_date => $for_date,
                    });
            } else {
                BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
                    'volsurface_' . $underlying->volatility_surface_type,
                    {
                        symbol        => $underlying->symbol,
                        recorded_date => $for_date,
                    });
            }
        }

        if (grep { $underlying->market->name eq $_ } qw(forex commodities)) {
            push @currencies,
                ($underlying->asset_symbol, $underlying->quoted_currency_symbol, $underlying->rate_to_imply . '-' . $underlying->rate_to_imply_from);
        } else {
            @dividend_symbols = $underlying->symbol;
            push @currencies, $underlying->quoted_currency_symbol;
        }
    }

    @currencies       = uniq(grep { defined } @currencies);
    @dividend_symbols = uniq(grep { defined } @dividend_symbols);

    if ($underlying->market->name ne 'volidx') {
        BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
            'index',
            {
                symbol        => $_,
                recorded_date => $for_date
            }) for @dividend_symbols;
    } else {

        my $default_rate = 0;
        $default_rate = -35 if $underlying->symbol eq 'RDBULL';
        $default_rate = 20  if $underlying->symbol eq 'RDBEAR';

        BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
            'index',
            {
                symbol        => $_,
                recorded_date => $for_date,
                rates         => {365 => $default_rate},
            }) for @dividend_symbols;
    }

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'currency',
        {
            symbol        => $_,
            recorded_date => $for_date
        }) for @currencies;

    if ($underlying->market->name eq 'indices') {
        my $corr_data = {
            $underlying->symbol => {
                GBP => {
                    '3M'  => 0.356,
                    '6M'  => 0.336,
                    '9M'  => 0.32,
                    '12M' => 0.307,
                },
                USD => {
                    '3M'  => 0.356,
                    '6M'  => 0.336,
                    '9M'  => 0.32,
                    '12M' => 0.307,
                },
                AUD => {
                    '3M'  => 0.356,
                    '6M'  => 0.336,
                    '9M'  => 0.32,
                    '12M' => 0.307,
                },
                EUR => {
                    '3M'  => 0.356,
                    '6M'  => 0.336,
                    '9M'  => 0.32,
                    '12M' => 0.307,
                },
            }};
        BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
            'correlation_matrix',
            {
                symbol        => 'indices',
                correlations  => $corr_data,
                recorded_date => $for_date,
            });
    }

    return;
}

sub get_barrier_range {
    my $args = shift;

    my ($underlying, $duration, $spot, $vol) =
        @{$args}{'underlying', 'duration', 'spot', 'volatility'};
    my $premium_adjusted = $underlying->market_convention->{delta_premium_adjusted};
    my @barriers;
    if ($args->{type} eq 'double') {
        my $ref = {
            high_barrier => 'VANILLA_CALL',
            low_barrier  => 'VANILLA_PUT',
        };
        foreach my $delta (10, 90) {
            my $highlow;
            foreach my $type (keys %$ref) {
                $highlow->{$type} = get_strike_for_spot_delta({
                    delta            => $delta / 100,
                    option_type      => $ref->{$type},
                    atm_vol          => $vol,
                    t                => $duration / (86400 * 365),
                    r_rate           => 0,
                    q_rate           => 0,
                    spot             => $spot,
                    premium_adjusted => $premium_adjusted,
                });
            }
            push @barriers, $highlow;
        }
    } else {
        for my $delta (8 .. 12) {
            my $barrier = {
                barrier => get_strike_for_spot_delta({
                        delta            => ($delta * 5) / 100,
                        option_type      => 'VANILLA_CALL',
                        atm_vol          => $vol,
                        t                => $duration / (86400 * 365),
                        r_rate           => 0,
                        q_rate           => 0,
                        spot             => $spot,
                        premium_adjusted => $premium_adjusted,
                    }
                ),
            };
            push @barriers, $barrier;
        }
    }

    return \@barriers;
}

sub _order_symbol {
    my ($s1, $payout_currency) = @_;

    return if $s1 eq $payout_currency;
    my %order = (
        USD => 1,
        EUR => 2,
        GBP => 3,
        AUD => 4
    );
    if (not $order{$s1}) {
        return 'frx' . $payout_currency . $s1;
    } else {
        return ($order{$s1} > $order{$payout_currency})
            ? 'frx' . $s1 . $payout_currency
            : 'frx' . $payout_currency . $s1;
    }

    return;
}

1;
