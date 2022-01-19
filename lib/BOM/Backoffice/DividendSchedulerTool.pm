package BOM::Backoffice::DividendSchedulerTool;

use strict;
use warnings;
use Date::Utility;
use Text::Trim qw(trim);
use Syntax::Keyword::Try;
use BOM::Database::ClientDB;
use Scalar::Util qw(looks_like_number);
use BOM::MarketData qw(create_underlying);
use BOM::Config::QuantsConfig qw(get_mt5_symbols_mapping);

=head2 BOM::Backoffice::DividendSchedulerTool
    BOM::Backoffice::DividendSchedulerTool act as a model that corresponds to all the data-related logic.
=cut

=head2 _dbic_dividend_scheduler
    Initiate DB connection
=cut

sub _dbic_dividend_scheduler {
    return BOM::Database::ClientDB->new({
            broker_code => 'FOG',
            operation   => 'collector'
        })->db->dbic;
}

=head2 validate_params
    BOM::Backoffice::DividendSchedulerTool::validate_params($args)

    This is to validate the params before we save it.
=cut

sub validate_params {
    my $args = shift;

    return {error => "Platform type is required"}        if !$args->{platform_type};
    return {error => "Server name is required"}          if !$args->{server_name};
    return {error => "Symbol is required"}               if !$args->{symbol};
    return {error => "Currency is required"}             if !$args->{currency};
    return {error => "Long Dividend must be a number"}   if !looks_like_number($args->{long_dividend});
    return {error => "Short Dividend must be a number"}  if !looks_like_number($args->{short_dividend});
    return {error => "Long Tax must be a number"}        if !looks_like_number($args->{long_tax});
    return {error => "Short Tax must be a number"}       if !looks_like_number($args->{short_tax});
    return {error => "Long Dividend must be > 0, or 0"}  if $args->{long_dividend} < 0;
    return {error => "Short Dividend must be < 0, or 0"} if $args->{short_dividend} > 0;
    return {error => "Long Tax must be > 0, or 0"}       if $args->{long_tax} < 0;
    return {error => "Short Tax must be > 0, or 0"}      if $args->{short_tax} < 0;
    return {error => "Comment is required"}              if !$args->{dividend_deal_comment};
    return {error => "Applied Datetime is required"}     if !$args->{applied_datetime};

    my $applied_datetime    = Date::Utility->new($args->{applied_datetime} . ":00");
    my $trading_calendar    = Quant::Framework->new->trading_calendar(BOM::Config::Chronicle::get_chronicle_reader);
    my $mt5_symbols_mapping = BOM::Config::QuantsConfig->get_mt5_symbols_mapping;
    my $underlying          = create_underlying($mt5_symbols_mapping->{$args->{symbol}});

    # We need to add "skip holiday validation" feature to enable dividend scheduled on selected holiday
    my $valid_trading_time;
    if ($trading_calendar->closing_on($underlying->exchange, $applied_datetime) || $args->{skip_holiday_check}) {
        $valid_trading_time = 1;
    } else {
        $valid_trading_time = 0;
    }

    # We need to hardcode this as the trading time in mt5 is not the same at binary
    my $closing_hour = $applied_datetime->is_dst_in_zone($underlying->exchange->trading_timezone) ? 21 : 22;

    # Here we need to consider underlying symbol that does not have any Daylight Saving Time(DST)
    # e.g JPY_225
    if (!$underlying->{exchange}->{market_times}->{dst}) {
        $closing_hour = 21;
    }

    my $SQLquery                      = 'SELECT * FROM cfd.select_adjustment_dividend_schedule(?,?,?)';
    my $truncated_datetime            = $applied_datetime->truncate_to_day;
    my $get_divident_scheduler_perday = _dbic_dividend_scheduler->run(
        fixup => sub {
            $_->selectall_hashref($SQLquery, 'schedule_id', {}, undef, $truncated_datetime->datetime_yyyymmdd_hhmmss, '1 day');
        });

    # Validation for update function
    if ($args->{update}) {
        my $get_divident_scheduler = _dbic_dividend_scheduler->run(
            fixup => sub {
                $_->selectrow_hashref('SELECT * FROM cfd.adjustment_dividend_schedule WHERE schedule_id=?', undef, $args->{schedule_id});
            });

        return {error => "Cannot edit this scheduler as it has already been applied. Please close this page."}
            if $get_divident_scheduler->{schedule_status} ne "created";
    } else {
        # Symbol validation per day
        if ($get_divident_scheduler_perday) {
            foreach my $dividend_scheduler (keys %{$get_divident_scheduler_perday}) {
                if ($get_divident_scheduler_perday->{$dividend_scheduler}->{symbol} eq $args->{symbol}) {
                    return {error => "Duplicated symbol in on " . $applied_datetime->date_ddmmmyy};
                }

            }
        }
    }

    # Past applied datetime check
    if ($applied_datetime->epoch <= Date::Utility->new()->epoch) {
        return {error => "Date and Time cannot in the past."};
    }

    # Default symbol currency check
    if ($underlying->quoted_currency_symbol ne $args->{currency}) {
        return {error => 'Please choose "' . $underlying->quoted_currency_symbol . '" as the currency'};
    }

    # Validate when the market is closed(on the weekend or holiday)
    if ($valid_trading_time) {
        if ($applied_datetime->hour >= $closing_hour and $applied_datetime->hour < ($closing_hour + 1)) {
            my $formated_datetime = Date::Utility->new($applied_datetime)->datetime_yyyymmdd_hhmmss;
            $args->{applied_datetime} = $formated_datetime;

            return $args;
        } else {
            return {error => "Applied Date and time need to be between $closing_hour-" . ($closing_hour + 1) . " hour."};
        }
    } else {
        return {error => "Applied Date and time is not on trading days."};
    }
}

