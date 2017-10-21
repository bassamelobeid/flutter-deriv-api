package BOM::RPC::v3::TickStreamer;

use strict;
use warnings;

use Finance::Asset;
use Date::Utility;

use BOM::RPC::v3::Utility;
use BOM::RPC::v3::Contract;
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use BOM::Platform::Context qw (localize request);
use Quant::Framework;
use BOM::Platform::Chronicle;

sub ticks {
    my $params = shift;

    my $symbol   = $params->{symbol};
    my $response = BOM::RPC::v3::Contract::validate_underlying($symbol);
    if ($response and exists $response->{error}) {
        return $response;
    }

    return {stash => {"${symbol}_display_decimals" => $response->display_decimals}};
}

sub ticks_history {
    my $params = shift;

    my $args   = $params->{args};
    my $symbol = $args->{ticks_history};

    my $response = BOM::RPC::v3::Contract::validate_symbol($symbol);
    if ($response and exists $response->{error}) {
        return $response;
    }

    my $ul = create_underlying($symbol);

    unless ($ul->feed_license =~ /^(realtime|delayed|daily)$/) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'StreamingNotAllowed',
                message_to_client => BOM::Platform::Context::localize("Streaming for this symbol is not available due to license restrictions.")});
    }

    if (exists $args->{subscribe} and $args->{subscribe} eq '1') {
        my $status = BOM::RPC::v3::Contract::validate_license($ul);
        if ($status and exists $status->{error}) {
            return $response;
        }

        $status = BOM::RPC::v3::Contract::validate_is_open($ul);
        if ($status and exists $status->{error}) {
            return $response;
        }
    }

    my $style = $args->{style} || ($args->{granularity} ? 'candles' : 'ticks');

    # default to 60 if not defined or send as 0 for candles
    $args->{granularity} = $args->{granularity} || 60 if $style eq 'candles';

    $response = _validate_start_end({%$args, ul => $ul});    ## no critic (ProhibitCommaSeparatedStatements)
    if ($response and exists $response->{error}) {
        return $response;
    } else {
        $args = $response;
    }

    my ($publish, $result, $type);
    if ($style eq 'ticks') {
        my $ticks   = _ticks($args);
        my $history = {
            prices => [map { $ul->pipsized_value($_->{price}) } @$ticks],
            times  => [map { $_->{time} } @$ticks],
        };
        $result  = {history => $history};
        $type    = "history";
        $publish = 'tick';
    } elsif ($style eq 'candles') {
        my @candles = @{_candles($args)};
        $result = {
            candles => \@candles,
        };
        $type    = "candles";
        $publish = $args->{granularity};
    } else {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidStyle',
                message_to_client => BOM::Platform::Context::localize("Style [_1] invalid", $style)});
    }

    return {
        stash   => {"${symbol}_display_decimals" => $ul->display_decimals},
        type    => $type,
        data    => $result,
        publish => $publish,
        ($args->{granularity}) ? (granularity => $args->{granularity}) : ()};
}

sub _ticks {
    my $args = shift;

    my $ul    = $args->{ul};
    my $start = $args->{start};
    my $end   = $args->{end};
    my $count = $args->{count};

    my $ticks = $ul->feed_api->ticks_start_end_with_limit_for_charting({
        start_time => $start,
        end_time   => $end,
        limit      => $count,
    });

    return [map { {time => $_->epoch, price => $ul->pipsized_value($_->quote)} } reverse @$ticks];
}

