package BOM::Charting;

use strict;
use warnings;

use Crypt::NamedKeys;
use Date::Utility;
use BOM::Platform::Runtime;
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
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

    my $underlying = create_underlying($underlying_symbol);
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
    my $underlying = create_underlying($symbol);

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

1;
