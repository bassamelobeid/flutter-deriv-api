package BOM::MarketDataAutoUpdater::ImpliedInterestRates;
use Moose;
extends 'BOM::MarketDataAutoUpdater';

use List::MoreUtils qw(notall);
use Scalar::Util qw(looks_like_number);
use Text::CSV::Slurp;

use Format::Util::Numbers qw(roundcommon);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use BOM::Config::Chronicle;
use Bloomberg::FileDownloader;
use BOM::Config::Runtime;
use Bloomberg::UnderlyingConfig;
use Quant::Framework::ImpliedRate;
use Quant::Framework::Currency;
use Quant::Framework;
use Quant::Framework::ExpiryConventions;
use BOM::Config::Chronicle;
use LandingCompany::Registry;

use constant EXTERNAL_FIAT_CURRENCIES => qw(
    JPY NZD CAD CHF PLN NOK MXN SEK
);

has file => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_file {
    my @files = Bloomberg::FileDownloader->new->grab_files({file_type => 'forward_rates'});
    return $files[0];
}

has currencies => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_currencies {
    my @currencies = LandingCompany::Registry::all_currencies();
    return \@currencies;
}

has fiat_currencies => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_fiat_currencies {
    my ($self) = @_;
    my @currencies = $self->_get_currencies_by_type('fiat');
    # for now we need to set these fiat currencies manually since
    # they are not on our LandingCompany config and quants needs
    # these currencies for further calculation.
    push(@currencies, EXTERNAL_FIAT_CURRENCIES);
    return \@currencies;
}

=head2

search for all currencies by a specific type (fiat/crypto)

=back

return array with the currencies for the given type

=cut

sub _get_currencies_by_type {
    my ($self, $type) = @_;

    my @response;
    for my $currency_code ($self->currencies->@*) {
        my $definition = LandingCompany::Registry::get_currency_definition($currency_code);
        push(@response, $currency_code) if $definition->{type} eq $type;
    }
    return @response;
}

sub _get_forward_rates {
    my $self = shift;

    my $csv = Text::CSV::Slurp->load(file => $self->file);
    my $forward_rates;
    my $report = $self->report;

    foreach my $line (@$csv) {
        my $item = $line->{SECURITIES};
        next if $item eq 'N.A.';
        my $item_rates = $line->{PX_LAST};
        my $error_code = $line->{'ERROR CODE'};

        if ($error_code != 0 or $item_rates eq 'N.A.' or not looks_like_number($item_rates)) {
            push @{$report->{error}},
                'implied interest rates[' . $item_rates . '] data from Bloomberg has error code[' . $error_code . '] for security[' . $item . ']';
            next;
        }
        my ($underlying, $term) = $self->_get_forward_and_term_from_BB_ticker($item);
        if (defined $underlying and defined $term) {
            $forward_rates->{$underlying}->{rates}->{$term} = $item_rates;
        } else {
            push @{$report->{error}}, "Cannot get underlying symbol and term from bloomberg ticker[$item]";
        }
    }

    return $forward_rates;
}

