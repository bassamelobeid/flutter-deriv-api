package BOM::MarketData::HolidayCalendar;

=head1 NAME

HolidayCalendar::BBHolidayCalendar;

=head1 DESCRIPTION

Get calendar from Bloomberg and automated the process to save to couch

=cut

use Moose;

use base 'Exporter';

our @EXPORT_OK = qw(generate_holiday_upload_form);

use Path::Tiny;
use File::Temp ();
use Try::Tiny;
use File::Copy;
use Format::Util::Numbers qw(roundnear);
use File::Slurp;
use Text::CSV::Slurp;
use Date::Utility;
use BOM::MarketData::CurrencyConfig;
use BOM::MarketData::ExchangeConfig;
use BOM::Market::Exchange;
use BOM::Platform::Context;
use BOM::Market::Registry;
use BOM::Market::UnderlyingDB;
use BOM::Market::Underlying;

sub process_holidays {

    my $self  = shift;
    my $input = shift;
    my $date  = Date::Utility->new;
    my $calendar;

    my $manually_update_individual_holiday    = $input->{'manual_update_individual_holiday'};
    my $upload_exchange_currencies_excel_file = $input->{'upload_exchange_currencies_excel_file'};
    my $update_pseudo_holiday                 = $input->{'update_pseudo_holiday'};
    my $file                                  = $input->{'filetoupload'};
    my $symbol                                = $input->{'symbol'};
    my $holiday_date                          = $input->{'holiday_date'};
    my $holiday_event                         = $input->{'holiday_event'};
    my $source                                = $input->{'source'};
    my $type                                  = $input->{'type'};
    my $pseudo_start_date                     = $input->{'pseudo_start_date'};
    my $pseudo_end_date                       = $input->{'pseudo_end_date'};

    if ($upload_exchange_currencies_excel_file) {

        my $fh = File::Temp->new(SUFFIX => '.csv');
        my $filename = $fh->filename;
        copy($file, $filename);

        try {
            $calendar = parse_holiday_calendar($filename);
            _save_excel_holidays_to_couch($calendar);
            _save_holidays_for_opi();
        }
        catch {
            print "Could not save economic calendar. Reason: $_";
        };

    } elsif ($manually_update_individual_holiday) {

        my $new_holiday;
        push @{$new_holiday},
            {
            date => Date::Utility->new($holiday_date),
            desc => $holiday_event
            };

        try {
            _save_holidays_to_couch({
                'symbol'      => $symbol,
                'source'      => $source,
                'type'        => $type,
                'new_holiday' => $new_holiday,
            });

        }
        catch {
            print "Could not save economic calendar. Reason: $_";
        };

    } elsif ($update_pseudo_holiday) {
        my $first_date = Date::Utility->new($pseudo_start_date);
        my $last_date  = Date::Utility->new($pseudo_end_date);
        my $days       = $last_date->days_between($first_date);
        my $new_holiday;
        for (my $day = 0; $day <= $days; $day++) {
            next
                if ($first_date->plus_time_interval($day . 'd')->day_of_week == 0
                or $first_date->plus_time_interval($day . 'd')->day_of_week == 6);

            push @{$new_holiday},
                {
                date => $first_date->plus_time_interval($day . 'd'),
                desc => 'pseudo-holiday'
                };
            try {
                my @exchanges = get_all_exchanges();
                foreach my $exchange (@exchanges) {
                    _save_holidays_to_couch({
                        'symbol'      => $exchange,
                        'source'      => 'EXCHANGE',
                        'type'        => 'HOLIDAY',
                        'new_holiday' => $new_holiday,
                    });
                }
            }
            catch {
                print "Could not save economic calendar. Reason: $_";
            };
        }
    }
    return;
}

