package BOM::Market::Exchange;

=head1 NAME

BOM::Market::Exchange

=head1 DESCRIPTION

Models exchanges: places where underlyings are traded, e.g. LSE.

=cut

=head1 USAGE

    my $exchange = BOM::Market::Exchange->new('LSE');

=cut

use strict;
use warnings;
use feature 'state';

use Moose;
use DateTime;
use DateTime::TimeZone;
use File::Slurp qw(read_file);
use List::Util qw(min max);
use Memoize;
use Carp;
use Scalar::Util qw(looks_like_number);

use Date::Utility;
use BOM::Market::Currency;
use BOM::MarketData::ExchangeConfig;
use Memoize::HashKey::Ignore;
use BOM::Platform::Runtime;
use Time::Duration::Concise;
use BOM::Platform::Context qw(localize);

use BOM::Utility::Log4perl qw( get_logger );

# We're going to do this from time to time.
# I claim it's under control.
## no critic(TestingAndDebugging::ProhibitNoWarnings)
no warnings 'recursion';

=head1 ATTRIBUTES

=head2 symbol

The standard symbol used to reference this exchange

=head2 pretty_name

The client-friendly name

=head2 delay_amount

Amount the feed for this exchange needs to be delayed, in minutes.

=head2 representative_trading_date

A Date::Utility for a non-DST day which we believe represents normal trading for this exchange.

=head2 open_on_weekends

Is this exchange available for trading on a weekend?

=cut

has [qw(
        symbol
        pretty_name
        offered
        )
    ] => (
    is  => 'ro',
    isa => 'Str',
    );

has [qw(
        representative_trading_date
        )
    ] => (
    is         => 'ro',
    isa        => 'Maybe[Date::Utility]',
    lazy_build => 1,
    );

has [qw(
        delay_amount
        )
    ] => (
    is      => 'ro',
    isa     => 'Num',
    default => 60,
    );

=head2 currency

Exchange's main currency.

=cut

has currency => (
    is  => 'ro',
    isa => 'Maybe[BOM::Market::Currency]',
);

=head2 holidays

The hashref mapping of the days_since_epoch of all the holidays to their
descriptions or weights. If the weight is non-zero, the exchange still trades on
that day.

=cut

has holidays => (
    is  => 'rw',
    isa => 'HashRef',
);

## PRIVATE attribute market_times
#
# A hashref of human-readable times, which are converted to epochs for a given day
#
has market_times => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub { return {}; },
);

has is_affected_by_dst => (
    is         => 'ro',
    isa        => 'Bool',
    lazy_build => 1,
);

has open_on_weekends => (
    is      => 'ro',
    default => 0,
);

=head2 display_name

A name we can show to someone someday

=cut

has display_name => (
    is      => 'ro',
    lazy    => 1,
    default => sub { return shift->symbol },
);

=head2 trading_timezone


The timezone in which the exchange conducts business.

This should be a string which will allow the standard DateTime modules to find the proper information.

=head2 tenfore_trading_timezone

This reflects the timezone in which tenfore thinks the exchange conducts business.

=cut

has [qw(trading_timezone tenfore_trading_timezone)] => (
    is  => 'ro',
    isa => 'Maybe[Str]',
);

sub BUILDARGS {
    my ($class, $symbol) = @_;

    croak "Exchange symbol must be specified" unless $symbol;
    my $params_ref = BOM::MarketData::ExchangeConfig->new({symbol => $symbol})->get_parameters;
    $params_ref->{symbol} = $symbol;

    if (defined $params_ref->{currency}) {
        my $currency = uc $params_ref->{currency};
        if (length($currency) != 3 or $currency eq 'NA') {
            delete $params_ref->{currency};
        } else {
            $params_ref->{currency} = BOM::Market::Currency->new($currency);
        }
    } else {
        delete $params_ref->{currency};
    }

    my %holidays          = ();
    my $today_since_epoch = Date::Utility::today->days_since_epoch;

    for (keys %{$params_ref->{holidays}}) {
        my $when = Date::Utility->new($_);
        $holidays{$when->days_since_epoch} = $params_ref->{holidays}->{$_};
    }

    $params_ref->{holidays} = \%holidays;

    foreach my $dst_maybe (keys %{$params_ref->{market_times}}) {
        foreach my $trading_segment (keys %{$params_ref->{market_times}->{$dst_maybe}}) {
            if ($trading_segment ne 'trading_breaks') {
                $params_ref->{market_times}->{$dst_maybe}->{$trading_segment} = Time::Duration::Concise::Localize->new(
                    interval => $params_ref->{market_times}->{$dst_maybe}->{$trading_segment},
                    locale   => BOM::Platform::Context::request()->language
                );
            } else {
                my $break_intervals = $params_ref->{market_times}->{$dst_maybe}->{$trading_segment};
                my @converted;
                foreach my $int (@$break_intervals) {
                    my $open_int = Time::Duration::Concise::Localize->new(
                        interval => $int->[0],
                        locale   => BOM::Platform::Context::request()->language
                    );
                    my $close_int = Time::Duration::Concise::Localize->new(
                        interval => $int->[1],
                        locale   => BOM::Platform::Context::request()->language
                    );
                    push @converted, [$open_int, $close_int];
                }
                $params_ref->{market_times}->{$dst_maybe}->{$trading_segment} = \@converted;
            }
        }
    }

    return $params_ref;
}

