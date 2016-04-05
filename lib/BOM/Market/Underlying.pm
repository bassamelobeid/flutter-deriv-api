package BOM::Market::Underlying;
use 5.010;
use Moose;

=head1 NAME

BOM::Market::Underlying

=head1 DESCRIPTION

The representation of underlyings within our system

my $underlying = BOM::Market::Underlying->new($underlying_symbol);

=cut

use open qw[ :encoding(UTF-8) ];
use BOM::Market::Types;

use Carp;
use List::MoreUtils qw( any );
use List::Util qw( first max min);
use Scalar::Util qw( looks_like_number );
use BOM::Utility::Log4perl qw( get_logger );
use Memoize;
use Finance::Asset;

use Cache::RedisDB;
use Date::Utility;
use BOM::Market::Asset;
use BOM::Market::Currency;
use BOM::Market::Exchange;
use BOM::Market::SubMarket::Registry;
use BOM::Market;
use BOM::Market::Registry;
use Format::Util::Numbers qw(roundnear);
use Time::Duration::Concise;
use BOM::Platform::Runtime;
use BOM::Market::Data::DatabaseAPI;
use Quant::Framework::CorporateAction;
use BOM::Platform::Context qw(request localize);
use POSIX;
use Try::Tiny;
use BOM::Market::Types;
use YAML::XS qw(LoadFile);
use BOM::Platform::Static::Config;

with 'BOM::Market::Role::ExpiryConventions';

our $PRODUCT_OFFERINGS = LoadFile('/home/git/regentmarkets/bom-market/config/files/product_offerings.yml');

=head1 METHODS

=cut

=head2 new($symbol, [$for_date])

Return BOM::Market::Underlying object for given I<$symbol>. possibly at a given I<Date::Utility>.

=cut

sub new {
    my ($self, $args, $when) = @_;

    $args = {symbol => $args} if (not ref $args);
    my $symbol = $args->{symbol};

    croak 'No symbol provided to constructor.' if (not $symbol);

    delete $args->{for_date}
        if (exists $args->{for_date} and not defined $args->{for_date});
    $args->{for_date} = $when if ($when);

    my $obj;

    if (scalar keys %{$args} == 1) {

        # Symbol only requests can use cache.
        my $cache = Finance::Asset->instance->cached_underlyings;
        if (not $cache->{$symbol}) {
            my $new_obj = $self->_new($args);
            $symbol = $new_obj->symbol;
            $cache->{$symbol} = $new_obj;
        }
        $obj = $cache->{$symbol};
    } else {
        $obj = $self->_new($args);
    }

    return $obj;
}

=head2 comment

Internal use annotation.

=cut

has 'comment' => (
    is      => 'ro',
    isa     => 'Str',
    default => '',
);

=head2 for_date

The Date::Utility wherein this underlying is fixed.

=cut

has 'for_date' => (
    is      => 'ro',
    isa     => 'Maybe[Date::Utility]',
    default => undef,
);

=head2 inefficient_periods

Parts of the days wherein the market does not show proper efficiency

=cut

has inefficient_periods => (
    is      => 'ro',
    isa     => 'ArrayRef[HashRef]',
    default => sub { return []; },
);

=head2 symbol

What is the proper-cased symbol for our underlying?

=cut

has 'symbol' => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

# Can not be made into an attribute to avoid the caching problem.

=head2 system_symbol

The symbol used by the system to look up data.  May be different from symbol, particularly on inverted forex pairs.

=cut

has 'system_symbol' => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_system_symbol {
    my $self = shift;

    return ($self->inverted)
        ? 'frx' . $self->quoted_currency_symbol . $self->asset_symbol
        : $self->symbol;
}

=head2 delay_amount

The amount by which we much delay the feed for display

=cut

has delay_amount => (
    is         => 'ro',
    isa        => 'Num',
    lazy_build => 1,
);

#This really has to constructed in conjunction with feed_licence
sub _build_delay_amount {
    my $self = shift;

    my $license = $self->feed_license;

    my $delay_amount = ($license eq 'realtime') ? 0 : $self->exchange->delay_amount;

    return $delay_amount;
}

has [qw(
        asset_symbol
        volatility_surface_type
        quoted_currency_symbol
        combined_folder
        commission_level
        uses_dst_shifted_seasonality
        spot_spread
        spot_spread_size
        instrument_type
        )
    ] => (
    is         => 'ro',
    lazy_build => 1,
    );

has 'market' => (
    is         => 'ro',
    isa        => 'bom_financial_market',
    lazy_build => 1,
    coerce     => 1,
);

has _feed_license => (
    is => 'ro',
);

has asset => (
    is         => 'ro',
    lazy_build => 1,
);

has quoted_currency => (
    is         => 'ro',
    isa        => 'Maybe[BOM::Market::Currency]',
    lazy_build => 1,
);

has [qw(
        inverted
        quanto_only
        )
    ] => (
    is      => 'ro',
    isa     => 'Bool',
    default => 0,
    );

has contracts => (
    is         => 'ro',
    isa        => 'HashRef',
    lazy_build => 1,
);

sub _build_contracts {
    my $self = shift;

    return {} if $self->quanto_only;
    return $PRODUCT_OFFERINGS->{$self->symbol} // {};
}

has submarket => (
    is      => 'ro',
    isa     => 'bom_submarket',
    coerce  => 1,
    default => 'config',
);

has forward_tickers => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub { return {}; },
);

has providers => (
    is         => 'ro',
    lazy_build => 1,
);

=head2 providers

A list of feed providers for this underlying in the order of priority.

=cut

sub _build_providers {
    my $self = shift;

    return $self->market->providers;

}

=head2 outlier_tick

Allowed percentage move between consecutive ticks

=cut

has outlier_tick => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_outlier_tick {
    my $self = shift;

    return ($self->quanto_only) ? 0.10 : $self->submarket->outlier_tick;
}

=head2 outlier_tick

Allowed percentage move between consecutive ticks when is crosses weekend/holiday

=cut

has weekend_outlier_tick => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_weekend_outlier_tick {
    my $self = shift;
    return max($self->outlier_tick, $self->submarket->weekend_outlier_tick);
}

has forward_feed => (
    is      => 'ro',
    isa     => 'Bool',
    default => 0,
);

has 'feed_api' => (
    is      => 'ro',
    isa     => 'BOM::Market::Data::DatabaseAPI',
    handles => {
        ticks_in_between_start_end   => 'ticks_start_end',
        ticks_in_between_start_limit => 'ticks_start_limit',
        ticks_in_between_end_limit   => 'ticks_end_limit',
        ohlc_between_start_end       => 'ohlc_start_end',
        next_tick_after              => 'tick_after',
    },
    lazy_build => 1,
);