sub _save_excel_holidays_to_couch {
    my $calendar_data = shift;
    my $config_db;

    if (uc($calendar_data->{'calendar_type'}) eq 'COUNTRY') {

        $config_db = "BOM::MarketData::CurrencyConfig";

    } elsif (uc($calendar_data->{'calendar_type'}) eq 'EXCHANGE') {

        $config_db = "BOM::MarketData::ExchangeConfig";
    }
    my %synthetic_symbols = map { $_ => 1 } BOM::Market::UnderlyingDB->get_symbols_for(
        market    => 'smarties',
        submarket => 'smart_index'
    );

    foreach my $symbol (keys %{$calendar_data}) {

        if ($symbol eq 'calendar_type') {
            next;
        }

        my @couch_symbol = $config_db->new->get_symbol_for('bloomberg_calendar_code' => $symbol);

        foreach my $couch_symbol (@couch_symbol) {

            my $existing_data = $config_db->new({symbol => $couch_symbol})->get_parameters;

            my $holiday_to_save = compare_existing_and_new_holidays_data({
                    'existing' => $existing_data->{holidays},
                    'new'      => $calendar_data->{$symbol}->{'holidays'}});

            if ($calendar_data->{'calendar_type'} eq 'Exchange') {

                my $early_close_to_save = compare_existing_and_new_early_close_data({

                        'existing' => $existing_data->{market_times},
                        'new'      => $calendar_data->{$symbol}->{'early_close'},
                        'exchange' => BOM::Market::Exchange->new($couch_symbol),
                        'action'   => 'excel',

                });

                $existing_data->{market_times}->{early_closes} = $early_close_to_save;

            }

            $existing_data->{holidays}      = $holiday_to_save;
            $existing_data->{recorded_date} = Date::Utility->new;

            if ($synthetic_symbols{'SYN' . $couch_symbol}) {
                $config_db->new({%$existing_data, symbol => 'SYN' . $couch_symbol})->save;
            }
            my $new_config = $config_db->new($existing_data);
            $new_config->save;

        }

    }

    return;
}

sub compare_existing_and_new_holidays_data {

    my $args = shift;

    my $existing_holiday = $args->{'existing'};

    my $new_data = $args->{'new'};
    my @existing_epoch =
        map { Date::Utility->new($_)->epoch } keys %$existing_holiday;
    foreach my $new (@$new_data) {
        if (!grep { $new->{date}->epoch == $_ } @existing_epoch) {
            $existing_holiday->{$new->{date}->date_ddmmmyyyy} = $new->{desc};
        }
    }

    %$existing_holiday = map { Date::Utility->new($_)->date_ddmmmyyyy => $existing_holiday->{$_} } keys %$existing_holiday;

    return $existing_holiday;

}

sub compare_existing_and_new_early_close_data {

    my $arg = shift;

    my $existing_data = $arg->{'existing'};

    my $existing_early_close = $existing_data->{early_closes};

    my $new_data = $arg->{'new'};

    my $exchange = $arg->{'exchange'};

    my $action = $arg->{'action'};

    if (keys %{$existing_early_close}) {

        my @existing_epoch =
            map { Date::Utility->new($_)->epoch } keys %{$existing_early_close};
        foreach my $new (@$new_data) {
            if (!grep { $new->{date}->epoch == $_ } @existing_epoch) {

                if ($action eq 'excel') {

                    if ($exchange->is_in_dst_at($new->{date}->epoch) and $existing_data->{partial_trading}->{dst_close}) {
                        $existing_early_close->{$new->{date}->date_ddmmmyyyy} = $existing_data->{partial_trading}->{dst_close};
                    } elsif ($existing_data->{partial_trading}->{standard_close}) {
                        $existing_early_close->{$new->{date}->date_ddmmmyyyy} = $existing_data->{partial_trading}->{standard_close};
                    }
                } elsif ($action eq 'manual') {
                    $existing_early_close->{$new->{date}->date_ddmmmyyyy} = $new->{desc};

                }
            }

        }
    } else {

        foreach my $new (@$new_data) {

            if ($action eq 'excel') {

                if ($exchange->is_in_dst_at($new->{date}->epoch) and $existing_data->{partial_trading}->{dst_close}) {
                    $existing_early_close->{$new->{date}->date_ddmmmyyyy} = $existing_data->{partial_trading}->{dst_close};
                } elsif ($existing_data->{partial_trading}->{standard_close}) {
                    $existing_early_close->{$new->{date}->date_ddmmmyyyy} = $existing_data->{partial_trading}->{standard_close};
                }
            } elsif ($action eq 'manual') {
                $existing_early_close->{$new->{date}->date_ddmmmyyyy} = $new->{desc};

            }
        }

    }

    %$existing_early_close = map { Date::Utility->new($_)->date_ddmmmyyyy => $existing_early_close->{$_} } keys %$existing_early_close;

    return $existing_early_close;

}

