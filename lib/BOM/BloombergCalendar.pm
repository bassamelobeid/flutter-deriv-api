package BOM::BloombergCalendar;

use strict;
use warnings;

use Quant::Framework;
use Finance::Exchange;
use BOM::Platform::Chronicle;
use Quant::Framework::Holiday;
use Quant::Framework::PartialTrading;
use BOM::Backoffice::Request;
use Try::Tiny;
use Text::CSV::Slurp;
use Date::Utility;
use YAML::XS qw(LoadFile);

my $calendar_code_mapper = LoadFile('/home/git/regentmarkets/bom-backoffice/config/bloomberg_calendar_code_mapper.yml');

sub save_calendar {
    my ($calendar, $calendar_type) = @_;

    my $recorded_date = Date::Utility->new;
    my $updated;
    if ($calendar_type eq 'exchange_holiday' or $calendar_type eq 'country_holiday') {
        $updated = Quant::Framework::Holiday->new(
            recorded_date    => $recorded_date,
            calendar         => $calendar,
            chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer(),
        )->save;
    } else {
        $updated = Quant::Framework::PartialTrading->new(
            chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer(),
            recorded_date    => $recorded_date,
            type             => $calendar_type,
            calendar         => $calendar,
        )->save;
    }

    return $updated;
}

sub parse_calendar {
    my ($file, $calendar_type) = @_;

    my $csv = Text::CSV::Slurp->load(file => $file);
    my @holiday_data;
    my @early_closes;
    if ($calendar_type eq 'exchange_holiday') {
        @holiday_data = grep { defined $_->{Trading} and $_->{Trading} =~ /No/ } @$csv;
        @early_closes = grep { defined $_->{Trading} and $_->{Trading} =~ /Partial/ } @$csv;

    } elsif ($calendar_type eq 'country_holiday') {
        @holiday_data = grep { defined $_->{Settle} and $_->{Settle} =~ /No/ } @$csv;
    }
    my $data              = _process(@holiday_data);
    my $early_closes_data = _process(@early_closes);
    # don't have to include synthetics for country holidays
    if ($calendar_type ne 'country_holiday') {
        $data->{FOREX} = {_generate_common_holidays()};
        _include_metal_holidays_and_early_closes({
            holidays     => $data,
            early_closes => $early_closes_data
        });
        _save_early_closes_calendar($early_closes_data);
    }
    # convert to proper calendar format
    my $calendar;

    foreach my $exchange_name (keys %$data) {
        foreach my $date (keys %{$data->{$exchange_name}}) {
            my $description = $data->{$exchange_name}{$date};
            push @{$calendar->{$date}{$description}}, $exchange_name;
        }
    }

    return $calendar;
}

sub _generate_common_holidays {

    my $year                = Date::Utility->new->year;
    my $christmas           = Date::Utility->new("$year-12-25");
    my $next_year_christmas = Date::Utility->new(($year + 1) . "-12-25");
    my $new_year            = Date::Utility->new(($year + 1) . "-01-01");
    my $next_year_new_year  = Date::Utility->new(($year + 2) . "-01-01");
    return (
        !$christmas->is_a_weekend           ? ($christmas->epoch           => 'Christmas Day')   : (),
        !$new_year->is_a_weekend            ? ($new_year->epoch            => 'New Year\'s Day') : (),
        !$next_year_christmas->is_a_weekend ? ($next_year_christmas->epoch => 'Christmas Day')   : (),
        !$next_year_new_year->is_a_weekend  ? ($next_year_new_year->epoch  => 'New Year\'s Day') : (),
    );

}

sub _include_metal_holidays_and_early_closes {
    my $param             = shift;
    my $data              = $param->{holidays};
    my $early_closes_data = $param->{early_closes};

    my $us_holidays = $data->{NYSE};

    # From the study we did, gold is illiquid after European market close on those US holiday, so we set early close on those day.
    # On Good Friday, since both US and European market are closed, the gold's feed tend to be very spare, so we decide to keep it as holiday. Other provider such as Panda and Idata also mark this day as holiday
    $data->{METAL} = {_generate_common_holidays(), map { $_ => 'Good Friday' } grep { $us_holidays->{$_} =~ /Good Friday/ } keys %{$us_holidays}};
    $early_closes_data->{METAL} = {map { $_ => $us_holidays->{$_} } grep { $us_holidays->{$_} !~ /Good Friday/ } keys %{$us_holidays}};
    return;
}

sub generate_holiday_upload_form {
    my $args = shift;

    my $form;

    BOM::Backoffice::Request::template->process(
        'backoffice/holiday_upload_form.html.tt',
        {
            broker     => $args->{broker},
            upload_url => $args->{upload_url},
        },
        \$form
    ) || die BOM::Backoffice::Request::template->error();

    return $form;
}

sub _process {
    my @data = @_;

    my $output;
    foreach my $data (@data) {
        my $date = $data->{'Date'};
        next unless $date;
        my $calendar_code = $data->{'Code'};
        my $description   = $data->{'Holidays/Events'};

        if ($date =~ /(\d{1,2})\/(\d{1,2})\/(\d{2})$/) {
            my $year = $3;
            if ($year < 99) {
                $year = '20' . $year;
            }
            $date = Date::Utility->new($year . '-' . sprintf('%02d', $1) . '-' . sprintf('%02d', $2));
        } elsif ($date =~ /(\d{1,2})\/(\d{1,2})\/(\d{4})$/) {
            $date = Date::Utility->new($3 . '-' . sprintf('%02d', $1) . '-' . sprintf('%02d', $2));
        }

        next if not $calendar_code_mapper->{$calendar_code};
        my @affected_symbols = @{$calendar_code_mapper->{$calendar_code}};
        foreach my $symbol (@affected_symbols) {
            $output->{$symbol}{$date->date_ddmmmyyyy} = $description;
        }
    }

    return $output;
}

sub _save_early_closes_calendar {
    my $data = shift;
    my $calendar_data;
    my $calendar = Quant::Framework->new->trading_calendar(BOM::Platform::Chronicle::get_chronicle_reader());
    foreach my $exchange_name (keys %$data) {
        my $exchange        = Finance::Exchange->create_exchange($exchange_name);
        my $partial_trading = $exchange->market_times->{partial_trading};
        if (not $partial_trading) {
            print "$exchange_name does not have partial trading configuration but it has early closes. Please check. \n";
            next;
        }

        foreach my $date (keys %{$data->{$exchange_name}}) {

            my $epoch = Date::Utility->new($date)->epoch;

            my $description =
                  $calendar->is_in_dst_at($exchange, $epoch)
                ? $partial_trading->{dst_close}->interval
                : $partial_trading->{standard_close}->interval;
            push @{$calendar_data->{$date}{$description}}, $exchange_name;
        }
    }

    Quant::Framework::PartialTrading->new(
        chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader(),
        chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer(),
        recorded_date    => Date::Utility->new,
        type             => 'early_closes',
        calendar         => $calendar_data,
    )->save;
    return;

}

1;