sub _candles {
    my $args = shift;

    my $ul          = $args->{ul};
    my $start_time  = $args->{start};
    my $end_time    = $args->{end};
    my $granularity = $args->{granularity};
    my $count       = $args->{count};

    my @all_ohlc;
    # This ohlc_daily_list is the only one will get ohlc from feed.tick for a period
    if ($end_time - $start_time <= $granularity) {
        my $ohlc = $ul->feed_api->ohlc_daily_list({
                start_time => $start_time,
                end_time   => $end_time,
            })->[0];
        if ($ohlc) {
            $ohlc->{epoch} = $start_time;
            push @all_ohlc, $ohlc;
        }
    } elsif ($granularity >= 86400 and $ul->ohlc_daily_open) {
        # For the underlying nocturne, for daily ohlc, the date need to be date
        $start_time = Date::Utility->new($start_time)->truncate_to_day;
        $end_time   = Date::Utility->new($end_time)->truncate_to_day;
        push @all_ohlc,
            (
            reverse @{
                $ul->feed_api->ohlc_start_end({
                        start_time         => $start_time,
                        end_time           => $end_time,
                        aggregation_period => $granularity,
                    })});

    } else {
        my $first_stop = $start_time + ($granularity - $start_time % $granularity);
        my $last_stop = $first_stop + $granularity * int(($end_time - $first_stop) / $granularity);

        my $first_ohlc = $ul->feed_api->ohlc_daily_list({
                start_time => $start_time,
                end_time   => ($first_stop - 1)})->[0];
        if ($first_ohlc) {
            $first_ohlc->{epoch} = $start_time;
            push @all_ohlc, $first_ohlc;
        }
        if ($last_stop > $first_stop) {
            push @all_ohlc,
                (
                reverse @{
                    $ul->feed_api->ohlc_start_end({
                            start_time         => $first_stop,
                            end_time           => $last_stop - 1,
                            aggregation_period => $granularity,
                        })});
        }
        my $last_ohlc = $ul->feed_api->ohlc_daily_list({
                start_time => $last_stop,
                end_time   => $end_time
            })->[0];
        if ($last_ohlc) {
            $last_ohlc->{epoch} = $last_stop;
            push @all_ohlc, $last_ohlc;
        }
    }

    if (scalar(@all_ohlc) - $count > 0) {
        @all_ohlc = @all_ohlc[-$count .. -1];
    }

    return [
        map { {
                epoch => $_->epoch + 0,
                open  => $ul->pipsized_value($_->open),
                high  => $ul->pipsized_value($_->high),
                low   => $ul->pipsized_value($_->low),
                close => $ul->pipsized_value($_->close)}
            }
            grep {
            defined $_
            } @all_ohlc
    ];
}

sub _validate_start_end {
    my $args = shift;

    my $ul = $args->{ul} || return BOM::RPC::v3::Utility::create_error({
            code              => 'NoSymbolProvided',
            message_to_client => BOM::Platform::Context::localize("Please provide an underlying symbol.")});

    my $start            = $args->{start};
    my $end              = $args->{end} !~ /^[0-9]+$/ ? time() : $args->{end};
    my $count            = $args->{count};
    my $granularity      = $args->{granularity};
    my $trading_calendar = Quant::Framework->new->trading_calendar(BOM::Platform::Chronicle::get_chronicle_reader);
    my $exchange         = $ul->exchange;

    # special case to send explicit error when
    # both are timestamp & start > end time
    if ($start and $end and $start =~ /^[0-9]+$/ and $end =~ /^[0-9]+$/ and $start > $end) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidStartEnd',
                message_to_client => BOM::Platform::Context::localize("Start time [_1] must be before end time [_2]", $start, $end)});
    }

    # if no start but there is count and granularity, use count and granularity to calculate the start time to look back
    if (not $start and $count and $granularity) {
        my $expected_start = Date::Utility->new($end - ($count * $granularity));
        # handle for non trading day as well
        unless ($trading_calendar->trades_on($exchange, $expected_start)) {
            my $count = 0;
            do {
                $expected_start = $expected_start->minus_time_interval('1d');
                $count++;
            } while ($count < 5 and not $trading_calendar->trades_on($exchange, $expected_start));
        }
        $start = $expected_start->epoch;
    }
    # we must not return to the client any ticks/candles after this epoch
    my $licensed_epoch = $ul->last_licensed_display_epoch;
    # max allow 3 years
    unless ($start
        and $start =~ /^[0-9]+$/
        and $start > time() - 365 * 86400 * 3
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
        and $count < 5001)
    {
        $count = 5000;
    }
    if ($ul->feed_license ne 'realtime') {
        # if feed doesn't have realtime license, we should adjust end_time in such a way
        # as not to break license conditions
        if ($licensed_epoch < $end) {
            my $shift_back = $end - $licensed_epoch;
            if ($ul->feed_license ne 'delayed' or $ul->delay_amount > 0) {
                $end = $licensed_epoch;
            }
            if ($args->{adjust_start_time}) {
                $start -= $shift_back;
            }
        }
    }
    if ($args->{adjust_start_time}) {
        unless ($trading_calendar->is_open_at($exchange, Date::Utility->new($end))) {
            my $shift_back = $trading_calendar->seconds_since_close_at($exchange, Date::Utility->new($end));
            unless (defined $shift_back) {
                my $last_day = $trading_calendar->trade_date_before($exchange, Date::Utility->new($end));
                if ($last_day) {
                    my $closes = $trading_calendar->closing_on($exchange, $last_day)->epoch;
                    $shift_back = $end - $closes;
                }
            }
            if ($shift_back) {
                $start -= $shift_back;
                $end   -= $shift_back;
            }
        }
    }
    $args->{start} = $start;
    $args->{end}   = $end;
    $args->{count} = $count;

    if ($start > $end) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidStartEnd',
                message_to_client => BOM::Platform::Context::localize("Start time [_1] must be before end time [_2]", $start, $end)});
    }

    return $args;
}

1;
