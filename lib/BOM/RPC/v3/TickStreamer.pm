package BOM::RPC::v3::TickStreamer;

use strict;
use warnings;

use Finance::Asset;
use Date::Utility;

use BOM::RPC::v3::Utility;
use BOM::RPC::v3::Contract;
use BOM::Feed::Data::AnyEvent;
use BOM::Market::Underlying;
use BOM::Platform::Context qw (localize request);
use BOM::Product::Contract::Finder qw(available_contracts_for_symbol);
use BOM::Product::Offerings qw(get_offerings_with_filter);

sub ticks_history {
    my $params = shift;

    my $args   = $params->{args};
    my $symbol = $args->{ticks_history};

    my $response = BOM::RPC::v3::Contract::validate_symbol($symbol);
    if ($response and exists $response->{error}) {
        return $response;
    }

    if (exists $args->{subscribe} and $args->{subscribe} eq '1') {
        my $license = BOM::RPC::v3::Contract::validate_license($symbol);
        if ($license and exists $license->{error}) {
            return $license;
        }
    }

    my $ul = BOM::Market::Underlying->new($symbol);

    my $style = $args->{style} || ($args->{granularity} ? 'candles' : 'ticks');

    $response = _validate_start_end({%$args, ul => $ul});    ## no critic
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
        if (@candles) {
            $result = {
                candles => \@candles,
            };
            $type    = "candles";
            $publish = $args->{granularity};
        } else {
            return BOM::RPC::v3::Utility::create_error({
                    code              => 'InvalidCandlesRequest',
                    message_to_client => BOM::Platform::Context::localize('Invalid candles request')});
        }
    } else {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'InvalidStyle',
                message_to_client => BOM::Platform::Context::localize("Style [_1] invalid", $style)});
    }

    return {
        type    => $type,
        data    => $result,
        publish => $publish
    };
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

    return [map { {time => $_->epoch, price => $_->quote} } reverse @$ticks];
}

sub _candles {
    my $args = shift;

    my $ul          = $args->{ul};
    my $start_time  = $args->{start};
    my $end_time    = $args->{end};
    my $granularity = $args->{granularity} // 60;
    my $count       = $args->{count};

    my @all_ohlc;
    # This ohlc_daily_list is the only one will get ohlc from feed.tick for a period
    if ($end_time - $start_time <= $granularity) {
        my $ohlc = $ul->feed_api->ohlc_daily_list({
                start_time => $start_time,
                end_time   => $end_time,
            })->[0];
        $ohlc->{epoch} = $start_time;
        push @all_ohlc, $ohlc;
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

    return [map { {epoch => $_->epoch + 0, open => $_->open, high => $_->high, low => $_->low, close => $_->close} } grep { defined $_ } @all_ohlc];
}

sub _validate_start_end {
    my $args = shift;

    my $ul = $args->{ul} || return BOM::RPC::v3::Utility::create_error({
            code              => 'NoSymbolProvided',
            message_to_client => BOM::Platform::Context::localize("Please provide an underlying symbol.")});

    unless ($ul->feed_license =~ /^(realtime|delayed|daily)$/) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'StreamingNotAllowed',
                message_to_client => BOM::Platform::Context::localize("Streaming for this symbol is not available due to license restrictions.")});
    }

    my $start = $args->{start};
    my $end   = $args->{end} !~ /^[0-9]+$/ ? time() : $args->{end};
    my $count = $args->{count};
    my $granularity = $args->{granularity};
    # if no start but there is count and granularity, use count and granularity to calculate the start time to look back
    $start = (not $start and $count and $granularity) ? $end - ($count * $granularity) : $start;
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
        and $count < 5000)
    {
        $count = 500;
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
        unless ($ul->exchange->is_open_at($end)) {
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
