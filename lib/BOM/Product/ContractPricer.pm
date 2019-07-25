package BOM::Product::Contract;    ## no critic ( RequireFilenameMatchesPackage )

use strict;
use warnings;

use JSON::MaybeXS;
use Math::Util::CalculatedValue::Validatable;
use List::Util qw(max);
use List::MoreUtils qw(none all);
use Format::Util::Numbers qw/financialrounding/;

use Price::Calculator;
use Quant::Framework::EconomicEventCalendar;
use Quant::Framework::Currency;
use Quant::Framework::CorrelationMatrix;
use Pricing::Engine::EuropeanDigitalSlope;
use Pricing::Engine::TickExpiry;
use Pricing::Engine::BlackScholes;
use Pricing::Engine::Lookback;
use Pricing::Engine::Reset;
use Pricing::Engine::HighLow::Ticks;
use Pricing::Engine::HighLow::Runs;
use LandingCompany::Commission qw(get_underlying_base_commission);

use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::Product::Pricing::Greeks;
use BOM::Config::Chronicle;
use BOM::Config::QuantsConfig;
use BOM::Product::Pricing::Greeks::BlackScholes;
use BOM::Config::Runtime;
use BOM::Product::ContractVol;
use BOM::Market::DataDecimate;
use BOM::Product::Exception;
use BOM::Config;

## ATTRIBUTES  #######################

# Rates calculation, including quanto effects.
has [qw(mu discount_rate)] => (
    is         => 'ro',
    isa        => 'Num',
    lazy_build => 1,
);

has [qw(rho domqqq forqqq fordom)] => (
    is         => 'ro',
    isa        => 'HashRef',
    lazy_build => 1,
);

has priced_with => (
    is         => 'ro',
    isa        => 'Str',
    lazy_build => 1,
);

# a hash reference for slow migration of pricing engine to the new interface.
has new_interface_engine => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_new_interface_engine',
);

# we use pricing_engine_name matching all the time.
has priced_with_intraday_model => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_priced_with_intraday_model',
);

has price_calculator => (
    is         => 'ro',
    isa        => 'Price::Calculator',
    lazy_build => 1,
);

=head2 otm_threshold

An abbreviation for deep out of the money threshold. This is used to floor prices.

=cut

has otm_threshold => (
    is         => 'ro',
    lazy_build => 1,
);

# timeindays/timeinyears - note that for FX contracts of >=1 duration, these values will follow the market convention of integer days
has [
    qw(q_rate
        r_rate
        pricing_mu
        )
    ] => (
    is         => 'rw',
    lazy_build => 1,
    );

=head2 ask_price
=head2 bid_price
=head2 theo_price

These prices should be implemented in the Roles.

Currently, we have BOM::Product::Role::Binary and BOM::Product::Role::NonBinary to calculate these prices

=cut

has [
    qw( bid_price
        theo_price
        )
    ] => (
    is         => 'ro',
    init_arg   => undef,
    lazy_build => 1,
    );

has ask_price => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_ask_price {
    die '_build_ask_price should be over-written';
}

sub _build_bid_price {
    die '_build_bid_price should be over-written';
}

sub _build_theo_price {
    die '_build_theo_price should be over-written';
}

sub _build_app_markup_dollar_amount {
    die '_build_app_markup_dollar_amount should be over-written';
}

has [qw( pricing_engine_name )] => (
    is         => 'rw',
    isa        => 'Str',
    lazy_build => 1,
);

has pricing_engine => (
    is         => 'ro',
    lazy_build => 1,
);

has greek_engine => (
    is         => 'ro',
    isa        => 'BOM::Product::Pricing::Greeks',
    lazy_build => 1,
    handles    => [qw(delta vega theta gamma vanna volga)],
);

# pricing_new - Do we believe this to be a new unsold bet starting now (or later)?

has [qw(
        pricing_new
        )
    ] => (
    is         => 'ro',
    isa        => 'Bool',
    lazy_build => 1,
    );

# Application developer's commission.
# Defaults to 0%
has app_markup_percentage => (
    is      => 'ro',
    default => 0,
);