=head2 is_OTC

Is this an over the counter exchange?

=cut

has is_OTC => (
    is         => 'ro',
    isa        => 'Bool',
    init_arg   => undef,
    lazy_build => 1,
);

sub _build_is_OTC {
    my $self = shift;
    return ($self->symbol eq 'FOREX' or $self->symbol eq 'RANDOM' or $self->symbol eq 'RANDOM_NOCTURNE');
}

=head1 METHODS

=head2 new($symbol)

Returns object for given exchange. Accepts single parameter - exchange symbol.

=cut

has _build_time => (
    is      => 'ro',
    default => sub { time },
);

# we cache objects, when we're getting object from cache we should check if it isn't too old
# currently we allow age to be up to 30 seconds
sub _object_expired {
    return shift->_build_time + 30 < time;
}

my %_cached_objects;

sub new {
    my ($self, $symbol) = @_;

    my $ex = $_cached_objects{$symbol};
    if (not $ex or $ex->_object_expired) {
        $ex = $self->_new($symbol);
        $_cached_objects{$symbol} = $ex;
    }

    return $ex;
}

=head2 weight_on

Returns the weight assigned to the day of a given Date::Utility object. Return 0
if the exchange does not trade on this day and 1 if there is no pseudo-holiday.

=cut

sub weight_on {
    my ($self, $when) = @_;

    return ($self->trades_on($when) && !(defined $self->holidays->{$when->days_since_epoch}))
        ? 1
        : 0;
}

=head2 has_holiday_on

Returns true if the exchange has a holiday on the day of a given Date::Utility
object.

Holidays named 'pseudo-holiday' are not considered real holidays, this sub will return 0 for them.

=cut

sub has_holiday_on {
    my ($self, $when) = @_;

    my $holiday = $self->holidays->{$when->days_since_epoch};
    return defined $holiday && $holiday ne 'pseudo-holiday';
}

=head2 trades_on

Returns true if trading is done on the day of a given Date::Utility.

=cut

sub trades_on {
    my ($self, $when) = @_;

    state %trades_cache;

    my $really_when = $self->trading_date_for($when);
    my $days_since  = $really_when->days_since_epoch;
    my $symbol      = $self->symbol;

    $trades_cache{$symbol}->{$days_since} //= ((
                   $self->open_on_weekends
                or $really_when->is_a_weekday
        )
            and not $self->has_holiday_on($really_when)) ? 1 : 0;

    return $trades_cache{$symbol}->{$days_since};
}

=head2 trade_date_after

Returns a Date::Utility for the date on which trading is open after the given Date::Utility

=cut

sub trade_date_after {
    my ($self, $when) = @_;

    my $date_next;
    my $counter = 1;
    my $begin   = $self->trading_date_for($when);

    while (not $date_next and $counter <= 15) {
        my $possible = $begin->plus_time_interval($counter . 'd');
        $date_next = ($self->trades_on($possible)) ? $possible : undef;
        $counter++;
    }

    return $date_next;
}

=head2 trading_date_for

The date on which trading is considered to be taking place even if it is not the same as the GMT date.

Returns a Date object representing midnight GMT of the trading date.

Note that this does not handle trading dates are offset forward beyond the next day (24h). It will need additional work if these are found to exist.

=cut

