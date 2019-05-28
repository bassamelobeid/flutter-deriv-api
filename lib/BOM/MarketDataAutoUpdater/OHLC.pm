package BOM::MarketDataAutoUpdater::OHLC;

use Moose;
extends 'BOM::MarketDataAutoUpdater';

use Text::CSV::Slurp;
use Path::Tiny;

use BOM::Config::Chronicle;
use Date::Utility;
use Finance::Asset::Market::Registry;
use BOM::MarketData qw(create_underlying);
use BOM::MarketData qw(create_underlying_db);
use BOM::Config::Runtime;
use Bloomberg::FileDownloader;
use Bloomberg::RequestFiles;
use Quant::Framework;
use BOM::Config::Chronicle

    has directory_to_save => (
    is      => 'ro',
    default => sub {
        return BOM::Config::Runtime->instance->app_config->system->directory->feed . '/market';
    });

has file => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_file {
    my $self  = shift;
    my @files = Bloomberg::FileDownloader->new->grab_files({
        file_type => 'ohlc',
    });
    return \@files;
}

sub run {
    my $self = shift;

    my @files  = @{$self->file};
    my $report = $self->report;
    if ($#files == -1) {
        push @{$report->{error}}, 'OHLC AutoUpdater is terminating prematurely. File does not exist';
        return;
    }

    if ($#files > 1000) {
        push @{$report->{error}}, 'OHLC AutoUpdater is terminating prematurely. Number of files in Bloomberg seems too big: [' . $#files . ']';
        return;
    }

    my @symbols_to_update = create_underlying_db->get_symbols_for(
        market            => ['indices'],
        contract_category => 'ANY',
        exclude_disabled  => 1,
    );

    my @symbols_to_skip = qw/cryBTCUSD cryLTCUSD cryETHUSD/;

    my $trading_calendar = Quant::Framework->new->trading_calendar(BOM::Config::Chronicle::get_chronicle_reader());

    foreach my $file (@files) {
        my @bloomberg_result_lines = path($file)->lines_utf8;

        if (not scalar @bloomberg_result_lines) {
            push @{$report->{error}}, "File[$file] is empty";
            next;
        }

        my %bloomberg_to_binary = Bloomberg::UnderlyingConfig::bloomberg_to_binary;
        my $csv = Text::CSV::Slurp->load(file => $file);

        foreach my $data (@$csv) {
            my $ohlc_data;
            my $bb_symbol = $data->{SECURITIES};

            next unless $bb_symbol;

            my $bom_underlying_symbol = $bloomberg_to_binary{$bb_symbol};

            next if (grep { $_ eq $bom_underlying_symbol } (@symbols_to_skip));

            unless ($bom_underlying_symbol) {
                push @{$report->{error}}, "Unregconized bloomberg symbol[$bb_symbol]";
                next;
            }
            my $underlying = create_underlying($bom_underlying_symbol);
            my $now        = Date::Utility->new;

            next if (not $trading_calendar->trades_on($underlying->exchange, $now));

            if (my $validation_error = $self->_passes_sanity_check($data, $bom_underlying_symbol, @symbols_to_update)) {
                $report->{$bom_underlying_symbol} = {
                    success => 0,
                    reason  => $validation_error,
                };
            } else {
                my $symbol = $underlying->symbol;
                $ohlc_data->{item} = $symbol;
                my $date = $data->{LAST_UPDATE_DATE_EOD} ? $data->{LAST_UPDATE_DATE_EOD} : $data->{PX_YEST_DT};
                $date =~ s/^0//;
                my $open  = $data->{PX_OPEN}     ? $data->{PX_OPEN}     : $data->{PX_YEST_OPEN};
                my $high  = $data->{PX_HIGH}     ? $data->{PX_HIGH}     : $data->{PX_YEST_HIGH};
                my $low   = $data->{PX_LOW}      ? $data->{PX_LOW}      : $data->{PX_YEST_LOW};
                my $close = $data->{PX_LAST_EOD} ? $data->{PX_LAST_EOD} : $data->{PX_YEST_CLOSE};
                my $market_db_file_path = $self->directory_to_save . '/' . $symbol . '.db';
                my $line_to_append      = "$date $open $high $low $close\n";

                if (-e $market_db_file_path) {
                    my $last_line = `tail -1 $market_db_file_path`;
                    if ($last_line =~ /(\d\d?\-\w{3}\-\d{2})\s([\d\.]+)\s([\d\.]+)\s([\d\.]+)\s([\d\.]+)/) {
                        if ($1 ne $date) {
                            path($market_db_file_path)->append_utf8($line_to_append);
                            $report->{$bom_underlying_symbol}->{success} = 1;
                        }
                    }
                } else {
                    path($market_db_file_path)->append_utf8($line_to_append);
                    $report->{$bom_underlying_symbol}->{success} = 1;
                }
            }
        }
    }
    $self->SUPER::run();
    return 1;
}