=head2 create
    BOM::Backoffice::DividendSchedulerTool::create($args)

    'create' will create a new dividend scheduler.
=cut

sub create {
    my $args = shift;

    my $platform_type         = $args->{platform_type};
    my $server_name           = $args->{server_name};
    my $symbol                = $args->{symbol};
    my $currency              = $args->{currency};
    my $long_dividend         = $args->{long_dividend};
    my $short_dividend        = $args->{short_dividend};
    my $long_tax              = $args->{long_tax};
    my $short_tax             = $args->{short_tax};
    my $dividend_deal_comment = $args->{dividend_deal_comment};
    my $applied_datetime      = $args->{applied_datetime};
    my $skip_holiday_check    = $args->{skip_holiday_check};

    my $SQLquery = 'SELECT FROM cfd.create_adjustment_dividend_schedule(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)';

    try {
        _dbic_dividend_scheduler->run(
            fixup => sub {
                $_->selectrow_hashref(
                    $SQLquery, undef,          $platform_type, $server_name,    $symbol,
                    $currency, $long_dividend, $long_tax,      $short_dividend, $short_tax,
                    $dividend_deal_comment, $applied_datetime, $skip_holiday_check
                );
            });

        return {success => 1};
    } catch ($e) {
        return {error => 'ERR: ' . $e};
    }
}

=head2 show_all
    BOM::Backoffice::DividendSchedulerTool::show_all(date), where date = YYYY-MM-DD

    'show_all' will return all the exiting dividend scheduler given the date.
=cut

sub show_all {
    my $sorted_datetime = shift;
    my $datetime;

    if ($sorted_datetime) {
        $datetime = Date::Utility->new($sorted_datetime);
    } else {
        $datetime = Date::Utility->new()->truncate_to_day;
    }

    my $SQLquery = 'SELECT * FROM cfd.select_adjustment_dividend_schedule(?,?,?)';

    my $index_divident_scheduler = _dbic_dividend_scheduler->run(
        fixup => sub {
            $_->selectall_hashref($SQLquery, 'schedule_id', {}, undef, $datetime->datetime_yyyymmdd_hhmmss, '1 day');
        });

    return $index_divident_scheduler;
}

=head2 show
    BOM::Backoffice::DividendSchedulerTool::show(scheduler_id)

    'show' will return dividend scheduler with the given `scheduler_id`.
=cut

sub show {
    my $dividend_scheduler_id = shift;

    my $show_divident_scheduler = _dbic_dividend_scheduler->run(
        fixup => sub {
            $_->selectrow_hashref('SELECT * FROM cfd.adjustment_dividend_schedule WHERE schedule_id=?', undef, $dividend_scheduler_id);
        });

    # Reformat date for display
    my $formated_datetime = Date::Utility->new($show_divident_scheduler->{applied_date_time});
    $formated_datetime = $formated_datetime->date . "T" . $formated_datetime->time_hhmm;
    $show_divident_scheduler->{applied_date_time} = $formated_datetime;

    return $show_divident_scheduler;
}

=head2 update
    BOM::Backoffice::DividendSchedulerTool::update(scheduler_id)

    'update' will update the dividend scheduler with the given `scheduler_id`.
=cut

sub update {
    my $args = shift;

    my $schedule_id           = $args->{schedule_id};
    my $platform_type         = $args->{platform_type};
    my $server_name           = $args->{server_name};
    my $symbol                = $args->{symbol};
    my $currency              = $args->{currency};
    my $long_dividend         = $args->{long_dividend};
    my $short_dividend        = $args->{short_dividend};
    my $long_tax              = $args->{long_tax};
    my $short_tax             = $args->{short_tax};
    my $dividend_deal_comment = $args->{dividend_deal_comment};
    my $applied_datetime      = $args->{applied_datetime};
    my $skip_holiday_check    = $args->{skip_holiday_check};

    my $SQLquery = 'SELECT FROM cfd.update_adjustment_dividend_schedule(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)';

    try {
        _dbic_dividend_scheduler->run(
            fixup => sub {
                $_->selectrow_hashref(
                    $SQLquery,  undef,     $schedule_id,   $platform_type, $server_name,
                    $symbol,    $currency, $long_dividend, $long_tax,      $short_dividend,
                    $short_tax, $dividend_deal_comment, $applied_datetime, $skip_holiday_check
                );
            });

        return {success => 1};
    } catch ($e) {
        return {error => 'ERR: ' . $e};
    }
}

=head2 destroy
    BOM::Backoffice::DividendSchedulerTool::destroy(scheduler_id)

    'destroy' will delete the dividend scheduler with the given `scheduler_id`.
=cut

sub destroy {
    my $dividend_scheduler_id = shift;

    my $SQLquery = 'SELECT FROM cfd.delete_adjustment_dividend_schedule(?)';

    try {
        _dbic_dividend_scheduler->run(
            fixup => sub {
                $_->selectrow_hashref($SQLquery, undef, $dividend_scheduler_id->{schedule_id});
            });

        return {success => 1};
    } catch ($e) {
        return {error => 'ERR: ' . $e};
    }
}

1;
