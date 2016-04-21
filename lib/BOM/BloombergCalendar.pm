package BOM::BloombergCalendar;

use strict;
use warnings;

use Quant::Framework::Holiday;
use Quant::Framework::PartialTrading;
use BOM::Platform::Context;
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
            recorded_date => $recorded_date,
            calendar      => $calendar,
            chronicle_reader => BOM::System::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::System::Chronicle::get_chronicle_writer(),
        )->save;
    } else {
        $updated = Quant::Framework::PartialTrading->new(
            chronicle_reader => BOM::System::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::System::Chronicle::get_chronicle_writer(),
            recorded_date => $recorded_date,
            type          => $calendar_type,
            calendar      => $calendar,
        )->save;
    }

    return $updated;
}

sub parse_calendar {
    my ($file, $calendar_type) = @_;

    my $csv = Text::CSV::Slurp->load(file => $file);
    my @holiday_data;
    if ($calendar_type eq 'exchange_holiday') {
        @holiday_data = grep { defined $_->{Trading} and $_->{Trading} =~ /No/ } @$csv;
    } elsif ($calendar_type eq 'country_holiday') {
        @holiday_data = grep { defined $_->{Settle} and $_->{Settle} =~ /No/ } @$csv;
    } elsif ($calendar_type eq 'early_closes') {
        @holiday_data = grep { defined $_->{Trading} and $_->{Trading} =~ /Partial/ } @$csv;
    }

    my $data = _process(@holiday_data);
    # don't have to include synthetics for country holidays
    if ($calendar_type ne 'country_holiday') {
        _include_synthetic($data);
        _include_forex_holidays($data);
    }
    # convert to proper calendar format
    my $calendar;
    foreach my $exchange_name (keys %$data) {
        foreach my $date (keys %{$data->{$exchange_name}}) {
            my $description;
            if ($calendar_type eq 'early_closes') {
                my $celandar = Quant::Framework::TradingCalendar->new($exchange_name, BOM::System::Chronicle::get_chronicle_reader());
                $description =
                      $calendar->is_in_dst_at($date)
                    ? $calendar->market_times->{partial_trading}{dst_close}
                    : $calendar->market_times->{partial_trading}{standard_close};
            } else {
                $description = $data->{$exchange_name}{$date};
            }
            push @{$calendar->{$date}{$description}}, $exchange_name;
        }
    }

    return $calendar;
}

sub _include_forex_holidays {
    my $data = shift;

    my $year      = Date::Utility->new->year;
    my $christmas = Date::Utility->new("$year-12-25")->epoch;
    my $new_year  = Date::Utility->new(($year + 1) . "-01-01")->epoch;
    $data->{FOREX} = {
        $christmas => 'Christmas Day',
        $new_year  => "New Year\'s Day",
    };

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

sub _include_synthetic {
    my $calendar = shift;

    my %mapper = (
        SYNSTOXX    => [qw(STOXX EUREX)],
        SYNEURONEXT => [qw(EURONEXT EEI_AM)],
        SYNLSE      => [qw(LSE ICE_LIFFE)],
        SYNBSE      => [qw(BSE BSE)],
        SYNNYSE_DJI => [qw(NYSE CME)],
        SYNFSE      => [qw(FSE EUREX)],
        SYNHKSE     => [qw(HKSE HKF)],
        SYNTSE      => [qw(TSE CME)],
        SYNSWX      => [qw(SWX EUREX_SWISS)],
        SYNNYSE_SPC => [qw(NYSE_SPC CME)],
    );
    # take care of synthetic holidays now
    foreach my $syn_exchange (keys %mapper) {
        my %syn_data = map { (exists $calendar->{$_}) ? %{$calendar->{$_}} : () } @{$mapper{$syn_exchange}};
        $calendar->{$syn_exchange} = \%syn_data;
    }

    return;
}
1;