sub trading_date_for {
    my ($self, $date) = @_;

    return $date->truncate_to_day unless ($self->trading_date_can_differ);

    my $next_day = $date->plus_time_interval('1d')->truncate_to_day;
    my $open_ti =
        $self->market_times->{$self->_times_dst_key($next_day)}->{daily_open};

    return ($open_ti and $next_day->epoch + $open_ti->seconds <= $date->epoch)
        ? $next_day
        : $date->truncate_to_day;

}

has trading_date_can_differ => (
    is         => 'ro',
    isa        => 'Bool',
    lazy_build => 1,
    init_arg   => undef,
);

# This presumes we only ever move on the open side, never past the end of a day.
sub _build_trading_date_can_differ {
    my $self = shift;
    my @premidnight_opens =
        grep { $_->seconds < 0 }
        map  { $self->market_times->{$_}->{daily_open} }
        grep { exists $self->market_times->{$_}->{daily_open} }
        keys %{$self->market_times};

    return (scalar @premidnight_opens) ? 1 : 0;
}

=head2 calendar_days_to_trade_date_after

Returns the number of calendar days between a given Date::Utility
and the next day on which trading is open.

=cut

sub calendar_days_to_trade_date_after {
    my ($self, $when) = @_;

    return $self->trade_date_after($when)->days_between($when);
}
Memoize::memoize('calendar_days_to_trade_date_after', NORMALIZER => '_normalize_on_dates');

=head2 trade_date_before

Returns a Date::Utility representing the trading day before a given Date::Utility

If given the additional arg 'lookback', will look back X number of
trading days, rather than just one.

=cut

sub trade_date_before {
    my ($self, $when, $additional_args) = @_;

    my $begin = $self->trading_date_for($when);
    my $lookback = (ref $additional_args) ? $additional_args->{'lookback'} : 1;

    my $date_behind;
    my $counter = 0;

    while (not $date_behind and $counter < 15) {
        my $possible = $begin->minus_time_interval(($lookback + $counter) . 'd');
        $date_behind =
            ($self->trades_on($possible) and $self->trading_days_between($possible, $when) == $lookback - 1) ? $possible : undef;
        $counter++;
    }

    return $date_behind;
}

sub _days_between {

    my ($self, $begin, $end) = @_;

    my @days_between = ();

    # Don't include start and end days.
    my $current = $begin->truncate_to_day->plus_time_interval('1d');
    $end = $end->truncate_to_day->minus_time_interval('1d');

    # Generate all days between.
    while (not $current->is_after($end)) {
        push @days_between, $current;
        $current = $current->plus_time_interval('1d');    # Next day, please!
    }

    return \@days_between;
}
Memoize::memoize('_days_between', NORMALIZER => '_normalize_on_dates');

=head2 trading_days_between

Returns the number of trading days _between_ two given RMG dates.

    $exchange->trading_days_between(Date::Utility->new('4-May-10'),Date::Utility->new('5-May-10'));

=cut

sub trading_days_between {
    my ($self, $begin, $end) = @_;

    # Count up how many are trading days.
    return scalar grep { $self->trades_on($_) } @{$self->_days_between($begin, $end)};
}
Memoize::memoize('trading_days_between', NORMALIZER => '_normalize_on_dates');

=head2 holiday_days_between

Returns the number of holidays _between_ two given RMG dates.

    $exchange->trading_days_between(Date::Utility->new('4-May-10'),Date::Utility->new('5-May-10'));

=cut

sub holiday_days_between {
    my ($self, $begin, $end) = @_;

    # Count up how many are trading days.
    return scalar grep { $self->has_holiday_on($_) } @{$self->_days_between($begin, $end)};
}
Memoize::memoize('holiday_days_between', NORMALIZER => '_normalize_on_dates');

=head1 OPEN/CLOSED QUESTIONS ETC.

BOM::Market::Exchange can be questioned about various things related to opening/closing.
The following shows all these questions via code examples:

=head2 is_open

    if ($self->is_open)

=cut

sub is_open {
    my $self = shift;
    return $self->is_open_at(time);
}

=head2 is_open_at

    if ($self->is_open_at($epoch))

=cut

sub is_open_at {
    my ($self, $when) = @_;

    my $open;
    my $date = (ref $when) ? $when : Date::Utility->new($when);
    if (my $opening = $self->opening_on($date)) {
        $open = 1
            if (not $date->is_before($opening)
            and not $date->is_after($self->closing_on($date)));
        if ($self->is_in_trading_break($date)) {
            $open = undef;
        }
    }

    return $open;
}

