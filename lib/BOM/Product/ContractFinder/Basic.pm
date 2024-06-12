package BOM::Product::ContractFinder::Basic;

use strict;
use warnings;

use BOM::Config::Chronicle;
use BOM::Config::QuantsConfig;
use BOM::Config::Runtime;
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Fetcher::VolSurface;
use BOM::Product::Contract::Strike;
use BOM::Product::Contract::Strike::Turbos;
use BOM::Product::Contract::Strike::Vanilla;
use Cache::LRU;
use Date::Utility;
use Exporter              qw(import);
use Format::Util::Numbers qw(financialrounding);
use JSON::MaybeXS         qw(decode_json);
use List::Util            qw(max);
use Number::Closest::XS   qw(find_closest_numbers_around);
use POSIX                 qw(floor);
use Quant::Framework;
use Time::Duration::Concise;
use VolSurface::Utils qw(get_strike_for_spot_delta);
use YAML::XS          qw(LoadFile);

our @EXPORT_OK = qw(decorate decorate_brief);

my $cache = Cache::LRU->new(size => 500);

=head2 app_config
dynamic settings from backoffice
=cut

sub app_config {
    return BOM::Config::Runtime->instance->app_config;
}

=head2 decorate ($args)

Adds contract metadata to each offering object of an underlying symbol.

=head3 Parameters

Accepts a hashref with the following arguments:

=over 4

=item C<symbol> - string

Underlying symbol, e.g. 'R_50', '1HZ100V'

=item C<offerings> - arrayref

Array reference to the list of offerings

=item C<non_available_offerings> - arrayref

Array reference to the list of unavailable offerings

=item C<landing_company_name> - string

Short name of a landing company, e.g. 'virtual', 'svg', 'iom'

=back

=head3 Returns

Returns a hash with the following attributes:

=over 4

=item C<available> - arrayref

Array reference to the list of available offerings with added contract metadata

=item C<non_available> - arrayref

Array reference to the list of unavailable offerings

=item C<hit_count> - number

Total number of offerings available

=item C<spot> - number

Current spot price for the requested underlying symbol

=item C<open> - integer

Market opening time for the underlying symbol in epoch value 

=item C<close> - integer

Market closing time for the underlying symbol in epoch value

=item C<feed_license> - string

Indicates whether feed data is realtime or delayed

=back

=cut