sub run {
    my $self = shift;

    my $report        = $self->report;
    my $forward_rates = $self->_get_forward_rates();
    my @tenors        = ('ON', '1W', '2W', '1M', '2M', '3M', '6M', '9M', '12M');

    UNDERLYING:
    foreach my $underlying_symbol (keys %$forward_rates) {

        my $underlying                    = create_underlying($underlying_symbol);
        my $spot                          = $forward_rates->{$underlying_symbol}->{rates}->{'SP'};
        my $currency_to_imply_symbol      = $underlying->rate_to_imply;
        my $currency_to_imply_from_symbol = $underlying->rate_to_imply_from;
        my $implied_symbol                = $currency_to_imply_symbol . '-' . $currency_to_imply_from_symbol;
        my $currency_to_imply             = Quant::Framework::Currency->new({
            symbol           => $currency_to_imply_symbol,
            chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
        });
        # According to Bloomberg,
        # a) Implied rate for asset currency:
        #    - For ON :
        #      Implied rate = ((ON_forward_outright * (1 + quoted_currency_rate/100 * tiy))/TN_forward_outright) - 1)/ tiy
        #
        #    - While for other tenors other than ON:
        #      Implied rate = ((spot * (1 + quoted_currency_rate/100 * tiy))/Tenor_forward_outright - 1)/ tiy
        #
        # b) Implied rate for quoted currency:
        #    - For ON :
        #      Implied rate = ((TN_forward_outright * (1 + asset_currency_rate/100 * tiy))/ON_forward_outright) - 1)/ tiy
        #
        #    - While for other tenors other than ON:
        #      Implied rate = ((Tenor_forward_outright * (1 + asset_currency_rate/100 * tiy))/spot - 1)/ tiy

        my $trading_calendar  = Quant::Framework->new->trading_calendar(BOM::Config::Chronicle::get_chronicle_reader);
        my $expiry_convention = Quant::Framework::ExpiryConventions->new(
            calendar   => $trading_calendar,
            underlying => $underlying,
        );
        my $implied_rates;
        foreach my $tenor (@tenors) {
            my $forward_day              = $self->_tenor_mapper($tenor, $expiry_convention);
            my $asset_currency_daycount  = $underlying->asset->daycount;
            my $quoted_currency_daycount = $underlying->quoted_currency->daycount;
            my $tiy                      = $forward_day / 365;
            my $quoted_currency_rate     = $underlying->quoted_currency->rate_for($tiy);
            my $asset_currency_rate      = $underlying->asset->rate_for($tiy);

            if ($tenor eq 'ON') {
                if (    exists $forward_rates->{$underlying_symbol}->{rates}->{'ON'}
                    and exists $forward_rates->{$underlying_symbol}->{rates}->{'TN'})
                {
                    my $ON_forward_outright = $forward_rates->{$underlying_symbol}->{rates}->{'ON'};
                    my $TN_forward_outright = $forward_rates->{$underlying_symbol}->{rates}->{'TN'};

                    if ($currency_to_imply_symbol eq $underlying->asset_symbol) {
                        $implied_rates->{$forward_day} = roundcommon(
                            0.0001,
                            ((
                                    ($ON_forward_outright * (1 + $quoted_currency_rate * ($forward_day / $quoted_currency_daycount))) /
                                        $TN_forward_outright
                                ) - 1
                            ) / ($forward_day / $asset_currency_daycount) * 100
                        );
                    } elsif ($currency_to_imply_symbol eq $underlying->quoted_currency_symbol) {
                        $implied_rates->{$forward_day} = roundcommon(
                            0.0001,
                            (
                                (($TN_forward_outright * (1 + $asset_currency_rate * ($forward_day / $asset_currency_daycount))) /
                                        $ON_forward_outright) - 1
                            ) / ($forward_day / $quoted_currency_daycount) * 100
                        );
                    }
                }
            } else {
                my $tenor_forward_outright = $forward_rates->{$underlying_symbol}->{rates}->{$tenor};

                if ($tenor_forward_outright) {
                    if ($currency_to_imply_symbol eq $underlying->asset_symbol) {
                        $implied_rates->{$forward_day} = roundcommon(0.0001,
                            ((($spot * (1 + $quoted_currency_rate * ($forward_day / $quoted_currency_daycount))) / $tenor_forward_outright) - 1) /
                                ($forward_day / $asset_currency_daycount) *
                                100);
                    } elsif ($currency_to_imply_symbol eq $underlying->quoted_currency_symbol) {
                        $implied_rates->{$forward_day} = roundcommon(0.0001,
                            ((($tenor_forward_outright * (1 + $asset_currency_rate * ($forward_day / $asset_currency_daycount))) / $spot) - 1) /
                                ($forward_day / $quoted_currency_daycount) *
                                100);
                    }
                }
            }

            my $market_rates_for_tenor = $currency_to_imply->rate_for($forward_day / 365);

            next if not $implied_rates->{$forward_day};

            if ($implied_rates->{$forward_day} >= 5) {
                if (   ($market_rates_for_tenor / ($implied_rates->{$forward_day} / 100) >= 2)
                    or ($market_rates_for_tenor / ($implied_rates->{$forward_day} / 100) <= 0.5))
                {
                    $implied_rates->{$forward_day} = $market_rates_for_tenor;
                }
            }

            # Perform some sanity checks for the implied rates.
            # First condition: Check if the implied_rate is more than 5%
            # Second condition: If the first condition meet, check if the implied rate is reasonable compare to market rates.
            # Example: If the implied rate is 8% but the market rate itself is around 7%, then that high implied rate is reasonable

            if ($implied_rates->{$forward_day} > 15 or $implied_rates->{$forward_day} < -3) {
                $report->{$implied_symbol} = {
                    success => 0,
                    reason  => 'The implied rate for '
                        . $currency_to_imply_symbol
                        . ' implied from '
                        . $underlying_symbol
                        . ' on tenor '
                        . $tenor . ' is '
                        . $implied_rates->{$forward_day}
                        . ' which is not within our acceptable range [-3%, 15%]'
                };
                next UNDERLYING;
            }
        }

        my $implied = Quant::Framework::ImpliedRate->new(
            symbol           => $implied_symbol,
            rates            => $implied_rates,
            recorded_date    => Date::Utility->new,
            chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
        );

        $implied->save;
        $report->{$implied_symbol}->{success} = 1;
    }

    my @crypto = $self->_get_currencies_by_type('crypto');

    my @pairs;
    for my $crypto (@crypto) {
        push @pairs, join '-', $crypto, $_ for $self->fiat_currencies->@*;
    }

    foreach my $sym (@pairs) {
        Quant::Framework::ImpliedRate->new(
            symbol => $sym,
            rates  => {
                0   => 0,
                365 => 0
            },
            recorded_date    => Date::Utility->new,
            chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
        )->save;

        $report->{$sym}->{success} = 1;
    }

    $self->SUPER::run();
    return 1;
}

sub _tenor_mapper {
    my ($self, $tenor, $expiry_convention) = @_;

    my $date = Date::Utility->new();

    my $expiry_spot_date = $expiry_convention->_spot_date($date);

    my $forward_expiry_date = $expiry_convention->forward_expiry_date({
        from => $date,
        term => $tenor,
    });

    # for 1W and above, the number of expiry day is calculated from the spot date
    my $day =
        ($tenor eq 'ON')
        ? $forward_expiry_date->days_between($date)
        : $forward_expiry_date->days_between($expiry_spot_date);

    return $day;
}

sub _get_forward_and_term_from_BB_ticker {
    my ($self, $ticker) = @_;

    my %tickerlist = Bloomberg::UnderlyingConfig::get_forward_tickers_list();
    foreach my $underlying (keys %tickerlist) {
        foreach my $term (keys %{$tickerlist{$underlying}}) {
            if ($ticker eq $tickerlist{$underlying}{$term}) {
                return ($underlying, $term);
            }
        }
    }

    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