=head2 will_open

    if ($self->will_open)

=cut

sub will_open {
    my $self = shift;
    return $self->will_open_after(time);
}

=head2 will_open_after

    if ($self->will_open_after($epoch))

=cut

sub will_open_after {
    my ($self, $epoch) = @_;

    # basically, if open is "0", but not undef. Annoying _market_opens logic
    if (defined $self->_market_opens($epoch)->{'open'}
        and not $self->_market_opens($epoch)->{'open'})
    {
        return 1;
    }
    return;
}

=head2 seconds_until_open_at

    my $seconds = $self->seconds_until_open_at($epoch);

=cut

sub seconds_until_open_at {
    my ($self, $epoch) = @_;
    return $self->_market_opens($epoch)->{'opens'};
}

=head2 seconds_since_open_at

    my $seconds = $self->seconds_since_open_at($epoch);

=cut

sub seconds_since_open_at {
    my ($self, $epoch) = @_;
    return $self->_market_opens($epoch)->{'opened'};
}

=head2 seconds_until_close_at

    my $seconds = $self->seconds_until_close_at($epoch);

=cut

sub seconds_until_close_at {
    my ($self, $epoch) = @_;
    return $self->_market_opens($epoch)->{'closes'};
}

=head2 seconds_since_close_at

    my $seconds = $self->seconds_since_close_at($epoch);

=cut

sub seconds_since_close_at {
    my ($self, $epoch) = @_;
    return $self->_market_opens($epoch)->{'closed'};
}

## PRIVATE _market_opens
#
# PARAMETERS :
# - time   : the time as a timestamp
#
# RETURNS    : A reference to a hash with the following keys:
# - open   : is set to 1 if the market is currently open, 0 if market is closed
#            but will open, 'undef' if market is closed and will not open again
#            today.
# - closed : undefined if market has not been open yet, otherwise contains the
#            seconds for how long the market was closed.
# - opens  : undefined if market is currently open and does not open anymore today,
#            otherwise the market will open in 'opens' seconds.
# - closes : undefined if open is undef, otherwise market will close in 'closes' seconds.
# - opened : undefined if market is closed, contains the seconds the market has
#            been open.
#
#
########
sub _market_opens {
    my ($self, $time) = @_;

    # Date::Utility should handle this, but let's not bother;
    my $when = (ref $time) ? $time : Date::Utility->new($time);
    my $date = $when;

    # Figure out which "trading day" we are on
    # even if it differs from the GMT calendar day.
    my $next_day  = $date->plus_time_interval('1d')->truncate_to_day;
    my $next_open = $self->opening_on($next_day);
    $date = $next_day if ($next_open and not $date->is_before($next_open));

    my $open  = $self->opening_on($date);
    my $close = $self->closing_on($date);

    if (not $open) {

        # date is not a trading day: will not and has not been open today
        my $next_open = $self->opening_on($self->trade_date_after($when));
        return {
            open   => undef,
            opens  => $next_open->epoch - $when->epoch,
            opened => undef,
            closes => undef,
            closed => undef,
        };
    }

    my $breaks = $self->trading_breaks($when);
    # not trading breaks
    if (not $breaks) {
        # Past closing time: opens next trading day, and has been open today
        if ($close and not $when->is_before($close)) {
            return {
                open   => undef,
                opens  => undef,
                opened => $when->epoch - $open->epoch,
                closes => undef,
                closed => $when->epoch - $close->epoch,
            };
        } elsif ($when->is_before($open)) {
            return {
                open   => 0,
                opens  => $open->epoch - $when->epoch,
                opened => undef,
                closes => $close->epoch - $when->epoch,
                closed => undef,
            };
        } elsif ($when->is_same_as($open) or ($when->is_after($open) and $when->is_before($close)) or $when->is_same_same($close)) {
            return {
                open   => 1,
                opens  => undef,
                opened => $when->epoch - $open->epoch,
                closes => $close->epoch - $when->epoch,
                closed => undef,
            };
        }
    } else {
        my @breaks = @$breaks;
        # Past closing time: opens next trading day, and has been open today
        if ($close and not $when->is_before($close)) {
            return {
                open   => undef,
                opens  => undef,
                opened => $when->epoch - $breaks[-1][1]->epoch,
                closes => undef,
                closed => $when->epoch - $close->epoch,
            };
        } elsif ($when->is_before($open)) {
            return {
                open   => 0,
                opens  => $open->epoch - $when->epoch,
                opened => undef,
                closes => $breaks[0][0]->epoch - $when->epoch,
                closed => undef,
            };
        } else {
            my $current_open = $open;
            for (my $i = 0; $i <= $#breaks; $i++) {
                my $int_open  = $breaks[$i][0];
                my $int_close = $breaks[$i][1];
                my $next_open = exists $breaks[$i + 1] ? $breaks[$i + 1][0] : $close;

                if ($when->is_after($current_open) and $when->is_before($int_open)) {
                    return {
                        open   => 1,
                        opens  => undef,
                        opened => $when->epoch - $current_open->epoch,
                        closes => $int_open->epoch - $when->epoch,
                        closed => undef,
                    };
                } elsif ($when->is_same_as($int_open)
                    or ($when->is_after($int_open) and $when->is_before($int_close))
                    or $when->is_same_as($int_close))
                {
                    return {
                        open   => 0,
                        opens  => $int_close->epoch - $when->epoch,
                        opened => undef,
                        closes => $close->epoch - $when->epoch,       # we want to know seconds to official close
                        closed => $when->epoch - $int_open->epoch,
                    };
                } elsif ($when->is_after($int_close) and $when->is_before($next_open)) {
                    return {
                        open   => 1,
                        opens  => undef,
                        opened => $when->epoch - $int_close->epoch,
                        closes => $next_open->epoch - $when->epoch,
                        closed => undef,
                    };
                }
            }

        }
    }

    return;
}

