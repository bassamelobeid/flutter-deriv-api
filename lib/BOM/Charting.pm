package BOM::Charting;

use strict;
use warnings;

use Crypt::NamedKeys;
use Date::Utility;
use BOM::Platform::Runtime;
use BOM::Platform::Context qw(request);
use BOM::Market::Data::DatabaseAPI;
use BOM::Market::Underlying;
use Try::Tiny;

# for Light chart / chart director
# BO charting
sub getFeedsFromHistoryServer {
    my $args = shift;

    my %args_request = (
        'instrument'   => $args->{'stock'},
        'intervalSecs' => $args->{'interval'},
        'limit'        => $args->{'limit'},
        'beginTime'    => $args->{'beginTime'},
        'endTime'      => $args->{'endTime'},
        'chartID'      => 'LIGHTCHARTS',
        'giveAll'      => 1,                      # give all available data, ignoring licence restrictions
    );

    my $data = processHistoricalFeed({
        clientID    => '',
        chartID     => $args->{'chartID'},
        remote_addr => '',
        remote_port => '',
        input       => \%args_request,
    });

    # Check if server responded with error.
    if ($data =~ /Error/i) {
        $data = '';
    }
    my @datalines = @{$data};

    # No data to display.
    if (scalar @datalines < 3) {
        return;
    }

    my %FeedHash;
    foreach my $line (@datalines) {
        $line =~ s/[=]+$//g;

        $line = Crypt::NamedKeys->new(keyname => 'feeds')->decrypt_payload(value => $line);
        $line =~ s/ts=(\d+)//g;
        $line =~ s/t=(\d+)//g;
        my $dt = $1;

        my ($open, $close, $low, $high);
        my ($ask, $bid, $quote);

        if ($args->{'interval'} > 0) {
            $line =~ s/o=(\d*\.?\d*)//g;
            my $open = $1;

            $line =~ s/s=(\d*\.?\d*)//g;
            my $close = $1;

            $line =~ s/l=(\d*\.?\d*)//g;
            my $low = $1;

            $line =~ s/h=(\d*\.?\d*)//g;
            my $high = $1;

            $FeedHash{$dt}{'open'}  = $open;
            $FeedHash{$dt}{'high'}  = $high;
            $FeedHash{$dt}{'low'}   = $low;
            $FeedHash{$dt}{'close'} = $close;
        } else {
            $line =~ s/a=(\d+\.?\d*)//g;
            my $ask = $1;

            $line =~ s/b=(\d+\.?\d*)//g;
            my $bid = $1;

            $line =~ s/q=(\d+\.?\d*)//g;
            my $quote = $1;

            $FeedHash{$dt}{'ask'}   = $ask;
            $FeedHash{$dt}{'bid'}   = $bid;
            $FeedHash{$dt}{'quote'} = $quote;
        }

        # Check if we are allowed to display this quote (licensed)..
        if ($line =~ /,x$/) {
            $FeedHash{$dt}{'nolicense'} = 1;
        }
    }

    return \%FeedHash;
}

sub processHistoricalFeed {
    my $args = shift;
    my ($clientID, $chartID, $CLIENT_REMOTE_ADDR, $CLIENT_REMOTE_PORT, $input) =
        @{$args}{'client_id', 'chart_id', 'remote_addr', 'remote_port', 'input'};

    my ($underlying_symbol, $intervalSecs, $beginTime, $endTime, $giveDelayedDailyData, $limit) = getParametersForHistoricalFeedRequest($input);

    # No symbol requested
    if (not $underlying_symbol) {
        warn("Invalid request from $CLIENT_REMOTE_ADDR. No symbol specified.");
        my @error = ('Invalid request. No symbol specified.');
        return \@error;
    }

    my $underlying = BOM::Market::Underlying->new($underlying_symbol);
    my $now        = Date::Utility->new;

    # Check license for requested historical summary of symbol
    my $license_info;
    my @error;
    try {
        $license_info = check_for_license_delay({
            underlying           => $underlying,
            endTime              => $endTime,
            chartID              => $chartID,
            intervalSecs         => $intervalSecs,
            giveDelayedDailyData => $giveDelayedDailyData,
        });
    }
    catch {
        warn("Client $CLIENT_REMOTE_ADDR $_");
        push @error, $_;
        0;
    } or return \@error;

    my $delaymins = $license_info->{delaymins};
    my $licenseTime;
    $licenseTime = $license_info->{licenseTime}
        if defined $license_info->{licenseTime};
    $endTime = $license_info->{endTime} if defined $license_info->{new_endTime};

    # Get the Historical feed.
    my $return_data = getHistoricalFeedFromDB({
        'intervalSecs' => $intervalSecs,
        'symbol'       => $underlying_symbol,
        'beginTime'    => $beginTime,
        'endTime'      => $endTime,
        'limit'        => $limit,
        'chartID'      => $chartID,
        'clientID'     => $clientID,
        'licenseTime'  => $licenseTime,
    });

    return $return_data;
}