has 'intradays_must_be_same_day' => (
    is         => 'ro',
    isa        => 'Bool',
    lazy_build => 1,
);

sub _build_intradays_must_be_same_day {
    my $self = shift;

    return $self->submarket->intradays_must_be_same_day;
}

=head2 max_suspend_trading_feed_delay

The maximum acceptable feed delay for an underlying.
Trading will be suspended if feed delay exceeds this threshold.

=cut

has 'max_suspend_trading_feed_delay' => (
    is         => 'ro',
    isa        => 'bom_time_interval',
    lazy_build => 1,
    coerce     => 1,
);

sub _build_max_suspend_trading_feed_delay {
    my $self = shift;

    return $self->submarket->max_suspend_trading_feed_delay;
}

=head2 max_failover_feed_delay

The threshold to fail over to secondary feed provider.

=cut

has max_failover_feed_delay => (
    is         => 'ro',
    isa        => 'bom_time_interval',
    lazy_build => 1,
    coerce     => 1,
);

sub _build_max_failover_feed_delay {
    my $self = shift;

    return $self->submarket->max_failover_feed_delay;
}

has [qw(sod_blackout_start eod_blackout_start eod_blackout_expiry)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_sod_blackout_start {
    my $self = shift;
    return $self->submarket->sod_blackout_start;
}

sub _build_eod_blackout_start {
    my $self = shift;
    return $self->submarket->eod_blackout_start;
}

sub _build_eod_blackout_expiry {
    my $self = shift;
    return $self->submarket->eod_blackout_expiry;
}

###
# End of Attribute section
###

###
# Moose lets us munge up the arguments to the constructor before we build the object.
# This is the function which actually does that.  Try to keep it as simple as possible.
# In fact, simplifying it as it stands would be cool.
###

around BUILDARGS => sub {
    my $orig       = shift;
    my $class      = shift;
    my $params_ref = shift;

    # Proper casing.
    $params_ref->{'symbol'} =~ s/^FRX/frx/i;
    $params_ref->{'symbol'} =~ s/^RAN/ran/i;

    # Basically if we don't have parameters this underlying doesn't exist, but
    # we have volatilities and etc, which shouldn't be here IMO, but
    # unfortunately they are

    my $params = Finance::Asset->instance->get_parameters_for($params_ref->{symbol});
    if ($params) {
        @$params_ref{keys %$params} = @$params{keys %$params};
    } elsif ($params_ref->{'symbol'} =~ /^frx/) {
        my $requested_symbol = $params_ref->{symbol};

        # This might be an inverted pair from what we expected.
        my $asset = substr($params_ref->{symbol}, 3, 3);
        my $quoted = substr($params_ref->{symbol}, 6);

        my $inverted_symbol = 'frx' . $quoted . $asset;

        $params = Finance::Asset->instance->get_parameters_for($inverted_symbol);
        if ($params) {
            @$params_ref{keys %$params} = @$params{keys %$params};
            $params_ref->{inverted} = 1;
        } else {
            get_logger()->debug("Forex underlying does not exist in yml file [" . $params_ref->{symbol} . "]");
        }
        $params_ref->{symbol}          = $requested_symbol;
        $params_ref->{asset}           = $asset;
        $params_ref->{quoted_currency} = $quoted;
    } elsif ($params_ref->{symbol} ne 'HEARTB') {
        get_logger()->debug("Underlying does not exist in yml file [" . $params_ref->{symbol} . "]");
    }

    # Pre-convert to seconds.  let underlyings.yml have easy to read.
    # These don't change from day to day.
    my @seconds;
    foreach my $ie (@{$params_ref->{inefficient_periods}}) {
        foreach my $key (qw(start end)) {
            $ie->{$key} = Time::Duration::Concise->new(
                interval => $ie->{$key},
            )->seconds;
        }
        push @seconds, $ie;
    }
    $params_ref->{inefficient_periods} = \@seconds;

    $params_ref->{asset_symbol} = $params_ref->{asset}
        if (defined $params_ref->{asset});
    delete $params_ref->{asset};
    $params_ref->{quoted_currency_symbol} = $params_ref->{quoted_currency}
        if (defined $params_ref->{quoted_currency});
    delete $params_ref->{quoted_currency};

    # Force re-evaluation.
    if ($params_ref->{feed_license}) {
        $params_ref->{_feed_license} = $params_ref->{feed_license};
        delete $params_ref->{feed_license};
    }

    return $class->$orig($params_ref);
};

=head2 uses_dst_shifted_seasonality

Indicate whether the seasonality trend of this underlying need to be shifted by Day Light Saving

=cut

has 'uses_dst_shifted_seasonality' => (
    is      => 'ro',
    isa     => 'Bool',
    default => 0,
);

=head2 commission_level

At what level do we charge commissions on this underlying?

=cut

sub _build_commission_level {
    my $self = shift;

    # For some reason this was unset, so make it the current max: 3
    return 3;
}

=head2 spot_spread_size

The number of pips in the expected bid-ask spread.

Presently hard-coded.


=cut

sub _build_spot_spread_size {

    # Assume 50 pips if it's not set in the YAML.
    return 50;
}

=head2 spot_spread

The bid-ask spread we see on this underlying.

Right now using hard-coded values.

=cut

sub _build_spot_spread {
    my $self = shift;

    return $self->spot_spread_size * $self->pip_size;
}

=head2 market

Returns which market this underlying is a part of. This is largely used on the
front end to seperate stocks, forex, commodoties, etc into categories. Note that
the market is normally taken from the underlyings.yml, this sub is called only
for underlyings not in the file.

=cut

sub _build_market {
    my $self = shift;

    # The default market is config.
    my $symbol = uc $self->symbol;
    my $market = BOM::Market->new({name => 'nonsense'});
    if ($symbol =~ /^FUT/) {
        $market = BOM::Market::Registry->instance->get('futures');
    } elsif ($symbol eq 'HEARTB' or $symbol =~ /^I_/) {
        $market = BOM::Market::Registry->instance->get('config');
    } elsif (length($symbol) >= 15) {
        $market = BOM::Market::Registry->instance->get('config');
        get_logger()->warn("Unknown symbol, symbol[$symbol]");
    }

    return $market;
}

sub _build_volatility_surface_type {
    my $self = shift;
    my $type = $self->submarket->volatility_surface_type ? $self->submarket->volatility_surface_type : $self->market->volatility_surface_type;
    return $type;
}

=head2 submarket

Returns the SubMarket on which this underlying can be found.
Required.

=head2 instrument_type

Returns what type of instrument it is (useful for knowing whether it is prone to
stock splits or jumpy random movements. Most of the time, the type will be taken
from underlyings.yml

=cut

sub _build_instrument_type {
    my $self            = shift;
    my $market          = $self->market;
    my $instrument_type = '';

    if (scalar grep { $market->name eq $_ } qw(config futures forex)) {
        $instrument_type = $market->name;
    }

    return $instrument_type;
}

=head2 display_name

User friendly name for the underlying

=cut

has display_name => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_display_name {
    my ($self) = @_;
    return uc $self->symbol;
}

=head2 translated_display_name

Returns a name for the underlying, after translating to the client's local language, which will appear reasonable to a client.

=cut

sub translated_display_name {
    my $self = shift;
    return localize($self->display_name);
}

=head2 exchange_name

To which exchange does the underlying belong. example: FOREX, NASDAQ, etc.

=cut

has _exchange_name => (
    is => 'ro',
);

has exchange_name => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_exchange_name {
    my $self = shift;
    my $exchange_name = $self->_exchange_name || 'FOREX';

    if ($self->symbol =~ /^FUTE(B|C)/i) {

        # International Petroleum Exchange (now called ICE)
        $exchange_name = 'IPE';
    } elsif ($self->symbol =~ /^FUTLZ/i) {

        # Euronext LIFFE FTSE-100 Futures
        $exchange_name = 'EURONEXT';
    }

    return $exchange_name;
}

=head2 exchange

Returns a BOM::Market::Exchange object where this underlying is traded.  Useful for
determining market open and closing times and other restrictions which may
apply on that basis.

=cut

has exchange => (
    is         => 'ro',
    isa        => 'BOM::Market::Exchange',
    lazy_build => 1,
    handles    => [
        'seconds_of_trading_between_epochs', 'trade_date_after', 'trade_date_before', 'trades_on',
        'has_holiday_on',                    'is_open',          'is_in_dst_at',      'is_OTC',
    ]);

sub _build_exchange {
    my $self = shift;

    $self->_exchange_refreshed(time);
    return BOM::Market::Exchange->new($self->exchange_name, $self->for_date);
}

has _exchange_refreshed => (
    is      => 'rw',
    default => 0,
);

before 'exchange' => sub {
    my $self = shift;
    $self->clear_exchange if ($self->_exchange_refreshed + 17 < time);
};

=head2 market_convention

Returns a hashref. Keys and possible values are:

=over 4

=item * atm_setting

Value can be one of:
    - atm_delta_neutral_straddle
    - atm_forward
    - atm_spot

=item * delta_premium_adjusted

Value can be one of:
    - 1
    - 0

=item * delta_style

Value can be one of:
    - spot_delta
    - forward_delta

=item * rr (Risk Reversal)

Value can be one of:
    - call-put
    - put-call

=item * bf (Butterfly)

Value can be one of:
    - 2_vol

=back

=cut

has market_convention => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub {
        return {
            delta_style            => 'spot_delta',
            delta_premium_adjusted => 0,
        };
    },
);

=head2 divisor

Divisor

=cut

has divisor => (
    is      => 'ro',
    isa     => 'Num',
    default => 1,
);

=head2 combined_folder

Return the directory name where we keep our quotes.

=cut

# sooner or later this should go away... or at least be private.
sub _build_combined_folder {
    my $self              = shift;
    my $underlying_symbol = $self->system_symbol;
    my $market            = $self->market;

    if ($market->name eq 'config' and $underlying_symbol !~ /HEARTB/gi) {
        $underlying_symbol =~ s/^FRX/^frx/;
        return 'combined/' . $underlying_symbol . '/quant';
    }

# For not config/vols return combined. Feed is saved in combined/ (no subfolder)
    return 'combined';
}

=head2 feed_license

What does our license for the feed permit us to display to the client?

Most of the time the license is take from the underlyings.yml

Returns one of:

* realtime: we can redistribute realtime data
* delayed: we can redistribute only 15/20/30min delayed data
* daily: we can redistribute only after market close
* chartonly: we can draw chart only (but display no prices)
* none: we cannot redistribute anything

For clients subscribed to realtime feed for certain instruments,
the client's cookie is checked and if applicable we return realtime.

=cut

sub feed_license {
    my $self = shift;

    my $feed_license = $self->_feed_license || $self->market->license;

    # IMPORTANT! do *not* translate the return values!
    if (_force_realtime_license()) {
        $feed_license = 'realtime';
    }

    return $feed_license;
}

=head2 $self->last_licensed_display_epoch

This returns timestamp after which we can't display ticks for the
underlying to client due to feed license restrictions.

=cut

sub last_licensed_display_epoch {
    my $self = shift;

    my $lic  = $self->feed_license;
    my $time = time;
    if ($lic eq 'realtime') {
        return $time;
    } elsif ($lic eq 'delayed') {
        return $time - 60 * $self->delay_amount;
    } elsif ($lic eq 'daily') {
        my $today  = Date::Utility->today;
        my $closes = $self->exchange->closing_on($today);
        if ($closes and $time >= $closes->epoch) {
            $time = $closes->epoch;
        } else {
            my $opens = $self->exchange->opening_on($today);
            $time =
                ($opens and $opens->is_before($today))
                ? $opens->epoch - 1
                : $today->epoch - 1;
        }
        return $time;
    } elsif ($lic eq 'chartonly') {
        return 0;
    } else {
        confess "don't know how to deal with '$lic' license of " . $self->symbol;
    }
}

# Force the underlying to behave as if we have a license allowing realtime data display.
# This should only be used internally or for auditing.

sub _force_realtime_license {
    return (request()->backoffice) ? 1 : undef;
}

=head2 quoted_currency

In which currency are the prices for this underlying quoted?

=cut

sub _build_quoted_currency {
    my $self = shift;

    if ($self->quoted_currency_symbol) {
        return BOM::Market::Currency->new({
            symbol   => $self->quoted_currency_symbol,
            for_date => $self->for_date,
        });
    }
    return;
}

=head2 asset

Return the asset object depending on the market type.

=cut

sub _build_asset {
    my $self = shift;

    return unless $self->asset_symbol;
    my $type =
          $self->submarket->asset_type eq 'currency'
        ? $self->submarket->asset_type
        : $self->market->asset_type;
    my $which = $type eq 'currency' ? 'BOM::Market::Currency' : 'BOM::Market::Asset';

    return $which->new({
        symbol   => $self->asset_symbol,
        for_date => $self->for_date,
    });
}

sub _build_asset_symbol {
    my $self   = shift;
    my $symbol = '';

    if ($self->symbol =~ /^FUT(\w+)_/) {
        $symbol = $1;
    }

    return $symbol;
}

sub _build_quoted_currency_symbol {
    my $self   = shift;
    my $symbol = '';

    if (scalar grep { $self->market->name eq $_ } qw( futures )) {
        $symbol = BOM::Market::Underlying->new($self->asset_symbol)->quoted_currency_symbol;
    }

    return $symbol;
}

=head2 feed_api

Returns, an instance of I<BOM::Market::Data::DatabaseAPI> based on information that it can collect from underlying.

=cut

sub _build_feed_api {
    my $self = shift;

    my $build_args = {underlying => $self->system_symbol};
    if ($self->use_official_ohlc) {
        $build_args->{use_official_ohlc} = 1;
    }

    if ($self->ohlc_daily_open) {
        $build_args->{ohlc_daily_open} = $self->ohlc_daily_open;
    }

    if ($self->inverted) {
        $build_args->{invert_values} = 1;
    }

    return BOM::Market::Data::DatabaseAPI->new($build_args);
}

# End of builders.

=head2 intraday_interval

Return interval between available starts for forward starting contracts

=cut

has intraday_interval => (
    is      => 'ro',
    isa     => 'bom_time_interval',
    default => '5m',
    coerce  => 1,
);

=head2 rate_to_imply

The general rule to determine which currency's rate should be implied are as below:

1) One of the currencies is Metal - imply Metal depo. 

