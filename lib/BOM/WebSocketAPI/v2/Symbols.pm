package BOM::WebSocketAPI::v2::Symbols;

use strict;
use warnings;

use Mojo::Base 'BOM::WebSocketAPI::v2::BaseController';
use Finance::Asset;

use Date::Utility;
use BOM::Feed::Data::AnyEvent;
use BOM::Market::Underlying;
use BOM::Product::Contract::Finder qw(available_contracts_for_symbol);

# these package-level structures let us 'memo-ize' the symbol pools for purposes
# of full-list results and for hashed lookups by-displayname and by-symbol-code.

my ($_by_display_name, $_by_symbol, $_by_exchange) = ({}, {}, {});
for (Finance::Asset->instance->symbols) {
    my $sp = Finance::Asset->instance->get_parameters_for($_) || next;
    my $ul = BOM::Market::Underlying->new($_);
    $_by_display_name->{$ul->display_name} = $sp;
    # If this display-name has slashes, also generate a 'safe' version that can sit in REST expressions
    if ((my $safe_name = $ul->display_name) =~ s(/)(-)g) {
        $_by_display_name->{$safe_name} = $sp;
    }
    $_by_symbol->{$_} = $sp;
    push @{$_by_exchange->{$ul->exchange_name}}, $ul->display_name;
}

# this constructs the symbol record sanitized for consumption by api clients.
sub _description {
    my $symbol = shift;
    my $ul     = BOM::Market::Underlying->new($symbol) || return;
    my $iim    = $ul->intraday_interval ? $ul->intraday_interval->minutes : '';
    # sometimes the ul's exchange definition or spot-pricing is not availble yet.  Make that not fatal.
    my $exchange_is_open = eval { $ul->exchange } ? $ul->exchange->is_open_at(time) : '';
    my ($spot, $spot_time, $spot_age) = ('', '', '');
    if ($spot = eval { $ul->spot }) {
        $spot_time = $ul->spot_time;
        $spot_age  = $ul->spot_age;
    }

    return {
        symbol                    => $symbol,
        display_name              => $ul->display_name,
        pip                       => $ul->pip_size,
        symbol_type               => $ul->instrument_type,
        exchange_name             => $ul->exchange_name,
        exchange_is_open          => $exchange_is_open,
        quoted_currency_symbol    => $ul->quoted_currency_symbol,
        intraday_interval_minutes => $iim,
        is_trading_suspended      => $ul->is_trading_suspended,
        spot                      => $spot,
        spot_time                 => $spot_time,
        spot_age                  => $spot_age,
    };
}

sub active_symbols {
    my ($c, $args) = @_;

    my $by = $args->{active_symbols};
    $by =~ /^(symbol|display_name)$/ or die 'by symbol or display_name only';
    return {
        msg_type       => 'active_symbols',
        active_symbols => {
            map { $_->{$by} => $_ }
                grep { !$_->{is_trading_suspended} && $_->{exchange_is_open} }
                map { _description($_) }
                keys %$_by_symbol
        },
    };
}

sub exchanges {
    my $class = shift;
    return $_by_exchange;
}

sub ok_symbol {
    my $c      = shift;
    my $symbol = $c->stash('symbol') || die 'routing error: symbol';
    my $sp     = symbol_search($symbol) || return $c->_fail("invalid symbol: $symbol", 404);
    $c->stash(sp => $sp);
    return 1;
}

sub list {
    return shift->_pass({symbols => [map { _description($_) } sort keys %$_by_symbol]});
}

sub symbol {
    my $c = shift;
    my $s = $c->stash('sp')->{symbol};
    return $c->_pass(_description($s));
}

sub price {
    my $c      = shift;
    my $symbol = $c->stash('sp')->{symbol};
    my $ul     = BOM::Market::Underlying->new($symbol);
    if ($ul->feed_license eq 'realtime') {
        my $tick = $ul->get_combined_realtime;
        $c->_pass({
            symbol => $symbol,
            time   => $tick->{epoch},
            price  => $tick->{quote},
        });
    } else {
        $c->_fail("realtime quotes are not available for $symbol");
    }
    return;
}

sub symbol_search {
    my $s = shift;
    return $_by_symbol->{$s} || $_by_display_name->{$s}    # or undef if not found.
}