sub check_for_license_delay {
    my $args = shift;
    my ($underlying, $chartID, $endTime, $intervalSecs, $giveDelayedDailyData) =
        @{$args}{'underlying', 'chartID', 'endTime', 'intervalSecs', 'giveDelayedDailyData'};

    my $underlying_symbol = $underlying->symbol;
    my $now               = Date::Utility->new;

    # Check license for requested historical summary of symbol
    my $license = $underlying->feed_license;
    my $delaymins = ($license eq 'realtime') ? 0 : $underlying->delay_amount;

    my ($licenseTime, $new_endTime);
    if ($license eq 'realtime' or $giveDelayedDailyData) {
        $delaymins = 0;
    } elsif ($license eq 'delayed') {
        if ($endTime + ($delaymins * 60) >= $now->epoch) {
            if ($chartID eq 'BOMSERVER') {

# For BOMSERVER we get all ticks but add a note to which we are not allowed to redistribute (add ,x at the end)
                $licenseTime = $now->epoch - ($delaymins * 60);
            } else {
                $new_endTime = $now->epoch - ($delaymins * 60);
            }
        }
    } elsif ($license eq 'daily' or $license eq 'chartonly') {

        # Summary interval must be at least daily
        if ($intervalSecs < 86400) {

# When requested from BOMSERVER we give quotes but add that it should always be 'obfuscated'
            if ($chartID eq 'BOMSERVER') {
                $licenseTime = 1;    #Set to 1 rather than 0 as Perl will regard 0 as not set.
            } else {
                die "$underlying_symbol not authorized for this summary";
            }
        }
    } else {
        die "$underlying_symbol not authorized";
    }

    my $license_info = {delaymins => $delaymins};
    $license_info->{licenseTime} = $licenseTime if $licenseTime;
    $license_info->{endTime}     = $new_endTime if $new_endTime;
    return $license_info;
}

sub getDataFromDB {
    my $arg_ref            = shift;
    my $underlying         = $arg_ref->{underlying};
    my $start_epoch        = $arg_ref->{start_time};
    my $end_epoch          = $arg_ref->{end_time};
    my $limit              = $arg_ref->{limit};
    my $aggregation_period = $arg_ref->{aggregation_period};

    my $data;
    if ($aggregation_period <= 0) {

        # api method just to be used in charting
        $data = $underlying->feed_api->ticks_start_end_with_limit_for_charting({
            start_time => $start_epoch,
            end_time   => $end_epoch,
            limit      => $limit,
        });
    } else {
        # api method just to be used in charting
        $data = $underlying->feed_api->ohlc_start_end_with_limit_for_charting({
            aggregation_period => $aggregation_period,
            start_time         => $start_epoch,
            end_time           => $end_epoch,
            limit              => $limit,
        });
    }

    return $data;
}

sub getHistoricalFeedFromDB {
    my $arg_ref = shift;

    my $intervalSecs = $arg_ref->{'intervalSecs'};
    my $symbol       = $arg_ref->{'symbol'};
    my $beginTime    = $arg_ref->{'beginTime'};
    my $endTime      = $arg_ref->{'endTime'};
    my $limit        = $arg_ref->{'limit'};
    my $chartID      = $arg_ref->{'chartID'};
    my $clientID     = $arg_ref->{'clientID'};
    my $licenseTime  = $arg_ref->{'licenseTime'};

    my @return_data;
    my $underlying = BOM::Market::Underlying->new($symbol);

    # Data to be returned when requested.
    my $ticks_data = getDataFromDB({
        underlying         => $underlying,
        start_time         => $beginTime,
        end_time           => $endTime,
        limit              => $limit,
        aggregation_period => $intervalSecs,
    });

    my $counter = 1;
    my $data;
    foreach my $tick (@{$ticks_data}) {
        my $feed_args = {
            intervalSecs => $intervalSecs,
            licenseTime  => $licenseTime,
            count        => $counter++,
            underlying   => $underlying,
        };

        my $line = format_feed_line($tick, $feed_args);
        push @return_data, $line;
    }

    return \@return_data;
}