=head1 OPENING TIMES

The following methods tell us when the exchange opens/closes on a given date.

=head2 opening_on

Returns the opening time (Date::Utility) of the exchange for a given Date::Utility.

    my $opening_epoch = $exchange->opening_on(Date::Utility->new('25-Dec-10')); # returns undef (given Xmas is a holiday)

=cut

sub opening_on {
    my ($self, $when) = @_;

    return $self->opens_late_on($when) // $self->_get_exchange_open_times($when, 'daily_open');
}

=head2 closing_on

Similar to opening_on.

    my $closing_epoch = $exchange->closing_on(Date::Utility->new('25-Dec-10')); # returns undef (given Xmas is a holiday)

=cut

sub closing_on {
    my ($self, $when) = @_;

    return $self->closes_early_on($when) // $self->_get_exchange_open_times($when, 'daily_close');
}

=head2 settlement_on

Similar to opening_on.

    my $settlement_epoch = $exchange->settlement_on(Date::Utility->new('25-Dec-10')); # returns undef (given Xmas is a holiday)

=cut

sub settlement_on {
    my ($self, $when) = @_;

    return $self->_get_exchange_open_times($when, 'daily_settlement');
}

=head2 trading_breaks

Defines the breaktime for this exchange.

=cut

sub trading_breaks {
    my ($self, $when) = @_;
    return $self->_get_exchange_open_times($when, 'trading_breaks');
}

sub is_in_trading_break {
    my ($self, $when) = @_;

    $when = Date::Utility->new($when);
    my $in_trading_break = 0;
    if (my $breaks = $self->trading_breaks($when)) {
        foreach my $break_interval (@{$breaks}) {
            if ($when->epoch >= $break_interval->[0]->epoch and $when->epoch <= $break_interval->[1]->epoch) {
                $in_trading_break++;
                last;
            }
        }
    }

    return $in_trading_break;
}

=head2 closes_early_on

Returns true if the exchange closes early on the given (RMG) date.

=cut

sub closes_early_on {
    my ($self, $when) = @_;

    my $closes_early;
    if ($self->trades_on($when)) {
        my $listed = $self->market_times->{early_closes}->{$when->date_ddmmmyyyy};
        if ($listed) {
            $closes_early = $when->truncate_to_day->plus_time_interval($listed);
        } elsif (my $scheduled_changes = $self->regularly_adjusts_trading_hours_on($when)) {
            $closes_early = $when->truncate_to_day->plus_time_interval($scheduled_changes->{daily_close}->{to})
                if ($scheduled_changes->{daily_close});
        }
    }

    return $closes_early;
}

=head2 opens_late

Returns true if the exchange opens late on the given (RMG) date.

=cut