has [qw(app_markup_dollar_amount app_markup)] => (
    is         => 'ro',
    lazy_build => 1,
);

# base_commission can be overridden on contract type level.
# When this happens, underlying base_commission is ignored.
#
# min_commission_amount - the minimum commission charged per contract.
# E.g. if the payout currency is in USD, the minimum commission we want to charge is 2 cents. (min_commission_amount = 0.02)
has [qw(risk_markup commission_markup base_commission commission_from_stake min_commission_amount)] => (
    is         => 'ro',
    lazy_build => 1,
);

has reset_time => (
    is         => 'ro',
    isa        => 'Num',
    lazy_build => 1,
);

has reset_time_in_years => (
    is         => 'ro',
    isa        => 'Num',
    lazy_build => 1,
);

has reset_spot => (
    is         => 'ro',
    lazy_build => 1,
);

sub commission_multiplier {
    return shift->price_calculator->commission_multiplier(@_);
}

# reset_time is used for actually resetting the barrier.
sub _build_reset_time {
    my $self = shift;

    return 0 unless $self->entry_tick;
    # reset time is the mid time from entry tick epoch to date expiry.
    return $self->entry_tick->epoch + int(($self->date_expiry->epoch - $self->entry_tick->epoch) * 0.5);
}

# reset_time_in_years is used in BS formula. For reset_time_in_years, it cannot be dependent
# on entry_tick otherwise we will not be able to price proposal.
# Based on analysis done, the small difference between date_start and entry_tick epoch is
# negligible.
# On the other hand, the reset_time which is used for actually resetting the barrier,
# we need to be precise, thus using entry_tick epoch made things much simpler because
# basically it is the mid between entry_tick and expiry.
sub _build_reset_time_in_years {
    my $self = shift;

    my $reset_time_in_years = ($self->date_expiry->epoch - $self->date_start->epoch) * 0.5;
    $reset_time_in_years = $reset_time_in_years / (365 * 24 * 60 * 60);
    return $reset_time_in_years;
}

sub _build_reset_spot {
    my $self = shift;

    my $reset_spot = undef;

    if ($self->category_code eq 'reset' and $self->reset_time and $self->date_pricing->epoch > $self->reset_time) {
        if ($self->tick_expiry) {
            my @ticks_since_start = @{$self->ticks_for_tick_expiry};
            my $tick_reset_timing = int($self->tick_count * 0.5);
            if (@ticks_since_start >= ($tick_reset_timing + 1)) {
                $reset_spot = $ticks_since_start[$tick_reset_timing];
            }
        } else {
            $reset_spot = $self->_tick_accessor->tick_at($self->reset_time);
        }
    }

    return $reset_spot;
}

has hour_end_markup_parameters => (
    is         => 'rw',
    lazy_build => 1,
);

sub _build_hour_end_markup_parameters {
    my $self = shift;

    return {} unless ($self->market->name eq 'forex' or $self->market->name eq 'commodities');

    # Do not apply hour end markup if duration is greater than 30 mins
    return {} if ($self->timeindays->amount * 24 * 60) > 30;

    # For forward starting, only applies it if the contract bought at 15 mins before the date_start, other that that it is hard for client to exploit the edge
    return {} if ($self->is_forward_starting && ($self->date_start->epoch - $self->date_pricing->epoch) > 15 * 60);

    my $adj_args = {
        starting_minute     => 50,
        end_minute          => 5,
        max_starting_minute => 57,
        max_end_minute      => 2

    };

    my $start_minute = $self->date_start->minute;
    my $start_hour   = $self->date_start->hour;
    # Do not apply markup if it is not between 50 minutes of the hour to 5 minutes of next hour
    return {} if $start_minute > $adj_args->{end_minute} and $start_minute < $adj_args->{starting_minute};

    my $high_low_lookback_from;

    if ($start_minute >= $adj_args->{starting_minute}) {
        # For contract starts at 14:57GMT, we will get high low from 14GMT
        $high_low_lookback_from = $self->date_start->minus_time_interval($self->date_start->epoch % 3600);
    } else {
        # For contract starts at 15:02GMT, we will get high low from 14GMT
        $high_low_lookback_from = $self->date_start->minus_time_interval($self->date_start->epoch % 3600 + 3600);
    }

    # We did not do any ajdusment if there is nothing to lookback ie either monday morning or the next day after early close
    return {} unless $self->trading_calendar->is_open_at($self->underlying->exchange, $high_low_lookback_from);

    # set the parameters to be used for markup parameters
    return {
        date_start          => $self->date_start,
        duration            => $self->timeindays->amount * 24 * 60,
        searching_date      => $high_low_lookback_from->plus_time_interval('1h'),
        symbol              => ($self->underlying->submarket->name eq 'major_pairs' ? $self->underlying->symbol : $self->underlying->submarket->name),
        high_low            => $self->spot_min_max($high_low_lookback_from),
        is_forward_starting => $self->is_forward_starting,
        adj_args            => $adj_args,
        current_spot        => $self->_pricing_args->{spot},
        contract_type       => $self->pricing_code
    };

}