sub parse_holiday_calendar {
    my $file = shift;

    my @result;

    my $csv = Text::CSV::Slurp->load(file => $file);

    my $data;
    foreach my $csv_line (@$csv) {
        my $info;

        my ($trading_field, $trading);

        my $date          = $csv_line->{'Date'};
        my $calendar_code = $csv_line->{'Code'};

        my $holiday       = $csv_line->{'Holidays/Events'};
        my $calendar_type = $csv_line->{'Type'};

        if ($calendar_type eq 'Country') {
            $trading = $csv_line->{'Settle'};
        } elsif ($calendar_type eq 'Exchange') {
            $trading = $csv_line->{'Trading'};
        }

        $data->{'calendar_type'} = $calendar_type;
        if (not $date) {
            next;
        } else {

            if ($date =~ /(\d{1,2})\/(\d{1,2})\/(\d{2})$/) {
                my $year = $3;
                if ($year < 99) {
                    $year = '20' . $year;
                }
                $date = Date::Utility->new($year . '-' . sprintf('%02d', $1) . '-' . sprintf('%02d', $2));
            } elsif ($date =~ /(\d{1,2})\/(\d{1,2})\/(\d{4})$/) {
                $date = Date::Utility->new($3 . '-' . sprintf('%02d', $1) . '-' . sprintf('%02d', $2));
            }

        }

        if ($trading =~ /No/) {

            $info = {
                date => $date,
                desc => $holiday
            };

            push @{$data->{$calendar_code}->{holidays}}, $info;

        } elsif ($trading eq 'Partial') {

            $info = {
                date => $date,
                desc => $holiday
            };
            push @{$data->{$calendar_code}->{early_close}}, $info;
        }

    }

    return $data;
}

sub _save_holidays_to_couch {
    my $input = shift;

    my $config_db;

    if (uc($input->{'source'}) eq 'COUNTRY') {

        $config_db = "BOM::MarketData::CurrencyConfig";

    } elsif (uc($input->{'source'}) eq 'EXCHANGE') {

        $config_db = "BOM::MarketData::ExchangeConfig";
    }

    if (uc($input->{'type'}) eq 'EARLY_CLOSE') {
        $config_db = "BOM::MarketData::ExchangeConfig";
    }

    my $existing_data = $config_db->new({symbol => $input->{'symbol'}})->get_parameters;
    my $new_holiday = $input->{'new_holiday'};

    if (uc($input->{'type'}) eq 'HOLIDAY') {

        my $holiday_to_save = compare_existing_and_new_holidays_data({
            'existing' => $existing_data->{holidays},
            'new'      => $new_holiday,
        });

        $existing_data->{holidays} = $holiday_to_save;

    } elsif (uc($input->{'type'}) eq 'EARLY_CLOSE') {

        my $early_close_to_save = compare_existing_and_new_early_close_data({

                'existing' => $existing_data->{market_times},
                'new'      => $new_holiday,
                'exchange' => BOM::Market::Exchange->new($input->{'symbol'}),
                'action'   => 'manual',

        });
        $existing_data->{market_times}->{early_closes} = $early_close_to_save;

    }

    $existing_data->{recorded_date} = Date::Utility->new;
    my $new_config = $config_db->new($existing_data);

    $new_config->save;

    return;

}

sub generate_holiday_upload_form {
    my $args = shift;

    my $form;

    BOM::Platform::Context::template->process(
        'backoffice/holiday_upload_form.html.tt',
        {
            broker     => $args->{broker},
            upload_url => $args->{upload_url},
        },
        \$form
    ) || die BOM::Platform::Context::template->error();

    return $form;
}