sub opens_late_on {
    my ($self, $when) = @_;

    my $opens_late;
    if ($self->trades_on($when)) {
        my $listed = $self->market_times->{late_opens}->{$when->date_ddmmmyyyy};
        if ($listed) {
            $opens_late = $when->truncate_to_day->plus_time_interval($listed);
        } elsif (my $scheduled_changes = $self->regularly_adjusts_trading_hours_on($when)) {
            $opens_late = $when->truncate_to_day->plus_time_interval($scheduled_changes->{daily_open}->{to})
                if ($scheduled_changes->{daily_open});
        }
    }

    return $opens_late;
}

sub _get_exchange_open_times {
    my ($self, $date, $which) = @_;

    my $when = (ref $date) ? $date : Date::Utility->new($date);
    my $that_midnight = $self->trading_date_for($when);
    my $requested_time;
    if ($self->trades_on($that_midnight)) {
        my $dst_key = $self->_times_dst_key($that_midnight);
        my $ti      = $self->market_times->{$dst_key}->{$which};
        if ($ti) {
            if (ref $ti eq 'ARRAY') {
                for my $int (@$ti) {
                    my $start_of_break = $that_midnight->plus_time_interval($int->[0]);
                    my $end_of_break   = $that_midnight->plus_time_interval($int->[1]);
                    push @{$requested_time}, [$start_of_break, $end_of_break];
                }
            } else {
                $requested_time = $that_midnight->plus_time_interval($ti);
            }
        }
    }
    return $requested_time;    # returns null on no trading days.
}

=head2 trades_normal_hours_on

Boolean which indicates if the exchange is trading in its normal hours on a given Date::Utility

=cut

sub trades_normal_hours_on {
    my ($self, $when) = @_;

    my $trades_normal_hours =
        ($self->trades_on($when) and not $self->closes_early_on($when) and not $self->opens_late_on($when));

    return $trades_normal_hours;
}

=head2 regularly_adjusts_trading_hours_on

Does this Exchange always shift from regular trading hours on Dates "like"
the provided Date?

=cut

sub regularly_adjusts_trading_hours_on {

    my ($self, $when) = @_;

    my $changes;

    if ($when->day_of_week == 5) {
        my $rule = localize('Fridays');
        if ($self->symbol eq 'FOREX') {
            $changes = {
                'daily_close' => {
                    to   => '21h',
                    rule => $rule,
                }};
        } elsif ($self->symbol eq 'JSC') {
            $changes = {
                'morning_close' => {
                    to   => '4h30m',
                    rule => $rule,
                },
                'afternoon_open' => {
                    to   => '7h',
                    rule => $rule
                }};
        }
    }

    return $changes;
}

=head2 is_in_dst_at

Is this exchange trading on daylight savings times for the given epoch?

=cut

sub is_in_dst_at {
    my ($self, $epoch) = @_;

    my $in_dst = 0;

    if ($self->is_affected_by_dst) {
        my $dt = DateTime->from_epoch(epoch => $epoch);
        $dt->set_time_zone($self->trading_timezone);
        $in_dst = $dt->is_dst;
    }

    return $in_dst;
}
Memoize::memoize(
    'is_in_dst_at',
    NORMALIZER => '_normalize_on_symbol_and_args',
);

sub _times_dst_key {
    my ($self, $when) = @_;

    my $epoch = (ref $when) ? $when->epoch : $when;

    return ($self->is_in_dst_at($epoch)) ? 'dst' : 'standard';
}

=head2 seconds_of_trading_between_epochs

Get total number of seconds of trading time between two epochs accounting for breaks.

=cut

sub seconds_of_trading_between_epochs {
    my ($self, $start_epoch, $end_epoch) = @_;

    my $result = 0;

    my $full_day = 86400;

    if ($start_epoch < $end_epoch) {

        my $day_start = $start_epoch - ($start_epoch % $full_day);
        my $day_end   = $end_epoch -   ($end_epoch % $full_day) - 1;

        if ($day_start == $start_epoch and $day_end == $end_epoch) {
            if ($day_end - $day_start > 86399) {
                my $day_earlier = $end_epoch - $full_day;
                $result =
                    $self->seconds_of_trading_between_epochs($start_epoch, $day_earlier) +
                    $self->_computed_trading_seconds($day_earlier + 1, $end_epoch);
            } else {
                $result = $self->_computed_trading_seconds($start_epoch, $end_epoch);
            }
        } else {
            my $start_eod = $day_start + 86399;
            if ($end_epoch <= $start_eod) {
                $result = $self->_computed_trading_seconds($start_epoch, $end_epoch);
            } else {
                $result =
                    $self->_computed_trading_seconds($start_epoch, $start_eod) +
                    $self->seconds_of_trading_between_epochs($start_eod + 1, $day_end) +
                    $self->_computed_trading_seconds($day_end + 1, $end_epoch);
            }
        }
    }

    return $result;
}