sub spot_min_max {
    my ($self, $from) = @_;

    my $from_epoch = $from->epoch;

    my $to_epoch =
          $self->date_pricing->is_after($self->date_expiry) ? $self->date_expiry->epoch
        : $self->is_forward_starting                        ? $self->date_start->epoch
        :                                                     $self->date_pricing->epoch;
    # When price a contract at the date start, the date pricing == date start
    # However, for price a lookback contract, we always excluded tick at date start (ie from is set to date_start +1)
    # Hence we need to cap the to epoch as follow
    $to_epoch = $self->sell_time if $self->category_code eq 'lookback' and $self->sell_time and $self->sell_time < $self->date_expiry->epoch;
    $to_epoch = max($from_epoch, $to_epoch);
    my $duration = $to_epoch - $from_epoch;

    my ($high, $low);
    if ($self->date_pricing->epoch > $from->epoch) {
        #Let's be more defensive here and use date pricing as well to determine the backprice flag.
        my $backprice = (defined $self->underlying->for_date or $self->date_pricing->is_after($self->date_expiry)) ? 1 : 0;
        my $decimate = BOM::Market::DataDecimate->new({market => $self->market->name});
        my $use_decimate = $self->category_code eq 'lookback' ? 0 : $duration <= 900 ? 0 : 1;
        my $ticks = $decimate->get({
            underlying  => $self->underlying,
            start_epoch => $from_epoch,
            end_epoch   => $to_epoch,
            backprice   => $backprice,
            decimate    => $use_decimate,
        });

        my @quotes = map { $_->{quote} } @$ticks;
        $low  = min(@quotes);
        $high = max(@quotes);
    }

    my $high_low = {
        high => $high // $self->pricing_spot,
        low  => $low  // $self->pricing_spot,
    };

    return $high_low;
}