2. One of the currencies is USD - imply non-USD depo (for offshore market). 

3. One of the currencies is JPY - imply non-JPY depo. 

4. One of the currencies is EUR - imply non-EUR depo. 

5) The second currency in the currency pair will be imply

=cut

has rate_to_imply => (
    is         => 'ro',
    isa        => 'Str',
    lazy_build => 1,
);

sub _build_rate_to_imply {
    my $self = shift;

    if ($self->market->name eq 'commodities') {
        return $self->asset_symbol;
    } elsif ($self->symbol =~ /USD/) {
        if ($self->asset_symbol eq 'USD') {
            return $self->quoted_currency_symbol;
        } else {
            return $self->asset_symbol;
        }
    } elsif ($self->symbol =~ /JPY/) {
        if ($self->asset_symbol eq 'JPY') {
            return $self->quoted_currency_symbol;
        } else {
            return $self->asset_symbol;
        }
    } elsif ($self->symbol =~ /EUR/) {
        if ($self->asset_symbol eq 'EUR') {
            return $self->quoted_currency_symbol;
        } else {
            return $self->asset_symbol;
        }
    } else {
        if ($self->symbol =~ /frx(\w\w\w)(\w\w\w)/) {
            return $2;
        }
    }
}

has rate_to_imply_from => (
    is         => 'ro',
    isa        => 'Str',
    lazy_build => 1,
);

