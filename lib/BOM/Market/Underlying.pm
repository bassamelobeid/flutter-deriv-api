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
use Cache::RedisDB;
use Date::Utility;
use Format::Util::Numbers qw(roundnear);
use JSON qw(from_json);
use List::MoreUtils qw( any );
use List::Util qw( first max min);
use Math::Round qw(round);
use Memoize;
use POSIX;
use Scalar::Util qw( looks_like_number );
use Time::HiRes;
use Time::Duration::Concise;
use Try::Tiny;
use YAML::XS qw(LoadFile);

use Finance::Asset;
use Finance::Asset::Market;
use Finance::Asset::Market::Registry;
use Finance::Asset::SubMarket::Registry;
use Finance::Asset::Market::Types;

use Quant::Framework::Spot;
use Quant::Framework::Spot::Tick;
use Quant::Framework::Exchange;
use Quant::Framework::TradingCalendar;
use Quant::Framework::CorporateAction;
use Quant::Framework::Spot::DatabaseAPI;
use Quant::Framework::Asset;
use Quant::Framework::Currency;
use Quant::Framework::ExpiryConventions;
use Quant::Framework::StorageAccessor;
use Quant::Framework::Utils::UnderlyingConfig;
use Quant::Framework::Utils::Builder;

#FeedDB::read_dbh is passed to Quant::Framework to be used to retrieve latest spot
use BOM::Database::FeedDB;

#Passed to Quant::Framework to read/write data
use BOM::System::Chronicle;

#Includes conversion code for Time::Duration::Concise, Date::Utility and Underlying
use BOM::Market::Types;

#Three quant-related settings which are read from a yml file
use BOM::System::Config;


our $PRODUCT_OFFERINGS = LoadFile('/home/git/regentmarkets/bom-market/config/files/product_offerings.yml');

#This has to be set to 1 only on the backoffice server. 
#A value of 1 means assuming real-time feed license for all underlyings.
our $FORCE_REALTIME_FEED = 0;

=head1 METHODS

=cut

=head2 new($symbol, [$for_date])

Return BOM::Market::Underlying object for given I<$symbol>. possibly at a given I<Date::Utility>.

=cut