sub _create_new_interface_engine {
    my $self = shift;
    return if not $self->new_interface_engine;

    my %pricing_parameters;

    my $payouttime_code = ($self->payouttime eq 'hit') ? 0 : 1;

    if ($self->pricing_engine_name eq 'Pricing::Engine::Digits') {
        %pricing_parameters = (
            strike => $self->barrier ? $self->barrier->as_absolute : undef,
            contract_type => $self->pricing_code,
        );
    } elsif ($self->pricing_engine_name eq 'Pricing::Engine::HighLow::Ticks' or $self->pricing_engine_name eq 'Pricing::Engine::HighLow::Runs') {
        %pricing_parameters = (
            contract_type => $self->pricing_code,
            selected_tick => $self->selected_tick,
        );
    } elsif ($self->pricing_engine_name eq 'Pricing::Engine::TickExpiry') {
        my $backprice = ($self->underlying->for_date) ? 1 : 0;
        %pricing_parameters = (
            apply_equal_tick_discount => 0,                           # do not discount for all pairs
            contract_type             => $self->pricing_code,
            underlying_symbol         => $self->underlying->symbol,
            date_start                => $self->effective_start,
            date_pricing              => $self->date_pricing,
            ticks                     => [
                reverse @{
                    $self->_tick_accessor->ticks_in_between_end_limit({
                            end_time => $self->date_start->epoch,
                            limit    => 20,
                        })}
            ],
            economic_events   => _generate_market_data($self->underlying, $self->date_start)->{economic_events},
            custom_commission => $self->_custom_commission,
            barrier_tier      => $self->barrier_tier,
        );
    } else {

        my %contract_config = (
            contract_type     => $self->pricing_code,
            underlying_symbol => $self->underlying->symbol,
            date_start        => $self->effective_start,
            date_pricing      => $self->date_pricing,
            date_expiry       => $self->date_expiry,
            payouttime_code   => $payouttime_code,
            for_date          => $self->underlying->for_date,
            spot              => $self->pricing_spot,
            strikes           => [grep { $_ } values %{$self->barriers_for_pricing}],
            priced_with       => $self->priced_with,
            payout_type       => $self->payout_type,
            is_atm_contract   => $self->is_atm_bet,
        );
        if ($self->pricing_engine_name eq 'Pricing::Engine::EuropeanDigitalSlope') {
            #pricing_vol can be calculated using an empirical vol. So we have to sent the raw numbers
            my $apply_equal_tie_markup = ((
                           $self->code eq 'CALLE'
                        or $self->code eq 'PUTE'
                )
                    and ($self->underlying->submarket->name eq 'major_pairs' or $self->underlying->submarket->name eq 'minor_pairs')) ? 1 : 0;
            %pricing_parameters = (
                %contract_config,
                chronicle_reader           => BOM::Config::Chronicle::get_chronicle_reader($self->underlying->for_date),
                apply_equal_tie_markup     => $apply_equal_tie_markup,
                discount_rate              => $self->discount_rate,
                mu                         => $self->mu,
                vol                        => $self->pricing_vol_for_two_barriers // $self->pricing_vol,
                q_rate                     => $self->q_rate,
                r_rate                     => $self->r_rate,
                volsurface                 => $self->volsurface->surface,
                volsurface_creation_date   => $self->volsurface->creation_date,
                hour_end_markup_parameters => $self->hour_end_markup_parameters,
            );
        } elsif ($self->pricing_engine_name eq 'Pricing::Engine::BlackScholes') {
            %pricing_parameters = (
                %contract_config,
                t             => $self->timeinyears->amount,
                discount_rate => $self->discount_rate,
                mu            => $self->mu,
                vol           => $self->pricing_vol_for_two_barriers // $self->pricing_vol,
            );
        } elsif ($self->pricing_engine_name eq 'Pricing::Engine::Reset') {
            %pricing_parameters = (
                %contract_config,
                contract_type => $self->pricing_code,
                t             => $self->timeinyears->amount,
                reset_time    => $self->reset_time_in_years,
                discount_rate => $self->discount_rate,
                mu            => $self->mu,
                vol           => $self->pricing_vol,
            );
        } elsif ($self->pricing_engine_name eq 'Pricing::Engine::Lookback') {

            %pricing_parameters = (
                strikes         => [grep { $_ } values %{$self->barriers_for_pricing}],
                spot            => $self->pricing_spot,
                discount_rate   => $self->discount_rate,
                t               => $self->timeinyears->amount,
                mu              => $self->mu,
                vol             => $self->pricing_vol,
                payouttime_code => $payouttime_code,
                payout_type     => 'non-binary',
                contract_type   => $self->pricing_code,
                spot_max        => $self->spot_min_max($self->date_start_plus_1s)->{high},
                spot_min        => $self->spot_min_max($self->date_start_plus_1s)->{low},
            );

        } else {
            die "Unknown pricing engine: " . $self->pricing_engine_name;
        }
    }

    if (my @missing_parameters = grep { !exists $pricing_parameters{$_} } @{$self->pricing_engine_name->required_args}) {
        die "Missing pricing parameters for engine " . $self->pricing_engine_name . " - " . join ',', @missing_parameters;
    }

    return $self->pricing_engine_name->new(%pricing_parameters);
}