sub _build_rate_to_imply_from {
    my $self = shift;

    return ($self->rate_to_imply eq $self->quoted_currency_symbol)
        ? $self->asset_symbol
        : $self->quoted_currency_symbol;
}

=head2 interest_rate_for

Get the interest rate for this underlying over a given time period (expressed in timeinyears.)

=cut

sub interest_rate_for {
    my ($self, $tiy) = @_;

    # timeinyears cannot be undef
    $tiy ||= 0;

    # list of markets that have zero rate
    my %zero_rate = (
        random => 1,
    );

    my $rate;
    if ($zero_rate{$self->market->name}) {
        $rate = 0;
    } elsif ($self->uses_implied_rate($self->quoted_currency_symbol)) {
        $rate = $self->quoted_currency->rate_implied_from($self->rate_to_imply_from, $tiy);
    } else {
        $rate = $self->quoted_currency->rate_for($tiy);
    }

    return $rate;
}

=head2 dividend_rate_for

Get the dividend rate for this underlying over a given time period (expressed in timeinyears.)

=cut

sub dividend_rate_for {
    my ($self, $tiy) = @_;

    die 'Attempting to get interest rate on an undefined currency for ' . $self->symbol
        unless (defined $self->asset_symbol);

    my %zero_rate = (
        smart_fx  => 1,
        smart_opi => 1,
    );

    my $rate;

    if ($self->market->name eq 'random') {
        my $div = Quant::Framework::Dividend->new({
            symbol           => $self->symbol,
            chronicle_reader => BOM::System::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::System::Chronicle::get_chronicle_writer(),
        });
        my @rates = values %{$div->rates};
        $rate = pop @rates;
    } elsif ($zero_rate{$self->submarket->name}) {
        $rate = 0;
    } else {
        # timeinyears cannot be undef
        $tiy ||= 0;
        if ($self->uses_implied_rate($self->asset_symbol)) {
            $rate = $self->asset->rate_implied_from($self->rate_to_imply_from, $tiy);
        } else {
            $rate = $self->asset->rate_for($tiy);
        }
    }
    return $rate;
}

sub uses_implied_rate {
    my ($self, $which) = @_;

    return
        if BOM::Platform::Static::Config::quants->{market_data}->{interest_rates_source} eq 'market';
    return unless $self->forward_feed;
    return unless $self->market->name eq 'forex';    # only forex for now
    return $self->rate_to_imply eq $which ? 1 : 0;
}

sub get_discrete_dividend_for_period {
    my ($self, $args) = @_;

    my ($start, $end) =
        map { Date::Utility->new($_) } @{$args}{'start', 'end'};

    my %valid_dividends;
    my $discrete_points = Quant::Framework::Dividend->new(
        symbol           => $self->asset->symbol,
        chronicle_reader => BOM::System::Chronicle::get_chronicle_reader(),
        chronicle_writer => BOM::System::Chronicle::get_chronicle_writer(),
    )->discrete_points;

    if ($discrete_points and %$discrete_points) {
        my @sorted_dates =
            sort { $a->epoch <=> $b->epoch }
            map  { Date::Utility->new($_) } keys %$discrete_points;

        foreach my $dividend_date (@sorted_dates) {
            if (    not $dividend_date->is_before($start)
                and not $dividend_date->is_after($end))
            {
                my $date = $dividend_date->date_yyyymmdd;
                $valid_dividends{$date} = $discrete_points->{$date};
            }
        }
    }

    return \%valid_dividends;
}