# Ignore all times which are not on day boundaries
tie my %seconds_cache => 'Memoize::HashKey::Ignore',
    IGNORE            => sub {
    my @bits = split /,/, shift;
    return ($bits[1] % 86400 && ($bits[2] + 1) % 86400);
    };
Memoize::memoize(
    'seconds_of_trading_between_epochs',
    NORMALIZER   => '_normalize_on_symbol_and_args',
    SCALAR_CACHE => [HASH => \%seconds_cache],
);

## PRIVATE method _computed_trading_seconds
#
# This one ACTUALLY does the heavy lifting of determining the number of trading seconds in an intraday period.
#
sub _computed_trading_seconds {
    my ($self, $start, $end) = @_;

    my $total_trading_time = 0;
    my $when               = Date::Utility->new($start);

    if ($self->trades_on($when)) {

        # Do the full computation.
        my $opening_epoch = $self->opening_on($when)->epoch;
        my $closing_epoch = $self->closing_on($when)->epoch;

# Total trading time left in interval. This is always between 0 to $period_secs_basis.
# This will automatically take care of early close because market close will just be the early close time.
        my $total_trading_time_including_lunchbreaks =
            max(min($closing_epoch, $end), $opening_epoch) - min(max($opening_epoch, $start), $closing_epoch);

        my $total_lunch_break_time = 0;

# Now take care of lunch breaks. But handle early close properly. It could be that
# the early close already wipes out the need to handle lunch breaks.
# Handle early close. For example on 24 Dec 2009, HKSE opens at 2:00, and stops
# for lunch at 4:30 and never reopens. In that case the value of $self->closing_on($thisday)
# is 4:30, and lunch time between 4:30 to 6:00 is no longer relevant.
        if (my $breaks = $self->trading_breaks($when)) {
            for my $break_interval (@{$breaks}) {
                my $interval_open  = $break_interval->[0];
                my $interval_close = $break_interval->[1];
                my $close_am       = min($interval_open->epoch, $closing_epoch);
                my $open_pm        = min($interval_close->epoch, $closing_epoch);

                $total_lunch_break_time = max(min($open_pm, $end), $close_am) - min(max($close_am, $start), $open_pm);

                if ($total_lunch_break_time < 0) {
                    die 'Total lunch break time between ' . $start . '] and [' . $end . '] for exchange[' . $self->symbol . '] is negative';
                }
            }
        }

        $total_trading_time = $total_trading_time_including_lunchbreaks - $total_lunch_break_time;
        if ($total_trading_time < 0) {
            croak 'Total trading time (minus lunch) between ' . $start . '] and [' . $end . '] for exchange[' . $self->symbol . '] is negative.';
        }
    }

    return $total_trading_time;
}

=head2 is_affected_by_dst

Tells whether the exchange's opening times change due to daylight savings
at some point in the year.

=cut

sub _build_is_affected_by_dst {
    my $self = shift;

    my $tz = DateTime::TimeZone->new(name => $self->trading_timezone);

    # This returns some incomprehensible number... so make it a nice bool.
    return ($tz->has_dst_changes) ? 1 : 0;
}

# PRIVATE method
# Takes a two arguments: an epoch timestamp and which switch to find 'next' or 'prev'
sub _find_dst_switch {
    my ($self, $epoch, $direction) = @_;

    $direction = 'next'
        if (not defined $direction
        or scalar grep { $direction ne $_ } qw(next prev));

# Assumption: there is exactly one switch (each way) per year and no period is over 250 days long.
# If we limit our search in this way, we'll definitely find the closest switch
    my $SEARCHWIDTH = 250 * 24 * 60 * 60;
    my $low_time    = ($direction eq 'next') ? $epoch : $epoch - $SEARCHWIDTH;
    my $high_time   = ($direction eq 'next') ? $epoch + $SEARCHWIDTH : $epoch;

    # Now we need to find out the unswitched state of DST.
    # This will let us know which way to continue the search when we miss.
    my $unswitched_state = $self->is_in_dst_at($epoch);

    my $ret_val;    # Presume failure.
    my $continue_search = 1;

    while ($continue_search and $high_time > $low_time) {
        my $mid_time = int $low_time + ($high_time - $low_time) / 2;
        my $mid_state = $self->is_in_dst_at($mid_time);

        # Do we have the epoch where the switch happens?
        # If so, it should be different a second earlier.
        if ($mid_state != $self->is_in_dst_at($mid_time - 1)) {
            $continue_search = 0;
            $ret_val         = $mid_time;
        } elsif (($direction eq 'next' and $mid_state == $unswitched_state)
            or ($direction eq 'prev' and $mid_state != $unswitched_state))
        {
            # We're in the past of the switch.
            $low_time = $mid_time + 1;
        } else {
            # We're in the future from the switch
            $high_time = $mid_time;
        }
    }

    return $ret_val;
}