sub new {
    my ($self, $args, $when) = @_;

    $args = {symbol => $args} if (not ref $args);
    my $symbol = $args->{symbol};

    die 'No symbol provided to constructor.' if (not $symbol);

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

has spot_source => (
    is         => 'ro',
    lazy_build => 1,
    handles    => {
        'set_combined_realtime'      => 'set_spot_tick',
        'get_combined_realtime_tick' => 'spot_tick',
        'get_combined_realtime'      => 'spot_tick_hash',
        'spot_tick'                  => 'spot_tick',
        'spot_time'                  => 'spot_time',
        'spot_age'                   => 'spot_age',
        'tick_at'                    => 'tick_at',
        'closing_tick_on'            => 'closing_tick_on',
    });

sub _build_spot_source {
    my $self = shift;

    return $self->_builder->build_spot;
}

sub spot {
    my $self = shift;

    return $self->pipsized_value($self->spot_source->spot_quote);
}

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
    isa        => 'financial_market',
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
    isa        => 'Maybe[Quant::Framework::Currency]',
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

has 'config' => (
    is         => 'ro',
    isa        => 'Quant::Framework::Utils::UnderlyingConfig',
    lazy_build => 1
);

sub _build_config {
    my $self = shift;

    my $asset_class =
          $self->submarket->asset_type eq 'currency'
        ? $self->submarket->asset_type
        : $self->market->asset_type;

    my %zero_rate = (
        smart_fx  => 1,
        smart_opi => 1,
    );

    my $default_dividend_rate = undef;

    $default_dividend_rate = 0 if $zero_rate{$self->submarket->name};
    $default_dividend_rate = -35 if $self->symbol eq 'RDBULL';
    $default_dividend_rate = 20 if $self->symbol eq 'RDBEAR';

    $default_dividend_rate = 20 if $self->symbol eq 'RDYIN';
    $default_dividend_rate = -35 if $self->symbol eq 'RDYANG';

    $default_dividend_rate = 0 if $self->symbol eq 'RDMOON';
    $default_dividend_rate = 0 if $self->symbol eq 'RDSUN';

    $default_dividend_rate = 0 if $self->symbol eq 'RDMARS';
    $default_dividend_rate = 0 if $self->symbol eq 'RDVENUS';

    my $build_args = {underlying => $self->system_symbol};

    $build_args->{use_official_ohlc} = 1 if ($self->use_official_ohlc);
    $build_args->{invert_values}     = 1 if $self->inverted;
    $build_args->{db_handle}         = sub {
        my $dbh = BOM::Database::FeedDB::read_dbh;
        $dbh->{RaiseError} = 1;
        return $dbh;
    };

    return Quant::Framework::Utils::UnderlyingConfig->new({
        symbol                                => $self->symbol,
        system_symbol                         => $self->system_symbol,
        market_name                           => $self->market->name,
        market_prefer_discrete_dividend       => $self->market->prefer_discrete_dividend,
        quanto_only                           => $self->quanto_only,
        rate_to_imply_from                    => $self->rate_to_imply_from,
        volatility_surface_type               => $self->volatility_surface_type,
        exchange_name                         => $self->exchange_name,
        uses_implied_rate_for_asset           => $self->uses_implied_rate($self->asset_symbol) // '',
        uses_implied_rate_for_quoted_currency => $self->uses_implied_rate($self->quoted_currency_symbol) // '',
        asset_symbol                          => $self->asset_symbol,
        quoted_currency_symbol                => $self->quoted_currency_symbol,
        extra_vol_diff_by_delta               => BOM::System::Config::quants->{market_data}->{extra_vol_diff_by_delta},
        market_convention                     => $self->market_convention,
        asset_class                           => $asset_class,
        default_dividend_rate                 => $default_dividend_rate,
        use_official_ohlc                     => $self->use_official_ohlc,
        pip_size                              => $self->pip_size,
        spot_db_args                          => $build_args,
    });
}

has '_builder' => (
    is         => 'ro',
    isa        => 'Quant::Framework::Utils::Builder',
    lazy_build => 1
);

sub _build__builder {
    my $self = shift;

    return Quant::Framework::Utils::Builder->new({
        for_date          => $self->for_date,
        chronicle_reader  => BOM::System::Chronicle::get_chronicle_reader($self->for_date),
        chronicle_writer  => BOM::System::Chronicle::get_chronicle_writer,
        underlying_config => $self->config
    });
}

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
    isa     => 'submarket',
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

has forward_feed => (
    is      => 'ro',
    isa     => 'Bool',
    default => 0,
);

has 'feed_api' => (
    is      => 'ro',
    isa     => 'Quant::Framework::Spot::DatabaseAPI',
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
        }
        $params_ref->{symbol}          = $requested_symbol;
        $params_ref->{asset}           = $asset;
        $params_ref->{quoted_currency} = $quoted;
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
    my $market = Finance::Asset::Market->new({name => 'nonsense'});
    if ($symbol =~ /^FUT/) {
        $market = Finance::Asset::Market::Registry->instance->get('futures');
    } elsif ($symbol =~ /^I_/) {
        $market = Finance::Asset::Market::Registry->instance->get('config');
    } elsif (length($symbol) >= 15) {
        $market = Finance::Asset::Market::Registry->instance->get('config');
        warn("Unknown symbol, symbol[$symbol]");
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

    return $exchange_name;
}

has expiry_conventions => (
    is         => 'ro',
    isa        => 'Quant::Framework::ExpiryConventions',
    lazy_build => 1,
    handles    => ['vol_expiry_date', '_spot_date', 'forward_expiry_date'],
);

sub _build_expiry_conventions {
    my $self = shift;

    return Quant::Framework::ExpiryConventions->new(
        chronicle_reader => BOM::System::Chronicle::get_chronicle_reader($self->for_date),
        is_forex_market  => $self->market->name eq 'forex',
        symbol           => $self->symbol,
        for_date         => $self->for_date,
        asset            => $self->asset,
        quoted_currency  => $self->quoted_currency,
        asset_symbol     => $self->asset_symbol,
        calendar         => $self->calendar,
    );
}

=head2 calendar

Returns a Quant::Framework::TradingCalendar object where this underlying is traded.  Useful for
determining market open and closing times and other restrictions which may
apply on that basis.

=cut

has calendar => (
    is         => 'ro',
    isa        => 'Quant::Framework::TradingCalendar',
    lazy_build => 1,
    handles =>
        ['seconds_of_trading_between_epochs', 'trade_date_after', 'trade_date_before', 'trades_on', 'has_holiday_on', 'is_open', 'is_in_dst_at',]);

sub _build_calendar {
    my $self = shift;

    $self->_exchange_refreshed(time);

    return Quant::Framework::TradingCalendar->new({
        symbol           => $self->exchange_name,
        chronicle_reader => BOM::System::Chronicle::get_chronicle_reader($self->for_date),
        for_date         => $self->for_date
    });
}

has exchange => (
    is         => 'ro',
    isa        => 'Quant::Framework::Exchange',
    lazy_build => 1,
);

sub _build_exchange {
    my $self = shift;

    $self->_exchange_refreshed(time);
    return Quant::Framework::Exchange->new($self->exchange_name);
}

has _exchange_refreshed => (
    is      => 'rw',
    default => 0,
);

before 'exchange' => sub {
    my $self = shift;
    $self->clear_exchange if ($self->_exchange_refreshed + 17 < time);
};

before 'calendar' => sub {
    my $self = shift;
    $self->clear_calendar if ($self->_exchange_refreshed + 17 < time);
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
    if ($FORCE_REALTIME_FEED) {
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
        my $closes = $self->calendar->closing_on($today);
        if ($closes and $time >= $closes->epoch) {
            $time = $closes->epoch;
        } else {
            my $opens = $self->calendar->opening_on($today);
            $time =
                ($opens and $opens->is_before($today))
                ? $opens->epoch - 1
                : $today->epoch - 1;
        }
        return $time;
    } elsif ($lic eq 'chartonly') {
        return 0;
    } else {
        die "don't know how to deal with '$lic' license of " . $self->symbol;
    }
}

=head2 quoted_currency

In which currency are the prices for this underlying quoted?

=cut

sub _build_quoted_currency {
    my $self = shift;

    if ($self->quoted_currency_symbol) {
        return Quant::Framework::Currency->new({
            symbol           => $self->quoted_currency_symbol,
            for_date         => $self->for_date,
            chronicle_reader => BOM::System::Chronicle::get_chronicle_reader($self->for_date),
            chronicle_writer => BOM::System::Chronicle::get_chronicle_writer(),
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
    my $which = $type eq 'currency' ? 'Quant::Framework::Currency' : 'Quant::Framework::Asset';

    return $which->new({
        symbol           => $self->asset_symbol,
        for_date         => $self->for_date,
        chronicle_reader => BOM::System::Chronicle::get_chronicle_reader($self->for_date),
        chronicle_writer => BOM::System::Chronicle::get_chronicle_writer(),
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

Returns, an instance of I<Quant::Framework::Spot::DatabaseAPI> based on information that it can collect from underlying.

=cut

sub _build_feed_api {
    my $self = shift;

    return $self->_builder->build_feed_api;
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

1) One of the currencies is Metal - imply Metal deposit rate.

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

=head2 dividend_rate_for

Get the dividend rate for this underlying over a given time period (expressed in timeinyears.)

=cut

sub dividend_rate_for {
    my ($self, $tiy) = @_;

    return $self->_builder->build_dividend->dividend_rate_for($tiy);
}

=head2 interest_rate_for

Get the interest rate for this underlying over a given time period (expressed in timeinyears.)

=cut

sub interest_rate_for {
    my ($self, $tiy) = @_;

    return $self->_builder->build_interest_rate->interest_rate_for($tiy);
}

sub get_discrete_dividend_for_period {
    my ($self, $args) = @_;

    return $self->_builder->build_dividend->get_discrete_dividend_for_period($args);
}

sub dividend_adjustments_for_period {
    my ($self, $args) = @_;

    return $self->_builder->build_dividend->dividend_adjustments_for_period($args);
}

sub uses_implied_rate {
    my ($self, $which) = @_;

    return
        if BOM::System::Config::quants->{market_data}->{interest_rates_source} eq 'market';
    return unless $self->forward_feed;
    return unless $self->market->name eq 'forex';    # only forex for now
    return $self->rate_to_imply eq $which ? 1 : 0;
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
    state $exchanges = {
        map {
            $_ => Quant::Framework::TradingCalendar->new({
                    symbol           => $_,
                    chronicle_reader => BOM::System::Chronicle::get_chronicle_reader($self->for_date),
                    for_date         => $self->for_date
                })
        } (qw(NYSE FSE LSE TSE SES ASX))};

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

=head1 FEED METHODS

=cut

sub get_ohlc_data_for_period {
    my ($self, $args) = @_;

    my ($start, $end) = @{$args}{'start', 'end'};

    my $start_date = Date::Utility->new($start);
    my $end_date   = Date::Utility->new($end);

    if ($end_date->epoch < $start_date->epoch) {
        die "[$0][get_ohlc_data_for_period] start_date > end_date ("
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

=head2 get_high_low_for_period

Usage:

  $u->get_high_low_for_period({start => "10-Jan-00", end => "20-Jan-00"});

Returns a hash ref with the following keys:
high  => The high over the period.
low   => The low over the period.

=cut

sub get_high_low_for_period {
    my ($self, $args) = @_;

    # Sleep for 10ms to give feed replicas a bit of time to catch the latest tick if the sell time is now
    Time::HiRes::sleep(0.01) if Date::Utility->new($args->{end})->epoch == time;
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
    'Quant::Framework::Spot::Tick' Object

=head2 breaching_tick

Get first tick in a provided period which breaches a barrier (either 'higher' or 'lower')

Return:
    'Quant::Framework::Spot::Tick' Object or undef

=head2 ticks_in_between_start_end

Gets ticks for specified start_time, end_time as all ticks between start_time and end_time

Returns,
    ArrayRef[Quant::Framework::Spot::Tick] on success
    empty ArrayRef on failure

=head2 ticks_in_between_start_limit

Get ticks for specified start_time, limit as limit number of ticks from start_time

Returns,
    ArrayRef[Quant::Framework::Spot::Tick] on success
    empty ArrayRef on failure

=head2 ticks_in_between_end_limit

Get ticks for specified end_time, limit as limit number of ticks from end_time.

Returns,
    ArrayRef[Quant::Framework::Spot::Tick] on success
    empty ArrayRef on failure

=head2 ohlc_between_start_end

Gets ohlc for specified start_time, end_time, aggregation_period

Returns,
    ArrayRef[Quant::Framework::Spot::OHLC] on success
    empty ArrayRef on failure


=cut

=head2 ohlc_daily_open

Daily ohlc from feed.ohlc_daily table can't be used, as there are computed based on GMT day.
In this case, daily ohlc need to be computed from feed.ohlc_hourly table, based on actual market open time

=cut

sub ohlc_daily_open {
    my $self = shift;

    my $today    = Date::Utility->today;
    my $calendar = $self->calendar;
    my $trading_day =
        ($calendar->trades_on($today))
        ? $today
        : $calendar->trade_date_after($today);

    my $open  = $calendar->opening_on($trading_day);
    my $close = $calendar->closing_on($trading_day);

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

sub breaching_tick {
    my ($self, %args) = @_;

    $args{underlying}    = $self->symbol;
    $args{system_symbol} = $self->system_symbol;
    $args{pip_size}      = $self->pip_size;

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

    my $storage_accessor = Quant::Framework::StorageAccessor->new(
        chronicle_reader => BOM::System::Chronicle::get_chronicle_reader($self->for_date),
        chronicle_writer => BOM::System::Chronicle::get_chronicle_writer(),
    );

    my $corp = Quant::Framework::CorporateAction::load($storage_accessor, $self->symbol);
    # no corporate actions in Chronicle
    return [] unless $corp;

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
            die 'Could not determine order of corporate actions on '
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
    is         => 'ro',
    lazy_build => 1,
);

sub _build_resets_at_open {
    my $self = shift;

    return $self->submarket->resets_at_open;
}

has risk_profile_setter => (
    is      => 'rw',
    default => 'underlying_symbol',
);

has [qw(always_available risk_profile base_commission)] => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_always_available {
    my $self = shift;
    return $self->submarket->always_available;
}

sub _build_risk_profile {
    my $self = shift;

    my $rp;
    if ($self->submarket->risk_profile) {
        $rp = $self->submarket->risk_profile;
        $self->risk_profile_setter('submarket');
    } else {
        $rp = $self->market->risk_profile;
        $self->risk_profile_setter('market');
    }

    return $rp;
}

sub _build_base_commission {
    my $self = shift;

    return $self->submarket->base_commission;
}

sub calculate_spread {
    my ($self, $volatility) = @_;

    die 'volatility is zero for ' . $self->symbol if $volatility == 0;

    my $spread_multiplier = BOM::System::Config::quants->{commission}->{adjustment}->{spread_multiplier};
    # since it is only vol indices
    my $spread  = $self->spot * sqrt($volatility**2 * 2 / (365 * 86400)) * $spread_multiplier;
    my $y       = POSIX::floor(log($spread) / log(10));
    my $x       = $spread / (10**$y);
    my $rounded = max(2, round($x / 2) * 2);

    return $rounded * 10**$y;
}

no Moose;

__PACKAGE__->meta->make_immutable(
    constructor_name    => '_new',
    replace_constructor => 1
);

1;