sub dividend_adjustments_for_period {
    my ($self, $args) = @_;

    my $applicable_dividends =
        ($self->market->prefer_discrete_dividend)
        ? $self->get_discrete_dividend_for_period($args)
        : {};

    my ($start, $end) = @{$args}{'start', 'end'};
    my $duration_in_sec = $end->epoch - $start->epoch;

    my ($dS, $dK) = (0, 0);
    foreach my $date (keys %$applicable_dividends) {
        my $adjustment           = $applicable_dividends->{$date};
        my $effective_date       = Date::Utility->new($date);
        my $sec_away_from_action = ($effective_date->epoch - $start->epoch);
        my $duration_in_year     = $sec_away_from_action / (86400 * 365);
        my $r_rate               = $self->interest_rate_for($duration_in_year);

        my $adj_present_value = $adjustment * exp(-$r_rate * $duration_in_year);
        my $s_adj = ($duration_in_sec - $sec_away_from_action) / ($duration_in_sec) * $adj_present_value;
        $dS -= $s_adj;
        my $k_adj = $sec_away_from_action / ($duration_in_sec) * $adj_present_value;
        $dK += $k_adj;
    }

    return {
        barrier => $dK,
        spot    => $dS,
    };
}

=head2 deny_purchase_during

Do both the supplied start and end Date::Utilitys lie within a denied trading period?

=cut

sub deny_purchase_during {
    my ($self, $start, $end) = @_;

    my $denied    = ($self->is_buying_suspended) ? 1 : 0;
    my $day_start = $start->truncate_to_day;
    my @ieps      = @{$self->inefficient_periods};

    while (not $denied and my $ie = shift @ieps) {
        $denied = 1
            unless ($start->is_before($day_start->plus_time_interval($ie->{start}))
            or $end->is_after($day_start->plus_time_interval($ie->{end})));
    }

    return $denied;
}

has '_recheck_appconfig' => (
    is      => 'rw',
    default => sub { return time; },
);

my $appconfig_attrs = [qw(is_newly_added is_buying_suspended is_trading_suspended)];
has $appconfig_attrs => (
    is         => 'ro',
    lazy_build => 1,
);

before $appconfig_attrs => sub {
    my $self = shift;

    my $now = time;
    if ($now >= $self->_recheck_appconfig) {
        $self->_recheck_appconfig($now + 19);
        foreach my $attr (@{$appconfig_attrs}) {
            my $clearer = 'clear_' . $attr;
            $self->$clearer;
        }
    }

};

sub _build_is_newly_added {
    my $self = shift;

    return grep { $_ eq $self->symbol } (@{BOM::Platform::Runtime->instance->app_config->quants->underlyings->newly_added});
}

=head2 is_buying_suspended

Has buying of this underlying been suspended?

=cut

sub _build_is_buying_suspended {
    my $self = shift;

    # Trade suspension implies buying suspension, as well.
    return (
        $self->is_trading_suspended
            or grep { $_ eq $self->symbol } (@{BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_buy}));
}

=head2 is_trading_suspended

Has all trading on this underlying been suspended?

=cut

sub _build_is_trading_suspended {
    my $self = shift;

    return (
               not keys %{$self->contracts}
            or $self->market->disabled
            or grep { $_ eq $self->symbol } (@{BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_trades}));
}

=head2 fullfeed_file

Where do we find the fullfeed file for the provided date?  Second argument allows override of the 'combined' portion of the path.

=cut

sub fullfeed_file {
    my ($self, $date, $override_folder) = @_;

    if ($date =~ /^(\d\d?)\-(\w\w\w)\-(\d\d)$/) {
        $date = $1 . '-' . ucfirst(lc($2)) . '-' . $3;
    }    #convert 10-JAN-05 to 10-Jan-05
    else {
        croak 'Bad date for fullfeed_file';
    }

    my $folder = $override_folder || $self->combined_folder;

    return
          BOM::Platform::Runtime->instance->app_config->system->directory->feed . '/'
        . $folder . '/'
        . $self->system_symbol . '/'
        . $date
        . ($override_folder ? "-fullfeed.csv" : ".fullfeed");
}

=head2 is_in_quiet_period

Are we currently in a quiet traidng period for this underlying?

Keeping this as a method will allow us to have long-lived objects

=cut

sub is_in_quiet_period {
    my $self = shift;

    my $quiet = 0;

    # Cache the exchange objects for faster service
    # The times should not reasonably change in a process-lifetime
    state $exchanges = {map { $_ => BOM::Market::Exchange->new($_) } (qw(NYSE FSE LSE TSE SES ASX))};

    if ($self->market->name eq 'forex') {
        # Pretty much everything trades in these big centers of activity
        my @check_if_open = ('LSE', 'FSE', 'NYSE');

        my @currencies = ($self->asset_symbol, $self->quoted_currency_symbol);

        if (grep { $_ eq 'JPY' } @currencies) {

            # The yen is also heavily traded in
            # Australia, Singapore and Tokyo
            push @check_if_open, ('ASX', 'SES', 'TSE');
        } elsif (
            grep {
                $_ eq 'AUD'
            } @currencies
            )
        {

            # The Aussie dollar is also heavily traded in
            # Australia and Singapore
            push @check_if_open, ('ASX', 'SES');
        }

        # If any of the places we've listed have an exchange open, we are not in a quiet period.
        my $when = $self->for_date // time;
        $quiet = (any { $exchanges->{$_}->is_open_at($when) } @check_if_open) ? 0 : 1;
    }

    return $quiet;
}

=head2 weighted_days_in_period

Returns the sum of the weights we apply to each day in the requested period.

=cut

sub weighted_days_in_period {
    my ($self, $begin, $end) = @_;

    $end = $end->truncate_to_day;
    my $current = $begin->truncate_to_day->plus_time_interval('1d');
    my $days    = 0.0;

    while (not $current->is_after($end)) {
        $days += $self->weight_on($current);
        $current = $current->plus_time_interval('1d');
    }

    return $days;
}

# weighted_days_in_period() is called a lot with the same arguments, memoize it.
# See also the comment on Exchange::_normalize_on_dates()
Memoize::memoize(
    'weighted_days_in_period',
    NORMALIZER => sub {
        my ($self, $begin, $end) = @_;

        return $self->symbol . ',' . $begin->days_since_epoch . ',' . $end->days_since_epoch . ',' . $self->closed_weight;
    });

=head2 weight_on

Returns the weight for a given day (given as a Date::Utility object).
Returns our closed weight for days when the market is closed.

=cut

sub weight_on {
    my ($self, $date) = @_;

    my $weight = $self->exchange->weight_on($date) || $self->closed_weight;
    if ($self->market->name eq 'forex') {
        my $base      = $self->asset;
        my $numeraire = $self->quoted_currency;
        my $currency_weight =
            0.5 * ($base->weight_on($date) + $numeraire->weight_on($date));

        # If both have a holiday, set to 0.25
        if (!$currency_weight) {
            $currency_weight = 0.25;
        }

        $weight = min($weight, $currency_weight);
    }

    return $weight;
}

=head2 closed_weight

The weight given to a day when the underlying is closed.