sub _generate_market_data {
    my ($underlying, $date_start) = @_;

    my $for_date = $underlying->for_date;
    my $result   = {};

    #this is a list of symbols which are applicable when getting important economic events.
    #Note that other than currency pair of the fx symbol, we include some other important currencies
    #here because any event for these currencies, can potentially affect all other currencies too
    my %applicable_symbols = (
        USD                                 => 1,
        AUD                                 => 1,
        CAD                                 => 1,
        CNY                                 => 1,
        NZD                                 => 1,
        $underlying->quoted_currency_symbol => 1,
        $underlying->asset_symbol           => 1,
    );

    my $ee = Quant::Framework::EconomicEventCalendar->new({
            chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader($for_date),
        }
        )->get_latest_events_for_period({
            from => $date_start->minus_time_interval('10m'),
            to   => $date_start->plus_time_interval('10m')
        },
        $for_date
        );

    my @applicable_news =
        sort { $a->{release_date} <=> $b->{release_date} } grep { $applicable_symbols{$_->{symbol}} } @$ee;

    #as of now, we only update the result with a raw list of economic events, later that we move to other
    #engines, we will add other market-data items too (e.g. dividends, vol-surface, ...)
    $result->{economic_events} = \@applicable_news;
    return $result;
}

=head2 market_is_inefficient

Returns true or false. Note that the value may vary depending on date_pricing.

=cut

sub market_is_inefficient {
    my $self = shift;

    # market inefficiency only applies to forex and commodities.
    return 0 unless ($self->market->name eq 'forex' or $self->market->name eq 'commodities');
    return 0 if $self->expiry_daily;

    my $hour = $self->date_pricing->hour + 0;
    # only 20:00/21:00 GMT to end of day
    my $disable_hour = $self->date_pricing->is_dst_in_zone('America/New_York') ? 20 : 21;
    return 0 if $hour < $disable_hour;
    return 1;
}

## BUILDERS  #######################

sub _build_domqqq {
    my $self = shift;

    my $result = {};

    if ($self->priced_with eq 'quanto') {
        my $prefix = $self->payout_currency_type eq 'crypto' ? 'cry' : 'frx';
        $result->{underlying} = create_underlying({
            symbol   => $prefix . $self->underlying->quoted_currency_symbol . $self->currency,
            for_date => $self->underlying->for_date
        });
        $result->{volsurface} = $self->_volsurface_fetcher->fetch_surface({
            underlying => $result->{underlying},
        });
    } else {
        $result = $self->fordom;
    }

    return $result;
}

sub _build_forqqq {
    my $self = shift;

    my $result = {};

    if ($self->priced_with eq 'quanto' and ($self->underlying->market->name eq 'forex' or $self->underlying->market->name eq 'commodities')) {
        my $prefix = $self->payout_currency_type eq 'crypto' ? 'cry' : 'frx';
        $result->{underlying} = create_underlying({
            symbol   => $prefix . $self->underlying->asset_symbol . $self->currency,
            for_date => $self->underlying->for_date
        });

        $result->{volsurface} = $self->_volsurface_fetcher->fetch_surface({
            underlying => $result->{underlying},
        });

    } else {
        $result = $self->domqqq;
    }

    return $result;
}

sub _build_otm_threshold {
    my $self = shift;

    # this is the default depp OTM threshold set in yaml per market
    return $self->market->deep_otm_threshold;
}

sub _build_app_markup {
    return shift->price_calculator->app_markup;
}

#this is supposed to be called for legacy pricing engines (not new interface)
sub _build_risk_markup {
    my $self = shift;

    my $base_amount = 0;
    if ($self->pricing_engine and $self->pricing_engine->can('risk_markup')) {
        $base_amount = $self->new_interface_engine ? $self->pricing_engine->risk_markup : $self->pricing_engine->risk_markup->amount;
    } elsif ($self->new_interface_engine) {
        $base_amount = $self->debug_information->{risk_markup}->{amount};
    }

    return Math::Util::CalculatedValue::Validatable->new({
        name        => 'risk_markup',
        description => 'Risk markup for a pricing model',
        set_by      => $self->pricing_engine_name,
        base_amount => $base_amount,
    });
}