sub filter_tick {
    my ($tick, $underlying) = @_;
    my $market = $underlying->market->name;

    # Cut the cuurency or in case of indices/US/UK stock round to 2 decimal digits
    if ($market eq 'forex' or $market eq 'commodities') {
        $tick = $underlying->pipsized_value($tick);

        # make it pip_size length, eg: 80.00 instead of 80
        my $decimal_length = length(1 / $underlying->pip_size) - 1;
        $tick = sprintf('%.' . $decimal_length . 'f', $tick);
    } elsif ($market ne 'volidx' and $market ne 'config') {
        $tick = sprintf("%.2f", $tick);
    }
    return $tick;
}

sub format_feed_line {
    my ($tick, $args) = @_;
    my ($licenseTime, $intervalSecs, $count, $underlying) =
        @{$args}{'licenseTime', 'intervalSecs', 'count', 'underlying'};

    my ($line, $nolicense);
    if ($intervalSecs <= 0) {
        my $dt    = $tick->epoch;
        my $ask   = filter_tick($tick->ask, $underlying);
        my $bid   = filter_tick($tick->bid, $underlying);
        my $quote = filter_tick($tick->quote, $underlying);

        $line = "c=$count,t=$dt,a=$ask,b=$bid,q=$quote,p=";

        if ($licenseTime and $dt >= $licenseTime) {
            $nolicense = 1;
        }
    } else {
        my $period = $tick->epoch;
        my $open   = filter_tick($tick->open, $underlying);
        my $close  = filter_tick($tick->close, $underlying);
        my $high   = filter_tick($tick->high, $underlying);
        my $low    = filter_tick($tick->low, $underlying);

        $line = "c=$count,t=$period,o=$open,s=$close,h=$high,l=$low";

        if ($licenseTime and ($period + $intervalSecs) >= $licenseTime) {
            $nolicense = 1;
        }
    }

    # append x if no license
    if ($nolicense) {
        $line .= ',x';
    }

    $line = Crypt::NamedKeys->new(keyname => 'feeds')->encrypt_payload(data => $line);

    return $line;
}

# Returns an array of parameters for Historical Feed Request
sub getParametersForHistoricalFeedRequest {

    # Pass in reference to the %input hash of HTTP Parameters
    my $refInput = shift;

    my $ONE_DAY      = 86400;
    my $intervalSecs = $refInput->{'intervalSecs'};
    if ($intervalSecs !~ m/^\d+$/) {
        $intervalSecs = $ONE_DAY;
    } elsif ($intervalSecs > $ONE_DAY) {
        if ($intervalSecs < 7 * $ONE_DAY) {
            $intervalSecs = $ONE_DAY;
        } elsif ($intervalSecs < 30 * $ONE_DAY) {
            $intervalSecs = 7 * $ONE_DAY;
        } else {
            $intervalSecs = 30 * $ONE_DAY;
        }
    }

    my $limit = $refInput->{'limit'};
    if (not defined $limit or $limit !~ m/^\d+$/) {
        $limit = 1000;
    } elsif ($limit > 4000) {
        $limit = 4000;
    }

    # Start/End time of feed
    my $beginTime = $refInput->{'beginTime'};
    my $endTime   = $refInput->{'endTime'};

    my $now = time;
    if (not(defined $beginTime) or $beginTime !~ m/^\d+$/) {
        my $estimatedTimespan = $intervalSecs * $limit;

        #Possible weekend corrections
        $estimatedTimespan += (2 * $ONE_DAY);
        if ($intervalSecs > $ONE_DAY) {
            my $timespanDays     = $estimatedTimespan / $ONE_DAY;
            my $possibleWeekends = int($timespanDays / 7);
            $estimatedTimespan += 2 * $possibleWeekends * $ONE_DAY;
        }

        if ($estimatedTimespan > 10 * 366 * $ONE_DAY) {
            $estimatedTimespan = 10 * 366 * $ONE_DAY;
        }

        $beginTime = $now - $estimatedTimespan;
    }

    if (not(defined $endTime) or $endTime !~ m/^\d+$/) {
        $endTime = $now;
    }

    $beginTime = ($beginTime == 0) ? 1 : $beginTime;

#For sake of DB queries endTime - beginTime for sub daily aggregations can't be inifinite.
    if (($intervalSecs < 86400 and $intervalSecs >= 3600)
        and $endTime - $beginTime > 86400 * 30 * 3)
    {
        $beginTime = $endTime - 86400 * 30 * 3;
    }
    if (($intervalSecs < 3600) and $endTime - $beginTime > 86400 * 30) {
        $beginTime = $endTime - 86400 * 30;
    }

    return ($refInput->{instrument}, $intervalSecs, $beginTime, $endTime, $refInput->{'giveAll'}, $limit);
}

