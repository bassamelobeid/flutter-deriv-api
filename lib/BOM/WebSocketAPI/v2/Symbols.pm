package BOM::WebSocketAPI::v2::Symbols;

use strict;
use warnings;

use Mojo::Base 'BOM::WebSocketAPI::v2::BaseController';
use Finance::Asset;

use Date::Utility;
use BOM::Platform::Context;
use BOM::Feed::Data::AnyEvent;
use BOM::Market::Underlying;
use BOM::Product::Contract::Finder qw(available_contracts_for_symbol);
use BOM::Product::Offerings qw(get_offerings_with_filter);
use Cache::RedisDB;
use JSON;

sub _description {
    my $symbol = shift;
    my $by     = shift || 'brief';
    my $ul     = BOM::Market::Underlying->new($symbol) || return;
    my $iim    = $ul->intraday_interval ? $ul->intraday_interval->minutes : '';
    # sometimes the ul's exchange definition or spot-pricing is not availble yet.  Make that not fatal.
    my $exchange_is_open = eval { $ul->exchange } ? $ul->exchange->is_open_at(time) : '';
    my ($spot, $spot_time, $spot_age) = ('', '', '');
    if ($spot = eval { $ul->spot }) {
        $spot_time = $ul->spot_time;
        $spot_age  = $ul->spot_age;
    }
    if ($by eq 'full') {
        return {
            symbol                    => $symbol,
            display_name              => $ul->display_name,
            pip                       => $ul->pip_size,
            symbol_type               => $ul->instrument_type,
            exchange_name             => $ul->exchange_name,
            delay_amount              => $ul->delay_amount,
            exchange_is_open          => $exchange_is_open,
            quoted_currency_symbol    => $ul->quoted_currency_symbol,
            intraday_interval_minutes => $iim,
            is_trading_suspended      => $ul->is_trading_suspended,
            spot                      => $spot,
            spot_time                 => $spot_time,
            spot_age                  => $spot_age,
            market_display_name       => $ul->market->translated_display_name,
            market                    => $ul->market->name,
            submarket                 => $ul->submarket->name,
            submarket_display_name    => $ul->submarket->translated_display_name
        };
    } else {
        return {
            symbol                 => $symbol,
            display_name           => $ul->display_name,
            symbol_type            => $ul->instrument_type,
            market_display_name    => $ul->market->translated_display_name,
            market                 => $ul->market->name,
            submarket              => $ul->submarket->name,
            submarket_display_name => $ul->submarket->translated_display_name,
            exchange_is_open       => $exchange_is_open || 0,
            is_trading_suspended   => $ul->is_trading_suspended,
        };
    }
}

sub active_symbols {
    my ($c, $args) = @_;

    my $return_type = $args->{active_symbols};
    $return_type =~ /^(brief|full)$/
        or return {
        msg_type => 'active_symbols',
        error    => {
            message => "Value must be 'brief' or 'full'",
            code    => "InvalidValue"
        }};

    my $landing_company_name = 'costarica';
    if (my $client = $c->stash('client')) {
        $landing_company_name = $client->landing_company->short;
    }
    my $legal_allowed_markets = BOM::Platform::Runtime::LandingCompany::Registry->new->get($landing_company_name)->legal_allowed_markets;

    my $request = BOM::Platform::Context::request();
    my $lang    = $request->language;

    # we need put $lang as part of the key b/c market translated_display_name
    my $cache_key = join('::', $landing_company_name, $return_type, $lang);

    my $result;
    return JSON::from_json($result) if $result = Cache::RedisDB->get("WS_ACTIVESYMBOL", $cache_key);

    $result = {
        msg_type       => 'active_symbols',
        active_symbols => [
            map { $_ }
                grep {
                my $market = $_->{market};
                grep { $market eq $_ } @{$legal_allowed_markets}
                }
                map {
                _description($_, $return_type)
                } get_offerings_with_filter('underlying_symbol')
        ],
    };
    Cache::RedisDB->set("WS_ACTIVESYMBOL", $cache_key, JSON::to_json($result), 300 - (time % 300));
    return $result;
}

sub _validate_start_end {
    my ($c, $args) = @_;

    my $ul    = $args->{ul} || die 'no underlying';
    my $start = $args->{start};
    my $end   = $args->{end};
    my $count = $args->{count};

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

sub ticks {
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

sub candles {
    my ($c, $args) = @_;
    my $interval_map = {
        M => 60,
        H => 3600,
        D => 86400,
        S => 1,
    };

    $args = _validate_start_end($c, $args);

    my $ul          = $args->{ul} || die 'no underlying';
    my $start_time  = $args->{start};
    my $end_time    = $args->{end};
    my $granularity = uc($args->{granularity} || 'M1');

    my ($unit, $size) = $granularity =~ /^([DHMS])(\d+)$/ or return;
    my $interval = $size * $interval_map->{$unit};
    my @all_ohlc;

    if ($end_time - $start_time <= $interval) {
        $interval = $end_time - $start_time;
        push @all_ohlc,
            @{
            $ul->feed_api->ohlc_start_end({
                    start_time         => $start_time,
                    end_time           => $end_time,
                    aggregation_period => $interval,
                })};

   }elsif ($unit eq 'D' and $ul->ohlc_daily_open) {
        # For the underlying nocturne, for daily ohlc, the date need to be date
        $start_time = Date::Utility->new($start_time)->truncate_to_day;
        $end_time   = Date::Utility->new($end_time)->truncate_to_day;
        push @all_ohlc,
            @{
            $ul->feed_api->ohlc_start_end({
                    start_time         => $start_time,
                    end_time           => $end_time,
                    aggregation_period => $interval,
                })};

    } else {
        my $first_stop = $start_time + ($interval - $start_time % $interval);
        my $last_stop = $first_stop + $interval * int(($end_time - $first_stop) / $interval);
        push @all_ohlc,
            @{
            $ul->feed_api->ohlc_daily_list({
                    start_time         => $start_time,
                    end_time           => $first_stop - 1,
                })};

        push @all_ohlc,
            @{
            $ul->feed_api->ohlc_start_end({
                    start_time         => $first_stop,
                    end_time           => $last_stop,
                    aggregation_period => $interval,
                })};

        push @all_ohlc,
            @{
            $ul->feed_api->ohlc_daily_list({
                    start_time         => $last_stop,
                    end_time           => $end_time,
                })};

    }

    return [map { {epoch => $_->epoch, open => $_->open, high => $_->high, low => $_->low, close => $_->close} } reverse @all_ohlc];

}
1;