# TODO: The commission structure should be incorporated in the tool that we used to set potential/realized loss limit. Existing hard-coded implementation is bad practice!
sub _build_base_commission {
    my $self = shift;

    my $market_name        = $self->market->name;
    my $per_market_scaling = BOM::Config::Runtime->instance->app_config->quants->commission->adjustment->per_market_scaling->$market_name;
    my $args               = {underlying_symbol => $self->underlying->symbol};
    if ($self->can('landing_company')) {
        $args->{landing_company} = $self->landing_company;
    }
    my $underlying_base = get_underlying_base_commission($args);

    if (my $custom_commission = $self->risk_profile->get_commission()) {
        $underlying_base = $custom_commission;
    }

    if (not $self->for_sale and $self->market->name eq 'volidx' and $self->tick_expiry and $self->category_code eq 'touchnotouch') {
        # We are adding another extra 2 percent to cover touch no touch tick trade.
        # The approximated discrete-monitoring prices (for one/double touch) underestimate the true prices for tick trades.
        # The discrete_monitoring_adj_markup is applied to push prices up just above the true prices.
        $underlying_base = $underlying_base + 0.02;
    }

    # apply reduced commission for major_pairs on forex intraday ATM on european hours. Normal hours, base_commission is set to 0.035.
    my $pricing_hour = $self->date_pricing->hour;
    if (    $self->priced_with_intraday_model
        and $self->underlying->submarket->name eq 'major_pairs'
        and $self->is_atm_bet
        and $pricing_hour >= 6
        and $pricing_hour <= 16)
    {
        $underlying_base = 0.03;
    }

    if (not $self->for_sale and $self->market->name eq 'volidx' and $self->tick_expiry and $self->category_code eq 'runs') {
        # For Runs the theo probability decreases sharply with an increase in number of ticks,
        # hence a fixed % of payout as commission makes contracts fairly expensive.
        # As an example a 1.5% commission on payout for a 5-tick contract would result in a 48% charge on theo price (e.g  `0.015/(1/2^5) == 0.48` or 48%).
        # This is when generally a 5 tick Rise/Fall contract has a commission around 3% of the theo price.

        # For Runs, we aim for a 4.8% constant commission in relation to theo probability (e.g `commission/theo = 0.048`, with `theo = 1/2^tick_count`).
        my $consistent_commission = [
            undef,
            undef,
            0.012,     # 2 ticks
            0.006,     # 3 ticks
            0.003,     # 4 ticks
            0.0015,    # 5 ticks
        ]->[$self->selected_tick];

        unless ($consistent_commission) {
            # We need to cater for commission if we decided to extend duration of 'runs'
            return BOM::Product::Exception->throw(
                error_code => 'InvalidTickExpiry',
                error_args => [$self->code],
            );
        }

        $underlying_base = $consistent_commission;
    }

    return $underlying_base * $per_market_scaling / 100;
}

sub _build_commission_markup {
    my $self = shift;

    # commission_markup needs theo_probability and min_commission_amount
    $self->price_calculator->theo_probability($self->theo_probability);
    $self->price_calculator->min_commission_amount($self->min_commission_amount);
    return $self->price_calculator->commission_markup;
}

sub _build_commission_from_stake {
    my $self = shift;

    # commission_from_stake needs theo_probability and commission_markup
    $self->price_calculator->theo_probability($self->theo_probability);
    $self->price_calculator->commission_markup($self->commission_markup);
    return $self->price_calculator->commission_from_stake;
}

sub _build_new_interface_engine {
    my $self = shift;

    my %engines = (
        'Pricing::Engine::BlackScholes'         => 1,
        'Pricing::Engine::Digits'               => 1,
        'Pricing::Engine::TickExpiry'           => 1,
        'Pricing::Engine::EuropeanDigitalSlope' => 1,
        'Pricing::Engine::Lookback'             => 1,
        'Pricing::Engine::HighLow::Ticks'       => 1,
        'Pricing::Engine::HighLow::Runs'        => 1,
        'Pricing::Engine::Reset'                => 1,
    );

    return $engines{$self->pricing_engine_name} // 0;
}

sub _build_fordom {
    my $self = shift;

    return {
        underlying => $self->underlying,
        volsurface => $self->volsurface,
    };
}