sub translated_text {
    my %localized_strings = (
        chart_month                          => localize('Month'),
        chartmenu_charttype_forest           => localize('Forest Chart'),
        chartmenu_indicator_wr               => localize('Williams %R'),
        chart_delay                          => localize('(delayed)'),
        chartmenu_indicator_bbl              => localize('Bollinger Bands Lower'),
        chartmenu_indicator_ss               => localize('Stochastic Slow'),
        chartmenu_indicator_sma              => localize('Simple Moving Average'),
        chartmenu_indicator_ssd              => localize('Stochastic Slow %D'),
        title_futures                        => localize('Futures'),
        tabbedpane_10min                     => '10m',
        title_random                         => localize('Volatility Indices'),
        dialog_no                            => localize('No'),
        chartmenu_indicator_ad               => localize('Accumulation/Distribution'),
        tabbedpane_monthly                   => localize('Monthly'),
        tabbedpane_5min                      => '5m',
        chartmenu_indicator_wma              => localize('Weighted Moving Average'),
        tabbedpane_tick                      => localize('Tick'),
        chart_loading_message                => localize('loading...'),
        chartmenu_indicator_sf               => localize('Stochastic Fast'),
        menu_windows_cascade                 => localize('Cascade'),
        chartmenu_target                     => localize('Target'),
        chartmenu_addlines_line              => localize('Line'),
        chart_crosshair_quote                => localize('Quote'),
        dialog_indicator_overlay             => localize('Overlay'),
        chart_loading_retry_message          => localize('Connection failure. Please try again later.'),
        tabbedpane_weekly                    => localize('Weekly'),
        dialog_open                          => localize('Open'),
        chartmenu_print                      => localize('Print'),
        menu_windows_tile                    => localize('Tile'),
        dialog_workspace_browse_msg          => localize('Pick workspace file'),
        chartmenu_charttype_candlestick      => localize('Candlestick Chart'),
        question_delete_all_chart_lines      => localize('Delete all lines?'),
        chartmenu_crosshair                  => localize('Crosshair'),
        chartmenu_charttype_line             => localize('Line Chart'),
        dialog_workspace_delete_msg          => localize('Are you sure you want to delete \'#1\'?'),
        chartmenu_indicator_macds            => localize('MACD Signal'),
        tabbedpane_30min                     => '30m',
        dialog_workspace_browse_error        => localize('Invalid workspace name. Only use characters (A-Z,a-z,0-9, -, _ and whitespace)'),
        menu_windows_close                   => localize('Close'),
        chart_day_bet                        => localize('Day Bet'),
        chart_hour                           => localize('hour'),
        chartmenu_addlines_fibfan            => localize('Fibonacci Fan'),
        chartmenu_indicator_mom              => localize('Momentum'),
        chartmenu_indicator_po               => localize('Price Oscillator'),
        tabbedpane_4hr                       => '4h',
        chartmenu_indicator_macd             => localize('MACD'),
        dialog_retracement_percentage        => localize('Retracement Percentages'),
        title_us_stocks                      => localize('US Stocks'),
        chart_crosshair_high                 => localize('High'),
        chartmenu_indicator_inputlimit_error => localize('Invalid period input! Please input the period between 0 and #1'),
        fullscreen_mode                      => localize('Switch to full screen mode'),
        chartmenu_indicator                  => localize('Indicator'),
        chart_week                           => localize('Week'),
        title_uk_stocks                      => localize('UK Stocks'),
        tabbedpane_daily                     => localize('Daily'),
        chart_tick                           => localize('Tick'),
        chart_crosshair_close                => localize('Last'),
        chartmenu_indicator_sfk              => localize('Stochastic Fast %K'),
        chart_crosshair_ask                  => localize('Ask'),
        chart_months                         => localize('Months'),
        chartmenu_indicator_cci              => localize('Commodity Channel Index'),
        dialog_save                          => localize('Save'),
        chartmenu_indicator_bba              => localize('Bollinger Bands Average'),
        menu_help_about_message              => 'Java Charting Application Version 2.0 Copyright Binary Ltd',
        chartmenu_logarithmic                => localize('Logarithmic Scale'),
        chartmenu_charttype                  => localize('Chart Type'),
        dialog_indicator_new                 => localize('New'),
        chart_days                           => localize('days'),
        chart_crosshair_bid                  => localize('Bid'),
        chartmenu_charttype_ohlc             => localize('Bar OHLC Chart'),
        chartmenu_charttype_mountain         => localize('Mountain Chart'),
        menu_help                            => localize('Help'),
        chartmenu_overlayinstruments         => localize('Overlay Instruments'),
        dialog_yes                           => localize('Yes'),
        chartmenu_indicator_rsi              => localize('Relative Strength Index'),
        dialog_workspace_save_successful     => localize('Workspace \'#1\' saved successfully.'),
        chartmenu_indicator_roc              => localize('Rate of Change'),
        workspace_message_error_connection   => localize('A problem occurred while connecting to the server. Please try again later.'),
        chartmenu_charttype_hlc              => localize('Bar HLC Chart'),
        dialog_browse                        => localize('Browse'),
        chartmenu_addlines_finret            => localize('Fibonacci Retracement'),
        chart_today_bet                      => localize('Today\'s Bet'),
        dialog_indicator_overlay_remove      => localize('Remove Overlay'),
        chartmenu_charttype_linedot          => localize('Line Dot Chart'),
        chartmenu_addlines_hl                => localize('High/Low'),
        chartmenu_deletealllines             => localize('Delete All Lines'),
        menu_stats                           => localize('Statistics'),
        chartmenu_indicator_ema              => localize('Exponential Moving Average'),
        dialog_workspace_save_failed         => localize('Unknown error while saving workspace \'#1\'.'),
        dialog_indicator                     => localize('Indicator'),
        chart_day                            => localize('Day'),
        menu_windows_close_all               => localize('Close All'),
        chartmenu_indicator_ps               => localize('Parabolic SAR'),
        dialog_delete_all                    => localize('Delete All'),
        menu_instruments                     => localize('Instruments'),
        dialog_indicator_overlay_add         => localize('Add Overlay'),
        chart_tipbox_tip                     => localize('Tip:'),
        chartmenu_indicator_dpo              => localize('Detrended Price Oscillator (DPO)'),
        chart_crosshair_low                  => localize('Low'),
        tabbedpane_1hr                       => '1h',
        chart_weeks                          => localize('Weeks'),
        dialog_cancel                        => localize('Cancel'),
        chartmenu_indicator_ssk              => localize('Stochastic Slow %K'),
        dialog_workspace_title               => localize('BOM Charts Workspace'),
        title_indices                        => localize('World Indices'),
        dialog_ok                            => localize('OK'),
        chart_crosshair_open                 => localize('Open'),
        menu_windows                         => localize('Windows'),
        chartmenu_indicator_bb               => localize('Bollinger Bands'),
        tabbedpane_8hr                       => '8h',
        normal_mode                          => localize('Switch to normal mode'),
        title_forex                          => localize('Forex'),
        chartmenu_indicator_atr              => localize('Avg True Range'),
        menu_workspace                       => localize('Workspace'),
        dialog_delete                        => localize('Delete'),
        menu_help_about                      => localize('About'),
        chart_mins                           => localize('minutes'),
        chartmenu_indicator_bbu              => localize('Bollinger Bands Upper'),
        chartmenu_indicator_uo               => localize('Ultimate Oscillator'),
        dialog_workspace_save_name           => localize('Workspace name:'),
        chart_loading_retry                  => localize('Retry'),
        question_increase_timescale          => localize('Do you want to increase the timescale?'),
        chart_min                            => localize('minute'),
        dialog_workspace_delete_all_msg      => localize('Are you sure you want to delete all workspaces?'),
        chartmenu_charttype_dot              => localize('Dot Chart'),
        question_decrease_timescale          => localize('Do you want to decrease the timescale?'),
        chartmenu_indicator_sfd              => localize('Stochastic Fast %D'),
        tabbedpane_1min                      => '1m',
        chart_tipbox_message =>
            localize('Right click to add studies, lines, overlays and more. You can save your work by choosing Workspace from the top menu'),
        chart_hours                  => localize('hours'),
        chart_loading_nodata_message => localize('No data available to draw the requested chart. Please try our daily chart for this instrument.'),
        workspace_message_need_to_login_to_use =>
            localize('You must be logged in to use the workspace feature.Account opening is free and takes only 30 seconds.'),
        menu_workspace_workspace => localize('Workspace'),
        chartmenu_addlines_close => localize('Close'),
        chartmenu_addlines       => localize('Add Lines'),
        dialog_indicator_period  => localize('Period'),
        title_clv                => localize('Close Location Value'),
        ema                      => localize(
            'Moving averages provide an objective measure of trend direction by smoothing out short-term price fluctuations.For an Exponential Moving Average, the applied weight factor decreases exponential for periods further away in the past. It gives much more importance to recent observations while still not discarding older observations entirely.Shorter length moving averages are more sensitive and signals trends much faster than longer length MAs, but also give more false signals. A longer length MA is more reliable but only picks up the big trend.'
        ),
        title_atr => localize('Avg True Range'),
        mdx       => localize(
            'The Mass Index attempts to predict reversals by comparing the trading range (High minus Low) for each period. Reversals are signalled by a bulge in the index line.'
        ),
        atr => localize(
            'An indicator that measures a security\'s volatility. High ATR values indicate high volatility and may be an indication of panic selling or panic buying. Low ATR readings indicate sideways movement by the stock.'
        ),
        sma => localize(
            'Moving averages provide an objective measure of trend direction by smoothing out short-term price fluctuations.A Simple Moving Average is the unweighted mean of the n (set by period) previous periods (1 period is the selected timescale, i.e. 1 minute, 1 day etc.).All previous periods have equal weight in determining the SMA.Shorter length moving averages are more sensitive and signals trends much faster than longer length MAs, but also give more false signals. A longer length MA is more reliable but only picks up the big trend.'
        ),
        title_cci      => localize('Commodity Channel Index'),
        title_aroon    => localize('Aroon Up/Down'),
        title_aroonosc => localize('AroonOsc'),
        title_fstoch   => localize('Fast Stochastic'),
        bbw            => localize('Indicator that displays the width of Bollinger Bands.'),
        coscillator    => localize(
            'Indicator that is calculated by subtracting a 10 period exponential moving average from a 3 period moving average of the Accumulation Distribution Line.'
        ),
        macd => localize(
            'The Moving Average Convergence/Divergence (MACD) indicator is a trend following indicator and is designed to identify trend changes.The MACD is an oscillator based on two exponential moving averages of a share price. Three lines are shown. The "MACD" line is calculated as the difference between the two moving averages (usually based on 12- and 26- day averages). The "signal" line is a 9-day smoothed average of the standard MACD line, and is sometimes referred to as the "slow" MACD line.'
        ),
        wma => localize(
            'Moving averages provide an objective measure of trend direction by smoothing out short-term price fluctuations.In a Weighted Moving Average, the previous periods have less weight for periods further away in the past. In an n-day WMA the latest day has weight n, the second latest n-1, etc, down to zero.Shorter length moving averages are more sensitive and signals trends much faster than longer length MAs, but also give more false signals. A longer length MA is more reliable but only picks up the big trend.'
        ),
        title_dpo         => localize('Detrended Price Osc'),
        title_performance => localize('Performance'),
        momentum          => localize(
            'An oscillator that measures the rate of price change (as opposed to the actual levels themselves). It is calculated by taking price differences for a fixed time interval. This positive or negative value is plotted around a zero line.'
        ),
        trix => localize(
            'A momentum indicator showing the percent rate-of-change of a triple exponentially smoothed moving average. Like other oscillators, TRIX oscillates around a zero line.'
        ),
        title_sstoch => localize('Slow Stochastic'),
        dpo          => localize(
            'The Detrended Price Oscillator compares closing price to a prior moving average, eliminating cycles longer than the moving average.'),
        title_momentum => localize('Momentum'),
        roc            => localize(
            'The Rate of Change indicator (ROC) is a way of showing how rapidly the price of a particular share (or other financial instrument) is moving. The theory is that if a price is rising (or falling) very quickly there will soon come a time when it is thought to be overbought (or oversold). When this occurs the price may still continue to rise (or fall), but not as rapidly as it was before.'
        ),
        title_trix => localize('TRIX'),
        title_dcw  => localize('Donchian Channel Width'),
        cci        => localize(
            'The CCI is a timing system that is best applied to commodity contracts, which have cyclical or seasonal tendencies. CCI does not determine the length of cycles - it is designed to detect when such cycles begin and end through the use of a statistical analysis which incorporates a moving average and a divisor reflecting both the possible and actual trading ranges.'
        ),
        cmf => localize(
            'Oscillator calculated from the daily readings of the Accumulation Distribution Line. The CMF is unlike a momentum oscillator in that it is not influenced by the daily price change. Instead, the indicator focuses on the location of the close relative to the range for the period (daily or weekly).'
        ),
        performance => localize(
            'The Performance indicator displays a security\'s price performance as a percentage. This is sometimes called a "normalized" chart. The Performance indicator displays the percentage that the security has increased since the first period displayed. For example, if the Performance indicator is 10, it means that the security\'s price has increased 10% since the first period displayed on the left side of the chart. Similarly, a value of -10% means that the security\'s price has fallen by 10% since the first period displayed.Performance charts are helpful for comparing the price movements of different securities.'
        ),
        accdist => localize(
            'Weighted volume indicator based on the one-day change in price divided by the current day\'s range. Generally, the ADI moves in the direction of price.'
        ),
        title_cvolatility => localize('Chaikin Volatility'),
        title_accdist     => localize('Accumulation/Distribution'),
        emv               => localize(
            'Highlights the relationship between volume and price changes and is particularly useful for assessing the strength of a trend.'),
        aroon => localize(
            'Indicator that signals an upward trend when it rises above zero and a downward trend when it falls below zero. The farther away the oscillator is from the zero line, the stronger the trend.'
        ),
        rsi => localize(
            'The Relative Strength Index (RSI) measures a share price relative to itself and its recent history. It is calculated as the average of the prices for days where the price rose divided by the average of the prices for days where the price fell. The RSI ranges between 0 and 100.A 70+ level could indicate that a share is overbought, meaning that the speculator should consider selling. Or conversely oversold at the 30 level. The principle is that when there\'s a high proportion of daily movement in one direction it suggests an extreme, and prices are likely to reverse.'
        ),
        stochrsi => localize(
            'An oscillator used to identify overbought and oversold readings in RSI (Relative Strength Index). Because RSI can go for extended periods without becoming overbought (above 70) or oversold (below 30), StochRSI provides an alternative means to identify these extremities.'
        ),
        williamr => localize(
            'A technical indicator which measures overbought/oversold levels in a very similar way to that of an Oscillator indicator, except that %R is plotted upside-down 0% to -100%. Readings in the range of 80 to 100% indicate that the security is oversold while readings in the 0 to 20% range suggest that it is overbought.'
        ),
        title_bbw => localize('Bollinger Band Width'),
        title_rsi => localize('Relative Strength Index'),
        title_uo  => localize('Ultimate Oscillator'),
        adx       => localize(
            'J. Welles Wilder has developed the Average Directional Index - ADX to define trend force, whether the trend will develop further or will gradually weaken. The indicator allows to analyse tendencies of the market and to make trading decisions in the market forex.'
        ),
        title_roc      => localize('Rate of Change'),
        title_stochrsi => localize('StochRSI'),
        dc             => localize('Donchian Channels plot the highest high and lowest low over the last period time intervals.'),
        title_emv      => localize('Ease of Movement'),
        dcw            => localize('Indicator that displays the width of Donchian Channels.'),
        tma            => localize(
            'Triangular moving averages place the majority of the weight on the middle portion of the price series. They are actually double-smoothed simple moving averages. The periods used in the simple moving averages varies depending on if you specify an odd or even number of time periods.'
        ),
        title_coscillator => localize('Chaikin Oscillator'),
        stoch             => localize(
            'The Stochastic Oscillator is a momentum indicator that shows the location of the current close relative to the high/low range over a set number of periods. The Stochastic Oscillator is made up of two lines that oscillate between a vertical scale of 0 to 100. The %K is the main line and it is drawn as a solid line. The second is the %D line and is a moving average of %K. The %D line is drawn as a dotted line. The Fast Stochastic is the average of the last three %K and a Slow Stochastic is a three day average of the Fast Stochastic.'
        ),
        title_mdx => localize('Mass Index'),
        aroonosc  => localize(
            'Technical Indicator derived from subtracting Aroon Down from Aroon Up. As Aroon Up and Aroon Down oscillate between 0 and 100, the Aroon Oscillator oscillates between -100 and 100 with zero as the centre crossover line.'
        ),
        title_cmf      => localize('Chaikin Money Flow'),
        title_williamr => localize('William\'s %R'),
        ppo            => localize(
            'An indicator based on the difference between two moving averages expressed as a percentage. The PPO is found by subtracting the longer moving average from the shorter moving average and then dividing the difference by the longer moving average.'
        ),
        title_adx   => localize('Avg Directional Index'),
        cvolatility => localize(
            'The Chaikin Volatility function determines the volatility of a financial data series using the percent change in a moving average of the high versus low price over a given time.'
        ),
        clv => localize(
            'The CLV is an indicator based on the location of close related to low and high for the period. It is used to spot the tendency in the price movements.'
        ),
        title_macd => localize('MACD'),
        title_ppo  => '% ' . localize('Price Oscillator'),
        envelop    => localize(
            'A Simple moving average line can be enhanced by putting a percentage envelope on either side of it. Our lines are displayed 20% above and 10% below the moving average line.'
        ),
        uo => localize(
            'An oscillator that attempts to combine information for several different time periods into one number. Three different time periods are used, typically a 7-day period, a 14-day period, and a 28-day period. The resulting oscillator is "bounded" in that it moves between 0 and 100 with 50 as the centre line. 70 and 30 are used as overbought/oversold levels.'
        ),
        bb => localize(
            'Bollinger Bands are lines displayed around a simple moving average line (default set to 20 periods). The upper line is displayed 2 standard deviations above the moving average, and the lower line is displayed 2 standard deviations below the moving average.By definition prices are high at the upper band and low at the lower band. This definition can aid in rigorous pattern recognition and is useful in comparing price action to the action of indicators to arrive at systematic trading decisions.'
        ),
    );

    # This is for ease of maintenance, not because it's pretty.
    my $languageString;
    foreach my $key (keys %localized_strings) {
        my $property = $localized_strings{$key};
        $languageString .= "$key=$property;";
    }
    return $languageString;
}