sub _build_representative_trading_date {
    my $self = shift;

    my $trading_day = $self->trade_date_after(Date::Utility::today());

    if ($self->is_in_dst_at($trading_day->epoch)) {
        $trading_day = Date::Utility->new($self->_find_dst_switch($trading_day->epoch, 'next'));
    }

    while (not $self->trades_normal_hours_on($trading_day)) {
        $trading_day = $self->trade_date_after($trading_day);
    }

    return $trading_day;
}

=head2 closed_for_the_day

Syntatic sugar to easily identify if the exchange is closed(already closed for the day or holiday or weekend).
We are not expecting any more activity in this exchange for today.

=cut

sub closed_for_the_day {
    my $self = shift;
    my $now  = Date::Utility->new;
    return (not $self->trades_on($now) or (not $self->is_open and $self->will_open));
}

=head2 last_trading_period

Returns the last_trading_period as { begin => ..., end => ... }
=cut

sub last_trading_period {
    my $self = shift;

    my $now              = Date::Utility->new;
    my $last_trading_day = $now;
    $last_trading_day = $self->trade_date_before($last_trading_day);

    my $open  = $self->opening_on($last_trading_day);
    my $close = $self->closing_on($last_trading_day);

    #For ASX, NSX and TSE Indices that can wrap around
    if ($close->is_before($open)) {
        $open = $open->minus_time_interval('1d');
    }

    return {
        begin => $open,
        end   => $close,
    };
}

=head2 regular_trading_day_after

a trading day that has no late open or early close

=cut

sub regular_trading_day_after {
    my ($self, $when) = @_;

    return if $self->closing_on($when);

    my $counter             = 0;
    my $regular_trading_day = $self->trade_date_after($when);
    while ($counter <= 10) {
        my $possible = $regular_trading_day->plus_time_interval($counter . 'd');
        if (    not $self->closes_early_on($possible)
            and not $self->opens_late_on($possible)
            and $self->trades_on($possible))
        {
            $regular_trading_day = $possible;
            last;
        }
        $counter++;
    }

    return $regular_trading_day;
}

## PRIVATE static method _normalize_on_dates
#
# Many of these functions don't change their results if asked for the
# same dates many times.  Let's exploit that for time over space
#
# This actually comes up in our pricing where we have to do many interpolations
# over the same ranges on different values.
#
# This attaches to the static method on the class for the lifetime of this instance.
# Since we only want the cache for our specific symbol, we need to include an identifier.

sub _normalize_on_dates {
    my ($self, @dates) = @_;

    return join '|', ($self->symbol, map { $_->days_since_epoch } @dates);
}

## PRIVATE static method _normalize_on_symbol_and_args
#
# Normalize on the args, but don't take the self part too seriously.

sub _normalize_on_symbol_and_args {
    my ($self, @other_args) = @_;

    return join ',', ($self->symbol, @other_args);
}

sub trading_period {
    my ($self, $when) = @_;

    return [] if not $self->trades_on($when);
    my $open = $self->opening_on($when);
    my $close = $self->closing_on($when);
    my $breaks = $self->trading_breaks($when);

    my @times = ($open);
    if (defined $breaks) {
        push @times, @{$_} for @{$breaks};
    }
    push @times, $close;

    my @periods;
    for (my $i=0; $i<$#times; $i+=2) {
        push @periods, [$times[$i], $times[$i+1]];
    }

    return \@periods;
}

no Moose;
__PACKAGE__->meta->make_immutable(
    constructor_name    => '_new',
    replace_constructor => 1
);

1;