sub _save_holidays_for_opi {
    my @underlying_symbols = BOM::Market::UnderlyingDB->instance->get_symbols_for(
        market       => 'smarties',
        contract_category => 'ANY',
    );
    my @exchanges;
    my $config_db = "BOM::MarketData::ExchangeConfig";

    foreach my $symbol (@underlying_symbols) {
        my $underlying = BOM::Market::Underlying->new($symbol);
        if ($underlying->submarket->name ne 'smart_opi') { next; }
        my $exchange = BOM::Market::Underlying->new($symbol)->exchange->symbol;
        if (!grep { $exchange =~ /$_$/ } @exchanges) {
            push @exchanges, $exchange;
        }
    }

    foreach my $exchange (@exchanges) {
        my ($first_exchange, $second_exchange) = split '-', $exchange;
        my $first_exchange_existing_data  = $config_db->new({symbol => $first_exchange})->get_parameters;
        my $second_exchange_existing_data = $config_db->new({symbol => $second_exchange})->get_parameters;
        my $opi_exchange_existing_data    = $config_db->new({symbol => $exchange})->get_parameters;

        my $first_exchange_holidays  = $first_exchange_existing_data->{holidays};
        my $second_exchange_holidays = $second_exchange_existing_data->{holidays};
        my $combined_exchange_holidays;

        foreach my $date (keys %$first_exchange_holidays) {
            push @{$combined_exchange_holidays->{holidays}},
                {
                date => Date::Utility->new($date),
                desc => $first_exchange_holidays->{$date}};
        }

        foreach my $second_exchange_holiday (keys %$second_exchange_holidays) {
            if (
                !grep { Date::Utility->new($second_exchange_holiday)->epoch == Date::Utility->new($_)->epoch }
                keys %$first_exchange_holidays
                )
            {
                push @{$combined_exchange_holidays->{holidays}},
                    {
                    date => Date::Utility->new($second_exchange_holiday),
                    desc => $second_exchange_holidays->{$second_exchange_holiday}};
            }
        }

        my $first_exchange_ec_data  = $first_exchange_existing_data->{market_times}->{early_closes};
        my $second_exchange_ec_data = $second_exchange_existing_data->{market_times}->{early_closes};

        foreach my $ec_date (keys %$first_exchange_ec_data) {
            push @{$combined_exchange_holidays->{early_closes}},
                {
                date => Date::Utility->new($ec_date),
                desc => $first_exchange_ec_data->{$ec_date}};
        }

        foreach my $second_exchange_ec_date (keys %$second_exchange_ec_data) {
            if (
                !grep { Date::Utility->new($second_exchange_ec_date)->epoch == Date::Utility->new($_)->epoch }
                keys %$first_exchange_ec_data
                )
            {
                push @{$combined_exchange_holidays->{early_closes}},
                    {
                    date => Date::Utility->new($second_exchange_ec_date),
                    desc => $second_exchange_ec_data->{$second_exchange_ec_date}};
            }
        }

        my $holiday_to_save = compare_existing_and_new_holidays_data({
            'existing' => $opi_exchange_existing_data->{holidays},
            'new'      => $combined_exchange_holidays->{holidays},
        });

        my $early_close_to_save = compare_existing_and_new_early_close_data({

                'existing' => $opi_exchange_existing_data->{market_times},
                'new'      => $combined_exchange_holidays->{early_closes},
                'exchange' => BOM::Market::Exchange->new($first_exchange),
                'action'   => 'excel',

        });

        $opi_exchange_existing_data->{holidays} = $holiday_to_save;
        $opi_exchange_existing_data->{market_times}->{early_closes} = $early_close_to_save;

        $opi_exchange_existing_data->{recorded_date} = Date::Utility->new;

        my $new_config = $config_db->new($opi_exchange_existing_data);
        $new_config->save;
    }
    return;
}

sub get_all_exchanges {
    my @all = ('forex', 'indices', 'commodities', 'smarties');
    my @underlying_symbols = BOM::Market::UnderlyingDB->instance->get_symbols_for(
        market       => \@all,
        contract_category => 'ANY',
    );
    my @exchanges;

    foreach my $symbol (@underlying_symbols) {
        my $exchange = BOM::Market::Underlying->new($symbol)->exchange->symbol;
        if (!grep { $exchange =~ /$_$/ } @exchanges) {
            push @exchanges, $exchange;
        }
    }
    return @exchanges;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