sub _passes_sanity_check {
    my ($self, $data, $bom_underlying_symbol, @symbols_to_update) = @_;

    if ($data->{'ERROR CODE'} != 0 or grep { $_ eq 'N.A.' } values %$data) {
        return 'Invalid data received from bloomberg';
    }
    my $underlying = create_underlying($bom_underlying_symbol);
    my $spot_eod   = $underlying->spot;
    my $symbol     = $underlying->symbol;
    my $date       = $data->{LAST_UPDATE_DATE_EOD} ? $data->{LAST_UPDATE_DATE_EOD} : $data->{PX_YEST_DT};
    $date =~ s/^0//;
    my $now   = Date::Utility->new;
    my $today = $now->date_ddmmmyy;

    if ($date ne $today) {
        return 'OHLC for ' . $symbol . ' is not updated. Incorrect date [' . $date . ']';
    }
    my $skip_close_check = (grep { $_ eq $bom_underlying_symbol } @symbols_to_update) ? 0 : 1;

    # convert string to number
    $data->{$_} += 0 for qw(PX_OPEN PX_HIGH PX_LOW PX_LAST_EOD PX_YEST_OPEN PX_YEST_HIGH PX_YEST_LOW PX_YEST_CLOSE);

    my $open  = $data->{PX_OPEN}     ? $data->{PX_OPEN}     : $data->{PX_YEST_OPEN};
    my $high  = $data->{PX_HIGH}     ? $data->{PX_HIGH}     : $data->{PX_YEST_HIGH};
    my $low   = $data->{PX_LOW}      ? $data->{PX_LOW}      : $data->{PX_YEST_LOW};
    my $close = $data->{PX_LAST_EOD} ? $data->{PX_LAST_EOD} : $data->{PX_YEST_CLOSE};

    my $suspicious_move   = $underlying->market->suspicious_move;
    my $p_suspicious_move = $suspicious_move * 100;

    if (   $open < 0.001
        or $high < 0.001
        or $low < 0.001
        or $close < 0.001
        or $open > 999999
        or $high > 999999
        or $low > 999999
        or $close > 999999)
    {
        return "OHLC data error $symbol/$today: system retreived these from Bloomberg: open[$open] high[$high] low[$low] close[$close]";
    } elsif ($open == $high and $high == $low and $low == $close) {
        return "OHLC date error $symbol/$today: open, high, low and close has the number";
    } elsif ($open > $high) {
        return "OHLC data error $symbol/$today: open[$open] price bigger than high[$high] price";
    } elsif ($open < $low) {
        return "OHLC data error $symbol/$today: open[$open] price less than low[$low] price";
    } elsif ($close > $high) {
        return "OHLC data error $symbol/$today: close[$close] price bigger than high[$high] price";
    } elsif ($close < $low) {
        return "OHLC data error $symbol/$today: close[$close] price less than low[$low] price";
    } elsif ($high < $low) {
        return "OHLC data error $symbol/$today: high[$high] price less than low[$low] price";
    } elsif ($high > $open * (1 + $suspicious_move)) {
        return "OHLC suspicious data $symbol/$today: Suspicious : high ($high) > open ($open) + \%$p_suspicious_move";
    } elsif ($close > $open * (1 + $suspicious_move)) {
        return "OHLC suspicious data $symbol/$today: Suspicious : close ($close) > open ($open) + \%$p_suspicious_move";
    } elsif ($low < $open * (1 - $suspicious_move)) {
        return "OHLC suspicious data $symbol/$today: Suspicious : low ($low) < open ($open) - \%$p_suspicious_move";
    } elsif ($close < $open * (1 - $suspicious_move)) {
        return "OHLC suspicious data $symbol/$today: Suspicious : close ($close) < open ($open) - \%$p_suspicious_move";
    } elsif (not $skip_close_check and abs(($spot_eod - $close) / $spot_eod) > 0.05) {
        return "OHLC big difference between official [$close] and unofficial [$spot_eod] with percentage diff"
            . abs(($spot_eod - $close) / $spot_eod);
    }
    return;
}

sub verify_ohlc_update {
    my $self = shift;

    my $now = Date::Utility->new;

    return if $self->is_a_weekend;

    my @all_markets = map { $_->name } Finance::Asset::Market::Registry->instance->display_markets;

    my @underlying_symbols = create_underlying_db->get_symbols_for(
        market            => \@all_markets,
        contract_category => 'ANY',
    );

    foreach my $underlying_symbol (@underlying_symbols) {
        $underlying_symbol =~ s/^\^//;

        next if (not $underlying_symbol);

        my $db_file = $self->directory_to_save . '/' . $underlying_symbol . '.db';

        next if not $db_file;

        next if (-M $db_file and -M $db_file >= 20);    # do only those that were modified in last 20 days (others are junk/tests)

        my $underlying = create_underlying($underlying_symbol);

        # we are checking back past 10 day OHLC, so start to look back calendar from that day
        my $for_date = $now->minus_time_interval('10d');
        my $calendar = Quant::Framework->new->trading_calendar(BOM::Config::Chronicle::get_chronicle_reader($for_date), $for_date);
        next if $calendar->is_holiday_for($underlying->exchange, $now);
        next if ($underlying->submarket->is_OTC);
        if (my @filelines = path($db_file)->lines_utf8) {
            $self->_check_file($underlying, $calendar, @filelines);
        } else {
            die('Could not open file: ' . $db_file);
        }

    }

    return 1;
}