=cut

has closed_weight => (
    is         => 'rw',
    isa        => 'Num',
    lazy_build => 1,
);

sub _build_closed_weight {
    my $self = shift;

    return ($self->market->name eq 'indices') ? 0.55 : 0.06;
}

=head1 REALTIME TICK METHODS
=head2 $self->set_combined_realtime($value)

Save last tick value for symbol in Redis. Returns true if operation was
successfull, false overwise. Tick value should be a hash reference like this:

{
    epoch => $unix_timestamp,
    quote => $last_price,
}

=cut

sub set_combined_realtime {
    my ($self, $value) = @_;

    my $tick;
    if (ref $value eq 'BOM::Market::Data::Tick') {
        $tick  = $value;
        $value = $value->as_hash;
    } else {
        $tick = BOM::Market::Data::Tick->new($value);
    }
    Cache::RedisDB->set_nw('COMBINED_REALTIME', $self->symbol, $value);
    return $tick;
}

=head2 $self->get_combined_realtime

Get last tick value for symbol from Redis. It will rebuild value from
feed db if it is not present in cache.

=cut

sub get_combined_realtime_tick {
    my $self = shift;

    my $value = Cache::RedisDB->get('COMBINED_REALTIME', $self->symbol);
    my $tick;
    if ($value) {
        $tick = BOM::Market::Data::Tick->new($value);
    } else {
        $tick = $self->tick_at(time, {allow_inconsistent => 1});
        if ($tick) {
            $self->set_combined_realtime($tick);
        }
    }

    return $tick;
}

sub get_combined_realtime {
    my $self = shift;

    my $tick = $self->get_combined_realtime_tick;

    return ($tick) ? $tick->as_hash : undef;
}

=head2 spot

What is the current spot price for this underlying?

=cut

# Get the last available value currently defined in realtime DB

sub spot {
    my $self = shift;
    my $last_price;

    my $last_tick = $self->spot_tick;
    $last_price = $last_tick->quote if $last_tick;

    return $self->pipsized_value($last_price);
}

=head2 spot_tick

What is the current tick on this underlying

=cut

sub spot_tick {
    my $self = shift;

    return ($self->for_date)
        ? $self->tick_at($self->for_date->epoch, {allow_inconsistent => 1})
        : $self->get_combined_realtime_tick;
}

=head2 spot_time

The epoch timestamp of the latest recorded tick in the .realtime file or undef if we can't find one.
t
=cut

sub spot_time {
    my $self      = shift;
    my $last_tick = $self->spot_tick;
    return $last_tick && $last_tick->epoch;
}

=head2 spot_age

The age in seconds of the latest tick

=cut

sub spot_age {
    my $self      = shift;
    my $tick_time = $self->spot_time;
    return defined $tick_time && time - $tick_time;
}

=head1 FEED METHODS
=head2 tick_at

What was the market tick at a given timestamp?  This will be the tick on or before the supplied timestamp.

=cut

sub tick_at {
    my ($self, $timestamp, $allow_inconsistent_hash) = @_;

    my $inconsistent_price;
    if (defined $allow_inconsistent_hash->{allow_inconsistent}
        and $allow_inconsistent_hash->{allow_inconsistent} == 1)
    {
        $inconsistent_price = 1;
    }

    my $pricing_date = Date::Utility->new($timestamp);
    my $tick;

    # get official close for previous trading day
    if ($self->use_official_ohlc
        and not $self->exchange->trades_on($pricing_date))
    {
        my $last_trading_day = $self->exchange->trade_date_before($pricing_date);
        $tick = $self->closing_tick_on($last_trading_day->date_ddmmmyy);
    } else {
        my $request_hash = {};
        $request_hash->{end_time} = $timestamp;
        $request_hash->{allow_inconsistent} = 1 if ($inconsistent_price);

        $tick = $self->feed_api->tick_at($request_hash);
    }

    return $tick;
}

=head2 closing_tick_on

Get the market closing tick for a given date.

Example : $underlying->closing_tick_on("10-Jan-00");

=cut

sub closing_tick_on {
    my ($self, $end) = @_;
    my $date = Date::Utility->new($end);

    my $closing = $self->exchange->closing_on($date);
    if ($closing and time > $closing->epoch) {
        my $ohlc = $self->ohlc_between_start_end({
            start_time         => $date,
            end_time           => $date,
            aggregation_period => 86400,
        });

        if ($ohlc and scalar @{$ohlc} > 0) {

            # We need a tick, but we can only get an OHLC
            # The epochs for these are set to be the START of the period.
            # So we also need to change it to the closing time. Meh.
            my $not_tick = $ohlc->[0];
            return BOM::Market::Data::Tick->new({
                symbol => $self->symbol,
                epoch  => $closing->epoch,
                quote  => $not_tick->close,
            });
        }
    }
    return;
}

sub get_ohlc_data_for_period {
    my ($self, $args) = @_;

    my ($start, $end) = @{$args}{'start', 'end'};

    my $start_date = Date::Utility->new($start);
    my $end_date   = Date::Utility->new($end);

    if ($end_date->epoch < $start_date->epoch) {
        confess "[$0][get_ohlc_data_for_period] start_date > end_date ("
            . $start_date->datetime . ' > '
            . $end_date->datetime
            . ") with input: $start > $end";
    }

    if ($end_date->epoch == $end_date->truncate_to_day->epoch) {

        # if is 00:00:00, make it 23:59:59 (end of the day)
        $end_date = Date::Utility->new($end_date->epoch + 86399);
    }

    my @ohlcs = @{
        $self->feed_api->ohlc_daily_list({
                start_time => $start_date->datetime_yyyymmdd_hhmmss,
                end_time   => $end_date->datetime_yyyymmdd_hhmmss,
            })};

    return @ohlcs;
}

=head2 get_daily_ohlc_table

Returns an array reference with ohlc information in the format of:
(date, open, high, low, close)

->get_daily_ohlc_table({
    start => $start,
    end => $end,
});

=cut

sub get_daily_ohlc_table {
    my ($self, $args) = @_;

    my @ohlcs = $self->get_ohlc_data_for_period($args);

    my @table;
    foreach my $ohlc (@ohlcs) {
        push @table, [Date::Utility->new($ohlc->epoch)->date, map { $self->pipsized_value($ohlc->$_) } (qw(open high low close))];
    }

    return \@table;
}

=head2 get_high_low_for_period

Usage:

  $u->get_high_low_for_period({start => "10-Jan-00", end => "20-Jan-00"});

Returns a hash ref with the following keys:
high  => The high over the period.
low   => The low over the period.

=cut