sub _build_discount_rate {
    my $self = shift;

    # not needing discount rate for intraday & tick
    # This is done for buy optimisation
    return 0 if $self->market->name eq 'volidx' and not $self->expiry_daily;

    my %args = (
        symbol => $self->currency,
        $self->underlying->for_date ? (for_date => $self->underlying->for_date) : (),
        chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader($self->underlying->for_date),
        chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
    );
    my $curr_obj = Quant::Framework::Currency->new(%args);

    return $curr_obj->rate_for($self->timeinyears->amount);
}

sub _build_priced_with {
    my $self = shift;

    my $underlying = $self->underlying;

    # Everything should have a quoted currency, except our randoms.
    # However, rather than check for random directly, just do a numeraire bet if we don't know what it is.
    my $priced_with;
    if ($underlying->quoted_currency_symbol eq $self->currency or (none { $underlying->market->name eq $_ } (qw(forex commodities indices)))) {
        $priced_with = 'numeraire';
    } elsif ($underlying->asset_symbol eq $self->currency) {
        $priced_with = 'base';
    } else {
        $priced_with = 'quanto';
    }

    # price with numeraire if payout currency is crypto. We are only skipping for non_stable_coins
    if ($underlying->submarket->name eq 'smart_fx' or $self->currency =~ /(?:BTC|BCH|ETH|ETC|LTC)/) {
        $priced_with = 'numeraire';
    }

    return $priced_with;
}

sub _build_mu {
    my $self = shift;

    my $mu = $self->r_rate - $self->q_rate;

    if (first { $self->underlying->market->name eq $_ } (qw(forex commodities indices))) {
        my $rho = $self->rho->{fd_dq};
        my $vol = $self->atm_vols;
        # See [1] for Quanto Formula
        $mu = $self->r_rate - $self->q_rate - $rho * $vol->{fordom} * $vol->{domqqq};
    }

    return $mu;
}

sub _build_rho {

    my $self     = shift;
    my $atm_vols = $self->atm_vols;
    my $w        = ($self->domqqq->{underlying}->inverted) ? -1 : 1;

    my %rhos;

    $rhos{fd_dq} = 0;

    if ($self->priced_with eq 'numeraire') {
        $rhos{fd_dq} = 0;
    } elsif ($self->priced_with eq 'base') {
        $rhos{fd_dq} = -1;
    } elsif ($self->underlying->market->name eq 'forex' or $self->underlying->market->name eq 'commodities') {
        $rhos{fd_dq} =
            $w * (($atm_vols->{forqqq}**2 - $atm_vols->{fordom}**2 - $atm_vols->{domqqq}**2) / (2 * $atm_vols->{fordom} * $atm_vols->{domqqq}));
    } elsif ($self->underlying->market->name eq 'indices') {
        my $cr             = BOM::Config::Chronicle::get_chronicle_reader($self->underlying->for_date);
        my $construct_args = {
            symbol           => $self->underlying->market->name,
            for_date         => $self->underlying->for_date,
            chronicle_reader => $cr,
        };
        my $rho_data           = Quant::Framework::CorrelationMatrix->new($construct_args);
        my $expiry_conventions = Quant::Framework::ExpiryConventions->new(
            underlying       => $self->underlying,
            chronicle_reader => $cr,
            calendar         => $self->trading_calendar,
        );

        my $index           = $self->underlying->asset_symbol;
        my $payout_currency = $self->currency;
        my $tiy             = $self->timeinyears->amount;

        $rhos{fd_dq} = $rho_data->correlation_for($index, $payout_currency, $tiy, $expiry_conventions);
    }

    return \%rhos;
}

