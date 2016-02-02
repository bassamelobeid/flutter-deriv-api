package BOM::Test::Data::Utility::UnitTestPrice;

use 5.010;
use strict;
use warnings;

use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);
use VolSurface::Utils qw(get_strike_for_spot_delta);
use Date::Utility;
use BOM::Market::Underlying;
use List::MoreUtils qw(uniq);
use YAML::XS qw(LoadFile);

sub create_pricing_data {
    my ($underlying_symbol, $payout_currency, $for_date) = @_;

    $for_date = Date::Utility->new unless $for_date;
    my $underlying = BOM::Market::Underlying->new($underlying_symbol);

    if (grep {$underlying->volatility_surface_type eq $_} qw(delta moneyness)) {
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
        } elsif ($underlying->market->name ne 'random') {
            if (my $symbol = _order_symbol($underlying->quoted_currency_symbol, $payout_currency)) {
                push @quanto_list, $symbol;
            }
        }

        my @underlying_list = map { BOM::Market::Underlying->new($_) } @quanto_list;
        push @underlying_list, $underlying;

        foreach my $underlying (@underlying_list) {
            BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
                'volsurface_' . $underlying->volatility_surface_type,
                {
                    symbol        => $underlying->symbol,
                    recorded_date => $for_date,
                });
        }
    }

    my @dividend_symbols;
    my @currencies = ($payout_currency);
    if (grep { $underlying->market->name eq $_ } qw(forex commodities)) {
        push @currencies, ($underlying->asset_symbol, $underlying->quoted_currency_symbol);
    } else {
        @dividend_symbols = $underlying->symbol;
        push @currencies, $underlying->quoted_currency_symbol;
    }

    @currencies = uniq(grep {defined } @currencies);

    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'index',
        {
            symbol        => $_,
            recorded_date => $for_date
        }) for @dividend_symbols;
    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
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
        BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
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

    my ($underlying, $duration, $spot, $vol) = @{$args}{'underlying', 'duration', 'spot', 'volatility'};
    my $premium_adjusted = $underlying->market_convention->{delta_premium_adjusted};
    my @barriers;
    if ($args->{contract_category}->two_barriers) {
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
        return ($order{$s1} > $order{$payout_currency}) ? 'frx' . $s1 . $payout_currency : 'frx' . $payout_currency . $s1;
    }

    return;
}

1;