sub _check_file {
    my ($self, $underlying, $calendar, @filelines) = @_;

    my $suspicious_move   = $underlying->market->suspicious_move;
    my $p_suspicious_move = $suspicious_move * 100;
    my $now               = Date::Utility->new;
    my $underlying_symbol = $underlying->symbol;

    my ($prevwhen, $prevdate, $prevopen, $prevhigh, $prevlow, $prevclose, $date);

    foreach my $dbline (@filelines) {
        if ($dbline =~ /^(\d\d?\-\w\w\w\-\d\d)\s+(\d*\.?\d*)\s+(\d*\.?\d*)\s+(\d*\.?\d*)\s+(\d*\.?\d*)/) {
            $date = $1;
            my $open  = $2;
            my $high  = $3;
            my $low   = $4;
            my $close = $5;

            my $when = Date::Utility->new($date);
            next if (not $calendar->trades_on($underlying->exchange, $when));

            if ($now->days_between($when) <= 10)    #don't bug cron with old suspicions
            {
                if ($high > $open * (1 + $suspicious_move)) {
                    warn("--Warning: Suspicious : $underlying_symbol $date high ($high) > open ($open) + $p_suspicious_move\%");
                } elsif ($close > $open * (1 + $suspicious_move)) {
                    warn("--Warning: Suspicious : $underlying_symbol $date close ($close) > open ($open) + $p_suspicious_move\%");
                } elsif ($low < $open * (1 - $suspicious_move)) {
                    warn("--Warning: Suspicious : $underlying_symbol $date low ($low) < open ($open) - $p_suspicious_move\%");
                } elsif ($close < $open * (1 - $suspicious_move)) {
                    warn("--Warning: Suspicious : $underlying_symbol $date close ($close) < open ($open) - $p_suspicious_move\%");
                }

                if ($prevclose) {
                    if ($low > $prevclose * (1 + $suspicious_move)) {
                        warn("--Warning: Suspicious : $underlying_symbol $date low ($low) > previousclose ($prevclose) + $p_suspicious_move\%");
                    }
                    if ($high < $prevclose * (1 - $suspicious_move)) {
                        warn("--Warning: Suspicious : $underlying_symbol $date high ($high) < previousclose ($prevclose) - $p_suspicious_move\%");
                    }
                }

                if    ($high < $low)   { warn("--ERROR : $underlying_symbol $date high ($high) < low ($low) !!"); }
                elsif ($close < $low)  { warn("--ERROR : $underlying_symbol $date close ($close) < low ($low) !!"); }
                elsif ($close > $high) { warn("--ERROR : $underlying_symbol $date close ($close) > high ($high) !!"); }

                if ($prevwhen and $when->is_same_as($prevwhen)) {
                    warn("--ERROR : $underlying_symbol $date appears twice");
                } elsif ($prevdate) {
                    if (my $trading_days_between = $calendar->trading_days_between($underlying->exchange, $prevwhen, $when)) {
                        warn(
                            "--Warning: $underlying_symbol MISSING DATES between $prevdate and $date (trading days between is: $trading_days_between)."
                        );
                    } else {
                        my $days_between = $when->days_between($prevwhen);

                        # If days between is negative it would mean that the dates are not ordered properly
                        if ($days_between < 0) {
                            warn(
                                "--Warning: $underlying_symbol DATES are out of order date $prevdate is after $date (days between is: $days_between)."
                            );
                        }

                        # If days between is too big, there should also be a trading day in between
                        if ($days_between > 10) {
                            warn("--Warning: $underlying_symbol MISSING DATES between $prevdate and $date (days between is: $days_between).");
                        }
                    }
                }
            }
            ($prevwhen, $prevdate, $prevopen, $prevhigh, $prevlow, $prevclose) = ($when, $date, $open, $high, $low, $close);
        } else {
            warn("--$underlying_symbol ERRONEOUS LINE '$dbline'");
        }
    }

    #check yesterday is in it
    my $yesterday = Date::Utility->new($now->epoch - 86400);
    #Sunday or Monday, or Saturday (db won't update until Monday's first tick)
    if ($now->is_a_weekend or $now->day_of_week == 1 and $date ne $now->date_ddmmmyy and $date ne $yesterday->date_ddmmmyy) {
        # Make sure we traded yesterday
        if ($calendar->trades_on($underlying->exchange, $yesterday)) {
            warn("--$underlying_symbol ERROR can't find yesterday's data (" . $yesterday->date_ddmmmyy . ")");
        }
    }

    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