sub decorate {
    my $args = shift;

    my ($symbol, $offerings, $non_available_offerings, $lc_short) =
        @{$args}{'symbol', 'offerings', 'non_available_offerings', 'landing_company_name'};

    my $now                 = Date::Utility->new;
    my $underlying          = create_underlying($symbol);
    my $exchange            = $underlying->exchange;
    my @inefficient_periods = @{$underlying->forward_inefficient_periods // []};
    my $calendar            = Quant::Framework->new->trading_calendar(BOM::Config::Chronicle::get_chronicle_reader());
    my $to_date             = $now->truncate_to_day;
    my @blackout_periods =
        map { [$to_date->plus_time_interval($_->{start})->time_hhmmss, $to_date->plus_time_interval($_->{end})->time_hhmmss] } @inefficient_periods;

    for my $o (@$offerings) {
        my $contract_category = $o->{contract_category};
        my $barrier_category  = $o->{barrier_category};
        my $contract_type     = $o->{contract_type};
        my $sentiment         = $o->{sentiment};

        if ($o->{start_type} eq 'forward') {
            my $key = join '::', ($symbol, $to_date->date);
            if (my $options = $cache->get($key)) {
                $o->{forward_starting_options} = $options;
            } else {
                my @trade_dates;
                for (my $date = $now; @trade_dates < 3; $date = $date->plus_time_interval('1d')) {
                    $date = $calendar->trade_date_after($exchange, $date) unless $calendar->trades_on($exchange, $date);
                    push @trade_dates, $date;
                }
                $o->{forward_starting_options} = [
                    map {
                        {
                            date  => Date::Utility->new($_->{open})->truncate_to_day->epoch,
                            open  => $_->{open},
                            close => $_->{close},
                            @blackout_periods ? (blackouts => \@blackout_periods) : ()}
                        }
                        map { @{$calendar->trading_period($exchange, $_)} } @trade_dates
                ];
                $cache->set($key, $o->{forward_starting_options});
            }
        }

        # This key is being used to decide whether to show additional
        # barrier field on the frontend.
        if ($contract_category =~ /^(?:staysinout|endsinout|accumulator)$/) {
            $o->{barriers} = 2;
        } elsif ($contract_category eq 'lookback'
            or $contract_category eq 'asian'
            or $contract_category eq 'highlowticks'
            or $barrier_category eq 'euro_atm'
            or $contract_type =~ /^DIGIT(?:EVEN|ODD)$/
            or $contract_category eq 'multiplier'
            or $contract_category eq 'callputspread')
        {
            $o->{barriers} = 0;
        } else {
            $o->{barriers} = 1;
        }

        if ($contract_category eq 'multiplier' and my $config = _get_multiplier_config($lc_short, $underlying->symbol)) {
            $o->{multiplier_range}   = $config->{multiplier_range};
            $o->{cancellation_range} = $config->{cancellation_duration_range};
        }

        if ($contract_category eq 'accumulator' and my $config = _get_accumulator_config($underlying->symbol)) {
            $o->{growth_rate_range} = $config->{growth_rate};
        }
        # The reason why we have to append 't' to tick expiry duration
        # is because in the backend it is easier to handle them if the
        # min and max are set as numbers rather than strings.
        if ($o->{expiry_type} eq 'tick') {
            $o->{max_contract_duration} .= 't';
            $o->{min_contract_duration} .= 't';
        }

        next unless $o->{barriers};

        if ($barrier_category eq 'non_financial') {
            if ($contract_type =~ /^DIGIT(?:MATCH|DIFF)$/) {
                $o->{last_digit_range} = [0 .. 9];
            } elsif ($contract_type eq 'DIGITOVER') {
                $o->{last_digit_range} = [0 .. 8];
            } elsif ($contract_type eq 'DIGITUNDER') {
                $o->{last_digit_range} = [1 .. 9];
            }
        } else {
            if ($o->{barriers} == 1) {
                $o->{barrier} = _default_barrier({
                    underlying        => $underlying,
                    duration          => $o->{min_contract_duration},
                    barrier_kind      => 'high',
                    contract_category => $o->{contract_category},
                });
            } else {
                $o->{high_barrier} = _default_barrier({
                    underlying        => $underlying,
                    duration          => $o->{min_contract_duration},
                    barrier_kind      => 'high',
                    contract_category => $o->{contract_category},
                });
                $o->{low_barrier} = _default_barrier({
                    underlying        => $underlying,
                    duration          => $o->{min_contract_duration},
                    barrier_kind      => 'low',
                    contract_category => $o->{contract_category},
                });
            }
        }

        # Here we set the barrier range N value
        if ($contract_category eq 'callputspread') {
            $o->{barrier_range} = _get_callputspread_barrier_range();
        }

        if ($contract_category eq 'vanilla') {
            # forex has dynamic max duration which is configurable from BO
            if ($underlying->market->name ne 'synthetic_index') {
                my $per_symbol_config = JSON::MaybeXS::decode_json(app_config->get("quants.vanilla.fx_per_symbol_config." . $underlying->symbol));
                my @maturities_allowed_days  = @{$per_symbol_config->{maturities_allowed_days}};
                my @maturities_allowed_weeks = @{$per_symbol_config->{maturities_allowed_weeks}};

                my $max_day  = max @maturities_allowed_days;
                my $max_week = max @maturities_allowed_weeks;

                # because weekly contracts need to end on Friday
                my $days_until_friday = (5 - Date::Utility->new->day_of_week) % 7;
                $o->{max_contract_duration} = max($max_day, ($max_week * 7) + $days_until_friday) . "d";
            }

            my $barrier_choices = _default_barrier_for_vanilla({
                    underlying   => $underlying,
                    duration     => $o->{min_contract_duration},
                    barrier_kind => 'high',
                    trade_type   => $contract_type,
                    expiry       => $o->{expiry_type}});

            if ($barrier_choices) {
                my $barrier_choices_length = scalar @{$barrier_choices};
                my $mid_barrier_choices    = $barrier_choices->[floor($barrier_choices_length / 2)];

                $o->{barrier_choices} = $barrier_choices;
                $o->{barrier}         = $mid_barrier_choices;
            }
        }

        if ($contract_category eq 'turbos' and my $config = _get_turbos_config($underlying->symbol)) {
            # latest available spot should be sufficient.
            my $current_tick    = defined $underlying->spot_tick ? $underlying->spot_tick : $underlying->tick_at(time, {allow_inconsistent => 1});
            my $barrier_choices = _default_barrier_for_turbos({
                underlying        => $underlying,
                duration          => $o->{min_contract_duration},
                sentiment         => $sentiment,
                expiry            => $o->{expiry_type},
                current_tick      => $current_tick,
                per_symbol_config => $config
            });

            my $barrier_choices_length = scalar @{$barrier_choices};
            my $mid_barrier_choices    = $barrier_choices->[floor($barrier_choices_length / 2)];

            $o->{barrier_choices} = $barrier_choices;
            $o->{barrier}         = $mid_barrier_choices;
            my $max      = $config->{max_multiplier} * $config->{max_multiplier_stake}{USD} / $current_tick->quote;
            my $min      = $config->{min_multiplier} * $config->{min_multiplier_stake}{USD} / $current_tick->quote;
            my $distance = abs($mid_barrier_choices);
            $o->{min_stake} = financialrounding('price', 'USD', $min * $distance);
            $o->{max_stake} = financialrounding('price', 'USD', $max * $distance);
        }
    }

    my ($open, $close) = (0, 0);
    if ($calendar->trades_on($exchange, $to_date)) {
        $open  = $calendar->opening_on($exchange, $to_date)->epoch;
        $close = $calendar->closing_on($exchange, $to_date)->epoch;
    }

    return {
        available     => $offerings,
        non_available => $non_available_offerings,
        hit_count     => scalar(@$offerings),
        spot          => $underlying->spot,
        open          => $open,
        close         => $close,
        feed_license  => $underlying->feed_license
    };
}

=head2 decorate_brief ($offerings)

Provide only brief details for each available offering.
Strip out other metadata relating to market, submarket, and underlying symbol.

=head3 Parameters

=over 4

=item C<offerings> - arrayref

Array reference to the list of offerings

=back

=head3 Returns

Returns a hash with the following attributes:

=over 4

=item C<available> - arrayref

Array reference to the list of available offerings

=item C<hit_count> - number

Total number of offerings available

=back

=cut

sub decorate_brief {
    my $offerings = shift;

    foreach my $offering (@$offerings) {
        delete $offering->{$_}
            for qw(exchange_name expiry_type market max_contract_duration min_contract_duration start_type submarket underlying_symbol);
    }

    return {
        available => $offerings,
        hit_count => scalar(@$offerings),
    };
}

=head2 _default_barrier_for_vanilla

calculates and return default barrier range for vanilla options

=cut

sub _default_barrier_for_vanilla {
    my $args = shift;

    my ($underlying, $duration, $barrier_kind, $trade_type, $expiry) = @{$args}{'underlying', 'duration', 'barrier_kind', 'trade_type', 'expiry'};

    $duration =~ s/t//g;
    $duration = Time::Duration::Concise->new(interval => $duration)->seconds;

    my $volsurface = BOM::MarketData::Fetcher::VolSurface->new->fetch_surface({underlying => $underlying});
    # latest available spot should be sufficient.
    my $current_tick = defined $underlying->spot_tick ? $underlying->spot_tick : $underlying->tick_at(time, {allow_inconsistent => 1});
    return unless $current_tick;

    # volatility should just be an estimate here, let's take it straight off the surface and
    # avoid all the craziness.
    my $tid          = $duration / 86400;
    my $closest_term = find_closest_numbers_around($tid, $volsurface->original_term_for_smile, 2);
    my $volatility   = $volsurface->get_surface_volatility($closest_term->[0], $volsurface->atm_spread_point);

    my $tiy = $tid / 365;

    $args = {
        current_spot => $current_tick->quote,
        pricing_vol  => $volatility,
        timeinyears  => $tiy,
        underlying   => $underlying,
        trade_type   => $trade_type,
        is_intraday  => $expiry eq 'intraday' ? 1 : 0
    };

    return BOM::Product::Contract::Strike::Vanilla::strike_price_choices($args);
}

=head2 _default_barrier_for_turbos

calculates and return default barrier range for turbos options

=cut

sub _default_barrier_for_turbos {
    my $args = shift;

    my ($underlying, $duration, $sentiment, $current_tick, $per_symbol_config) =
        @{$args}{'underlying', 'duration', 'sentiment', 'current_tick', 'per_symbol_config'};

    return unless $current_tick;

    my $fixed_config           = LoadFile('/home/git/regentmarkets/bom-config/share/fixed_turbos_config.yml');
    my $sigma                  = $fixed_config->{$underlying->symbol}->{sigma} || undef;
    my $num_of_barriers        = $per_symbol_config->{num_of_barriers}         || undef;
    my $min_distance_from_spot = $per_symbol_config->{min_distance_from_spot}  || undef;
    my $max_stake              = $per_symbol_config->{max_multiplier_stake}    || undef;
    my $max_multiplier         = $per_symbol_config->{max_multiplier}          || undef;

    unless (defined $sigma && defined $min_distance_from_spot && defined $num_of_barriers) {
        BOM::Product::Exception->throw(error_code => 'MissingRequiredContractConfig');
    }

    $args = {
        underlying             => $underlying,
        current_spot           => $current_tick->quote,
        sigma                  => $sigma,
        n_max                  => ($max_stake * $max_multiplier / $current_tick->quote),
        min_distance_from_spot => $min_distance_from_spot,
        num_of_barriers        => $num_of_barriers,
        sentiment              => $sentiment,
    };

    return BOM::Product::Contract::Strike::Turbos::strike_price_choices($args);
}

=head2 _turbos_per_symbol_config

get turbos per symbol config

=cut

sub _turbos_per_symbol_config {
    my $self = shift;

    #config for different landing companies are the same. and it is set as 'default' in app_config
    my $lc     = 'default';
    my $symbol = $self->underlying->symbol;

    if ($self->app_config->quants->turbos->symbol_config->can($lc) and $self->app_config->quants->turbos->symbol_config->$lc->can($symbol)) {
        return JSON::MaybeXS::decode_json($self->app_config->get("quants.turbos.symbol_config.$lc.$symbol"));
    } else {
        # throw error because configuration is unsupported for the symbol and landing company pair.
        BOM::Product::Exception->throw(error_code => 'MissingRequiredContractConfig');
    }
}

sub _default_barrier {
    my $args = shift;

    my ($underlying, $duration, $barrier_kind, $category) = @{$args}{'underlying', 'duration', 'barrier_kind', 'contract_category'};

    if ($category eq 'callputspread') {
        my $barrier = $underlying->pip_size;
        if ($barrier_kind eq 'high') {
            $barrier = '+' . $barrier;
        } else {
            $barrier = 0 - $barrier;
        }
        return $barrier;
    }

    my $option_type = $barrier_kind eq 'low' ? 'VANILLA_PUT' : 'VANILLA_CALL';
    $duration =~ s/t//g;
    $duration = Time::Duration::Concise->new(interval => $duration)->seconds;

    my $volsurface = BOM::MarketData::Fetcher::VolSurface->new->fetch_surface({underlying => $underlying});
    # latest available spot should be sufficient.
    my $current_tick = defined $underlying->spot_tick ? $underlying->spot_tick : $underlying->tick_at(time, {allow_inconsistent => 1});
    return unless $current_tick;

    # volatility should just be an estimate here, let's take it straight off the surface and
    # avoid all the craziness.
    my $tid          = $duration / 86400;
    my $closest_term = find_closest_numbers_around($tid, $volsurface->original_term_for_smile, 2);
    my $volatility   = $volsurface->get_surface_volatility($closest_term->[0], $volsurface->atm_spread_point);

    my $approximate_barrier = get_strike_for_spot_delta({
        delta            => 0.2,
        option_type      => $option_type,
        atm_vol          => $volatility,
        t                => $tid / 365,
        r_rate           => 0,
        q_rate           => 0,
        spot             => $current_tick->quote,
        premium_adjusted => 0,
        forward          => 1
    });

    my $strike = BOM::Product::Contract::Strike->new(
        underlying       => $underlying,
        basis_tick       => $current_tick,
        supplied_barrier => $approximate_barrier,
        barrier_kind     => $barrier_kind,
    );

    my $barrier = $duration >= 86400 ? $strike->as_absolute : $strike->as_difference;

    return $underlying->market->integer_barrier ? floor($barrier) : $barrier;
}

=head2 _quants_config

Builds Quants::Config object

=cut

sub _quants_config {

    return BOM::Config::QuantsConfig->new(chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader());

}

=head2 _get_multiplier_config

Gets multiplier's config

=cut

sub _get_multiplier_config {
    my ($lc_short, $symbol) = @_;

    my $config = _quants_config->get_multiplier_config($lc_short, $symbol) // {};

    return $config;
}

=head2 _get_accumulator_config

Gets accumulators's config

=cut

sub _get_accumulator_config {
    my $symbol = shift;

    my $qc = _quants_config();
    $qc->contract_category('accumulator');
    my $config = $qc->get_per_symbol_config({underlying_symbol => $symbol, need_latest_cache => 1}) // {};

    return $config;
}

=head2 _get_turbos_config

Gets accumulators's config

=cut

sub _get_turbos_config {
    my $symbol = shift;

    my $qc = _quants_config();
    $qc->contract_category('turbos');
    my $config = $qc->get_per_symbol_config({underlying_symbol => $symbol, need_latest_cache => 1}) // {};

    return $config;
}

=head2 _get_callputspread_barrier_range

_get_callputspread_barrier_range will return the callputspread barrier_range name.

=cut

sub _get_callputspread_barrier_range {
    return [{
            display_name => 'tight',
        },
        {
            display_name => 'middle',
        },
        {
            display_name => 'wide',
        }];
}

1;