sub _quote_interval_change {
    my ($open, $close, $underlying, $license) = @_;

    my $change = $close - $open;

    my $change_class;
    if ($change == 0) {
        $change_class = 'unchanged';
    } elsif ($change < 0) {
        $change_class = 'lower';
    } else {
        $change_class = 'higher';
    }

    my $percentage_change;
    if ($open) {
        $percentage_change = sprintf('%.2f', abs($change) / $open * 100);
    }

    $change = $underlying->pipsized_value(abs($change));

    # When we have license, show change more accurate, otherwise just give percentage.
    if ($license) {
        return
              '<td id="change" class="num '
            . $change_class . '">'
            . $change . ' ('
            . $percentage_change . '%)'
            . '&nbsp;<span class="market_'
            . $change_class
            . '"></span></td>';
    } else {
        return
              '<td id="change" class="num '
            . $change_class . '">'
            . $percentage_change . '%'
            . '&nbsp;<span class="market_'
            . $change_class
            . '"></span></td>';
    }
}

sub _get_price_changes_html {
    my $args       = shift;
    my $prices     = $args->{prices};
    my $underlying = $args->{underlying};

    my $licence_type = $underlying->feed_license;

    my $changes_html;
    my $license = 1;
    my $delay_seconds = ($licence_type eq 'delayed') ? 60 * $underlying->delay_amount : 0;
    my $previous_price;
    foreach my $datum (@{$prices}) {
        my $epoch = $datum->{epoch};
        # if the end of the interval is within the delay amount
        # (the 'time_interval' represents the end of the period)
        # then we cannot show the data
        $license = 0
            if ($license
            and $delay_seconds
            and (time - $epoch <= $delay_seconds));

        my $price = $datum->{quote};

        if ($previous_price) {
            $changes_html->{$epoch} = _quote_interval_change($previous_price, $price, $underlying, $license);
        }
        $previous_price = $price;
    }

    return $changes_html;
}

1;