sub _validate_start_end {
    my ($c, $args) = @_;

    my $ul    = $args->{ul} || die 'no underlying';
    my $start = $args->{start};
    my $end   = $args->{end};
    my $count = $args->{count};

    # we must not return to the client any ticks/candles after this epoch
    my $licensed_epoch = $ul->last_licensed_display_epoch;

    unless ($start
        and $start =~ /^[0-9]+$/
        and $start > time() - 365 * 86400
        and $start < $licensed_epoch)
    {
        $start = $licensed_epoch - 86400;
    }
    unless ($end
        and $end =~ /^[0-9]+$/
        and $end > $start)
    {
        $end = time();
    }
    unless ($count
        and $count =~ /^[0-9]+$/
        and $count > 0
        and $count < 5000)
    {
        $count = 500;
    }

    unless ($ul->feed_license eq 'realtime') {
        # if feed doesn't have realtime license, we should adjust end_time in such a way
        # as not to break license conditions
        if ($licensed_epoch < $end) {
            my $shift_back = $end - $licensed_epoch;
            unless ($ul->feed_license eq 'delayed') {
                $end = $licensed_epoch;
                $c->app->log->debug("Due to feed license end_time has been changed to $licensed_epoch");
            }
            if ($args->{adjust_start_time}) {
                $start -= $shift_back;
                $c->app->log->debug("start_time has been changed to $start");
            }
        }
    }

    if ($args->{adjust_start_time}) {
        unless ($ul->exchange->is_open_at($end)) {
            $c->app->log->debug("Exchange is closed at $end, adjusting start_time");
            my $shift_back = $ul->exchange->seconds_since_close_at($end);
            unless (defined $shift_back) {
                my $last_day = $ul->exchange->trade_date_before(Date::Utility->new($end));
                if ($last_day) {
                    my $closes = $ul->exchange->closing_on($last_day)->epoch;
                    $shift_back = $end - $closes;
                }
            }
            if ($shift_back) {
                $start -= $shift_back;
                $end   -= $shift_back;
                $c->app->log->debug("Adjusted time range: $start - " . ($end // 'disconnect'));
            }
        }
    }

    $args->{start} = $start;
    $args->{end}   = $end;
    $args->{count} = $count;

    return $args;
}

sub _ticks {
    my ($c, $args) = @_;

    $args = _validate_start_end($c, $args);

    my $ul    = $args->{ul} || die 'no underlying';
    my $start = $args->{start};
    my $end   = $args->{end};
    my $count = $args->{count};

    my $ticks = $ul->feed_api->ticks_start_end_with_limit_for_charting({
        start_time => $start,
        end_time   => $end,
        limit      => $count,
    });

    return [map { {time => $_->epoch, price => $_->quote} } reverse @$ticks];
}

sub ticks {
    my $c      = shift;
    my $symbol = $c->stash('sp')->{symbol};
    my $ul     = BOM::Market::Underlying->new($symbol);
    my $ticks  = $c->_ticks({
        ul    => $ul,
        start => $c->param('start') // 0,
        end   => $c->param('end') // 0,
        count => $c->param('count') // 0,
    });
    return $c->_pass({ticks => $ticks});
}

sub _candles {
    my ($c, $args) = @_;

    $args = _validate_start_end($c, $args);

    my $ul          = $args->{ul} || die 'no underlying';
    my $start       = $args->{start};
    my $end         = $args->{end};
    my $count       = $args->{count};
    my $granularity = uc($args->{granularity} || 'M1');

    my ($unit, $size) = $granularity =~ /^([DHMS])(\d+)$/ or return;

    my $period = do { {D => 86400, H => 3600, M => 60, S => 1}->{$unit} * $size };
    $start = $start - $start % $period;
    my $end_max = $start + $period * $count;
    $end = $end_max > $end ? $end : $end_max;

    $c->stash->{feeder} ||= BOM::Feed::Data::AnyEvent->new;
    my $w = $c->stash->{feeder}->get_ohlc(
        underlying => $ul->symbol,
        start_time => $start,
        end_time   => $end,
        interval   => $size . lc $unit,
        on_result  => $args->{sender},
    );
    return $w;

}

# needed only for REST API..
sub candles {
    my $c      = shift;
    my $symbol = $c->stash('sp')->{symbol};
    my $ul     = BOM::Market::Underlying->new($symbol);

    my $done = AnyEvent->condvar;
    my $candles;
    my $watcher = $c->_candles({
            ul          => $ul,
            start       => $c->param('start') // 0,
            end         => $c->param('end') // 0,
            count       => $c->param('count') // 0,
            granularity => $c->param('granularity') // '',
            sender      => sub { $candles = shift; $done->send },
        }) || return $c->_fail("invalid candles request");

    $done->recv;
    $c->stash->{feeder}->_pg->destroy;
    delete $c->stash->{feeder};
    return $c->_pass({candles => $candles});
}

# needed only for REST API..
sub contracts {
    my $c      = shift;
    my $symbol = $c->stash('sp')->{symbol};
    my $output = available_contracts_for_symbol({symbol => $symbol});
    return $c->_pass($output);
}

1;