sub get_high_low_for_period {
    my ($self, $args) = @_;

    my @ohlcs = $self->get_ohlc_data_for_period($args);

    my ($final_high, $final_low, $final_close);
    foreach my $ohlc (@ohlcs) {
        my $high = $ohlc->high;
        my $low  = $ohlc->low;

        $final_high = $high unless $final_high;
        $final_low  = $low  unless $final_low;

        $final_high = $high if $high > $final_high;
        $final_low  = $low  if $low < $final_low;
        $final_close = $ohlc->close;
    }

    return {
        high  => $final_high,
        low   => $final_low,
        close => $final_close,
    };
}

=head2 next_tick_after

Get next tick after a given time. What is the next tick on this underlying after the given epoch timestamp?
    my $tick = $underlying->next_tick_after(1234567890);

Return:
    'BOM::Market::Data::Tick' Object

=head2 breaching_tick

Get first tick in a provided period which breaches a barrier (either 'higher' or 'lower')

Return:
    'BOM::Market::Data::Tick' Object or undef

=head2 ticks_in_between_start_end

Gets ticks for specified start_time, end_time as all ticks between start_time and end_time

Returns,
    ArrayRef[BOM::Market::Data::Tick] on success
    empty ArrayRef on failure

=head2 ticks_in_between_start_limit

Get ticks for specified start_time, limit as limit number of ticks from start_time

Returns,
    ArrayRef[BOM::Market::Data::Tick] on success
    empty ArrayRef on failure

=head2 ticks_in_between_end_limit

Get ticks for specified end_time, limit as limit number of ticks from end_time.

Returns,
    ArrayRef[BOM::Market::Data::Tick] on success
    empty ArrayRef on failure

=head2 ohlc_between_start_end

Gets ohlc for specified start_time, end_time, aggregation_period

Returns,
    ArrayRef[BOM::Market::Data::OHLC] on success
    empty ArrayRef on failure


=cut

=head2 ohlc_daily_open

Some underlying, eg: RDYANG, RDYIN open at 12GMT. The open & close cross over GMT day.
Daily ohlc from feed.ohlc_daily table can't be used, as there are computed based on GMT day.
In this case, daily ohlc need to be computed from feed.ohlc_hourly table, based on actual market open time

=cut

sub ohlc_daily_open {
    my $self = shift;

    my $today    = Date::Utility->today;
    my $exchange = $self->exchange;
    my $trading_day =
        ($exchange->trades_on($today))
        ? $today
        : $exchange->trade_date_after($today);

    my $open  = $exchange->opening_on($trading_day);
    my $close = $exchange->closing_on($trading_day);

    if ($close->days_between($open) > 0) {
        return $open->seconds_after_midnight;
    }
    return;
}

=head2 pip_size

The pip value for a forex asset

=cut

has pip_size => (
    is      => 'ro',
    default => 0.0001,
);

=head2 display_decimals

How many decimals to display for this underlying

=cut

has display_decimals => (
    is         => 'ro',
    isa        => 'Num',
    lazy_build => 1,
);

sub _build_display_decimals {
    my $self = shift;

    return log(1 / $self->pip_size) / log(10);
}

=head2 pipsized_value

Resize a value to conform to the pip size of this underlying

=cut

sub pipsized_value {
    my ($self, $value, $custom) = @_;

    my ($pip_size, $display_decimals) =
          ($custom)
        ? ($custom, log(1 / $custom) / log(10))
        : ($self->pip_size, $self->display_decimals);
    if (defined $value and looks_like_number($value)) {
        $value = sprintf '%.' . $display_decimals . 'f', $value;
    }
    return $value;
}

=head2 price_at_intervals(\%args)

Give price_at values between start_time and end_time at interval_seconds
intervals. Accepts the following parameters:

=over 4

=item B<start_time>

Start from the specified time. This will be rounded up to the multiple of the
interval size

=item B<end_time>

End at specified time. This will be rounded down to the multiple of the
interval size

=item B<interval_seconds>

Interval between price_at values in seconds. By default I<intraday_interval> is
used

=back

Returns reference to the array of hashes with I<epoch> and <quote> elements

=cut