sub _build_price_calculator {
    my $self = shift;

    return Price::Calculator->new({
        currency              => $self->currency,
        deep_otm_threshold    => $self->otm_threshold,
        base_commission       => $self->base_commission,
        app_markup_percentage => $self->app_markup_percentage,
        # due to discount on end of hour, we just want to have a safety net to make sure we don't go below 0.45
        ($self->priced_with_intraday_model and $self->is_atm_bet) ? (minimum_ask_probability => 0.45) : (),
        ($self->has_commission_markup)      ? (commission_markup      => $self->commission_markup)      : (),
        ($self->has_commission_from_stake)  ? (commission_from_stake  => $self->commission_from_stake)  : (),
        ($self->has_payout)                 ? (payout                 => $self->payout)                 : (),
        ($self->has_ask_price)              ? (ask_price              => $self->ask_price)              : (),
        ($self->has_theo_probability)       ? (theo_probability       => $self->theo_probability)       : (),
        ($self->has_ask_probability)        ? (ask_probability        => $self->ask_probability)        : (),
        ($self->has_discounted_probability) ? (discounted_probability => $self->discounted_probability) : (),
    });
}

sub _build_greek_engine {
    my $self = shift;
    return BOM::Product::Pricing::Greeks::BlackScholes->new({bet => $self});
}

sub _build_pricing_engine_name {
    my $self = shift;

    #For Volatility indices, we use plain BS formula for pricing instead of VV/Slope
    return 'Pricing::Engine::BlackScholes' if $self->market->name eq 'volidx';

    my $engine_name = $self->is_path_dependent ? 'BOM::Product::Pricing::Engine::VannaVolga::Calibrated' : 'Pricing::Engine::EuropeanDigitalSlope';

    if ($self->tick_expiry) {
        my @symbols = create_underlying_db->get_symbols_for(
            market            => 'forex',     # forex is the only financial market that offers tick expiry contracts for now.
            contract_category => 'callput',
            expiry_type       => 'tick',
        );
        $engine_name = 'Pricing::Engine::TickExpiry' if _match_symbol(\@symbols, $self->underlying->symbol);
    } elsif (my $intraday_engine_name = $self->_check_intraday_engine_compatibility) {
        $engine_name = $intraday_engine_name;
    }

    return $engine_name;
}

sub _check_intraday_engine_compatibility {
    my $self = shift;

    my $engine_name =
        $self->market->name eq 'indices' ? 'BOM::Product::Pricing::Engine::Intraday::Index' : 'BOM::Product::Pricing::Engine::Intraday::Forex';

    return $engine_name->get_compatible('basic', $self->metadata);
}

sub _build_pricing_engine {
    my $self = shift;

    return $self->_create_new_interface_engine if $self->new_interface_engine;

    my $pricing_engine = $self->pricing_engine_name->new({
            bet                => $self,
            inefficient_period => $self->market_is_inefficient,
            $self->priced_with_intraday_model
            ? (
                economic_events   => $self->economic_events_for_volatility_calculation,
                custom_commission => $self->_custom_commission
                )
            : (),
        });

    return $pricing_engine;
}

sub _build_pricing_mu {
    my $self = shift;

    return $self->mu;
}

sub _build_r_rate {
    my $self = shift;

    return $self->underlying->interest_rate_for($self->timeinyears->amount);
}

sub _build_q_rate {
    my $self = shift;

    my $underlying = $self->underlying;
    my $q_rate     = $underlying->dividend_rate_for($self->timeinyears->amount);

    return $q_rate;
}

sub _build_pricing_new {
    my $self = shift;

    $self->date_pricing;
    # do not use $self->date_pricing here because milliseconds matters!
    # _date_pricing_milliseconds will not be set if date_pricing is not built.
    my $time = $self->_date_pricing_milliseconds // $self->date_pricing->epoch;
    return 0 if $time > $self->date_start->epoch;
    return 1;
}

sub _match_symbol {
    my ($lists, $symbol) = @_;
    for (@$lists) {
        return 1 if $_ eq $symbol;
    }
    return;
}

sub _build_min_commission_amount {
    my $self = shift;

    my $static = BOM::Config::quants;

    return $static->{bet_limits}->{min_commission_amount}->{$self->currency} // 0;
}

has _custom_commission => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build__custom_commission {
    my $self = shift;

    my $for_date = $self->underlying->for_date;
    my $qc       = BOM::Config::QuantsConfig->new(
        chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader($for_date),
        for_date         => $for_date
    );

    return $qc->get_config(
        'commission',
        +{
            contract_type     => $self->code,
            underlying_symbol => $self->underlying->symbol
        });
}

1;