sub price_at_intervals {
    my $self             = shift;
    my $args             = shift;
    my $start_date       = Date::Utility->new($args->{start_time});
    my $end_date         = Date::Utility->new($args->{end_time} // time);
    my $interval_seconds = $args->{interval_seconds} // $self->intraday_interval->seconds;

    # We don't want to go beyond the end of the day.
    # And if it's not even open, just use the same Date.
    my $day_close = $self->exchange->closing_on($start_date) // $start_date;
    $end_date = $day_close if ($end_date->is_after($day_close));

    $start_date = Date::Utility->new(POSIX::ceil($start_date->epoch / $interval_seconds) * $interval_seconds);
    $end_date   = Date::Utility->new(POSIX::floor($end_date->epoch / $interval_seconds) * $interval_seconds);

    my $prices = [];
    if ($end_date->is_before($start_date)) {
        return $prices;
    }

    my $ticks = $self->feed_api->tick_at_for_interval({
        'start_date'          => $start_date,
        'end_date'            => $end_date,
        'interval_in_seconds' => $interval_seconds,
    });

    my $db_ticks;
    my $last_tick_in_db = $start_date->epoch;
    foreach my $tick (@{$ticks}) {
        $db_ticks->{$tick->epoch} = $tick;
        $last_tick_in_db = $tick->epoch;
    }

    my $time = $start_date->epoch;
    while ($time <= $end_date->epoch) {
        my $tick;
        if ($time == $start_date->epoch) {
            $tick = $self->tick_at($start_date->epoch);
        } elsif ($time == $end_date->epoch) {
            $tick = $self->tick_at($end_date->epoch);
        } elsif ($db_ticks->{$time} and $time != $last_tick_in_db) {
            $tick = $db_ticks->{$time};
        } else {
            $tick = $self->tick_at($time);
        }
        if ($tick) {
            $tick->invert_values if ($self->inverted);
            push @$prices,
                {
                epoch => $time,
                quote => $self->pipsized_value($tick->quote),
                };
        }
        $time += $interval_seconds;
    }

    return $prices;
}

sub breaching_tick {
    my ($self, %args) = @_;

    $args{underlying} = $self;

    return $self->feed_api->get_first_tick(%args);
}

has [qw(spread_divisor)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_spread_divisor {
    my $self = shift;
    return $self->submarket->spread_divisor || $self->market->spread_divisor;
}

=head2 use_official_ohlc

Should this underlying use official OHLC

=cut

sub use_official_ohlc {
    my $self = shift;
    return $self->submarket->official_ohlc;
}

sub forward_starts_on {
    my $self = shift;
    my $day  = Date::Utility->new(shift)->truncate_to_day;

    my $exchange = $self->exchange;
    my $opening  = $exchange->opening_on($day);
    return [] unless ($opening);

    my $cache_key = 'FORWARDSTARTS::' . $self->symbol;
    my $cached_starts = Cache::RedisDB->get($cache_key, $day->date);
    return $cached_starts if ($cached_starts);

    my $sod_bo            = $self->sod_blackout_start;
    my $eod_bo            = $self->eod_blackout_expiry;
    my $intraday_interval = $self->intraday_interval;

    # With 0s blackout, skip open if we weren't open at the previous start.
    # Basically, Monday morning/holiday forex.
    my $start_at =
        ($sod_bo->seconds == 0 and not $exchange->is_open_at($opening->minus_time_interval($intraday_interval)))
        ? $opening->plus_time_interval($intraday_interval)
        : $opening->plus_time_interval($sod_bo);

    my $end_at = $exchange->closing_on($day)->minus_time_interval($eod_bo);
    my @trading_periods;
    if (my $breaks = $exchange->trading_breaks($day)) {
        my @breaks = @$breaks;
        if (@breaks == 1) {
            @trading_periods = ([$start_at, $breaks[0][0]->minus_time_interval($eod_bo)], [$breaks[0][1]->plus_time_interval($sod_bo), $end_at]);
        } else {
            push @trading_periods, [$start_at, $breaks[0][0]];
            push @trading_periods, [$breaks[0][1],  $breaks[1][0]];
            push @trading_periods, [$breaks[-1][1], $end_at];
        }
    } else {
        @trading_periods = ([$start_at, $end_at]);
    }

    my $starts;
    my $step_seconds = $intraday_interval->seconds;
    foreach my $period (@trading_periods) {
        my ($start_period, $end_period) = @$period;
        my $current = $start_period;
        my $stop    = $end_period;
        my $next    = $current->plus_time_interval($intraday_interval);

        while ($next->is_before($end_period)) {
            push @$starts, $current;
            $current = $next;
            $next    = $current->plus_time_interval($intraday_interval);
        }
    }

    Cache::RedisDB->set($cache_key, $day->date, $starts, 7207);    # Hold for about 2 hours.

    return $starts;
}

=head2 corporate_actions

A complete list of corporate actions available for this underlying at this time.
The list is returned in the order in which any adjustments should be applied.

We could have more than one corporate actions in a day.
We determine which action should be applied first based on the action code provided by Bloomberg.

=cut

=head2 applicable_corporate_actions

A list of corporate actions that would affect the market price for this underlying

=cut

has [qw(corporate_actions applicable_corporate_actions)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_corporate_actions {
    my $self = shift;

    return [] if not $self->market->affected_by_corporate_actions;

    my $corp = Quant::Framework::CorporateAction->new(
        symbol           => $self->symbol,
        chronicle_reader => BOM::System::Chronicle::get_chronicle_reader(),
        chronicle_writer => BOM::System::Chronicle::get_chronicle_writer());

    my $available_actions = $corp->actions;
    my %grouped_by_date;
    foreach my $id (keys %$available_actions) {
        my $act      = $available_actions->{$id};
        my $eff_date = $act->{effective_date};
        push @{$grouped_by_date{$eff_date}}, $act;
    }

    my $mapper = {
        STOCK_SPLT => {
            before => [3000, 3003, 3007],
            after  => [3001, 3005, 3008],
        },
        DVD_STOCK => {
            before => [2000, 2002, 2004, 2006, 2008, 2013, 2016, 2018],
            after  => [2001, 2003, 2005, 2007, 2009, 2014, 2017],
        },
    };

# This is the proper order in which to apply actions based on bloomberg's codes.
# If there are multiple actions a day, Bloomberg will provide the order of execution in codes.
# E.g. DVD_STOCK with code 2000 will be applied before any other actions on the same day, etc.
    foreach my $day (keys %grouped_by_date) {
        my $actions_on_day = $grouped_by_date{$day};
        my $number_of_act  = scalar @$actions_on_day;

        next if $number_of_act == 1;

        my $order;
        @{$order}{'first', 'last', 'mid'} = ([], [], []);
        foreach my $act (@$actions_on_day) {
            my $type = $act->{type};

            if (    grep { $type eq $_ } qw(DVD_STOCK STOCK_SPLT)
                and grep { $_ == $act->{action_code} } @{$mapper->{$type}->{before}})
            {
                push @{$order->{first}}, $act;
            } elsif (
                grep {
                    $type eq $_
                } qw(DVD_STOCK STOCK_SPLT)
                and grep {
                    $_ == $act->{action_code}
                } @{$mapper->{$type}->{after}})
            {
                push @{$order->{last}}, $act;
            } else {
                push @{$order->{mid}}, $act;
            }
        }

        if (scalar @{$order->{first}} > 1 or scalar @{$order->{last}} > 1) {
            croak 'Could not determine order of corporate actions on '
                . $self->system_symbol
                . '.  Have ['
                . scalar @{$order->{first}}
                . '] "first" and ['
                . scalar @{$order->{last}}
                . '] "last" actions.';
        }

        $grouped_by_date{$day} =
            [@{$order->{first}}, @{$order->{mid}}, @{$order->{last}}];
    }

    my @ordered_actions =
        map  { @{$grouped_by_date{$_->[1]}} }
        sort { $a->[0] <=> $b->[0] }
        map {
        [try { Date::Utility->new($_)->epoch } || 0, $_]
        }
        keys %grouped_by_date;

    return \@ordered_actions;
}

sub _build_applicable_corporate_actions {
    my $self = shift;

    return [grep { exists $_->{modifier} } @{$self->corporate_actions}];

}

=head2 get_applicable_corporate_actions_for_period

Returns an array of corporate actions within the given date, in the order that they will be executed.

=cut

sub get_applicable_corporate_actions_for_period {
    my ($self, $args) = @_;

    my ($start, $expiry) =
        map { Date::Utility->new($_) } @{$args}{'start', 'end'};

    my @valid_actions;
    foreach my $action (@{$self->applicable_corporate_actions}) {
        my $eff_date = Date::Utility->new($action->{effective_date});
        push @valid_actions, $action
            if not $eff_date->is_before($start)
            and not $eff_date->is_after($expiry);
    }

    return @valid_actions;
}

has resets_at_open => (
    is => 'ro',
    lazy_build => 1,
);

sub _build_resets_at_open {
    my $self = shift;

    return $self->submarket->resets_at_open;
}

no Moose;

__PACKAGE__->meta->make_immutable(
    constructor_name    => '_new',
    replace_constructor => 1
);

1;
