package BOM::MarketData;

use feature 'state';
use strict;
use warnings;

use BOM::System::Chronicle;
use Text::CSV::Slurp;
use Date::Utility;
use YAML::CacheLoader qw(LoadFile);

state $calendar_code_mapper = LoadFile('/home/git/regentmarkets/bom-backoffice/config/bloomberg_calendar_code_mapper.yml');

sub save_calendar {
    my ($data_ref, $type) = @_;

    my $calendar;
    foreach my $date (keys %$data_ref) {
        my $data = $data_ref->{$date};
        foreach my $ref (@$data) {
            foreach my $exchange (@{$calendar_code_mapper->{$ref->{calendar_code}}}) {
                $calendar->{$exchange}->{$date} = $ref->{desc};
            }
        }
    }
    # don't have to include synthetics for country holidays
    _include_synthetic($calendar) if $type ne 'country';
    my $updated = map { BOM::System::Chronicle::set($type, $_, $calendar->{$_}) } keys %$calendar;

    return $updated;
}

sub _include_synthetic {
    my $calendar = shift;

    my %mapper = (
        SYNSTOXX => [qw(STOXX EUREX)],
        SYNEURONEXT=> [qw(EURONEXT EEI_AM)],
        SYNLSE=> [qw(LSE ICE_LIFFE)],
        SYNBSE=> [qw(BSE BSE)],
        SYNNYSE_DJI=> [qw(NYSE CME)],
        SYNFSE=> [qw(FSE EUREX)],
        SYNHKSE=> [qw(HKSE HKF)],
        SYNTSE=> [qw(TSE CME)],
        SYNSWX=> [qw(SWX EUREX_SWISS)],
        SYNNYSE_SPC=> [qw(NYSE_SPC CME)],
    );
    # take care of synthetic holidays now
    foreach my $syn_exchange (keys %mapper) {
        my %syn_data = map {%{$calendar->{$_}}} @{$mapper{$syn_exchange}};
        $calendar->{$syn_exchange} = \%syn_data;
    }

    return;
}

sub parse_exchange_holiday {
    my $file = shift;

    my $csv = Text::CSV::Slurp->load(file => $file);
    my @holiday_data = grep {defined $_->{Trading} and $_->{Trading} =~ /No/} @$csv;
    my $data = _process(@holiday_data);

    return $data;
}

sub parse_country_holiday {
    my $file = shift;

    my $csv = Text::CSV::Slurp->load(file => $file);
    my @holiday_data = grep { defined $_->{Settle} and $_->{Settle} =~ /No/} @$csv;
    my $data = _process(@holiday_data);

    return $data;
}

sub parse_early_close_calendar {
    my $file = shift;

    my $csv = Text::CSV::Slurp->load(file => $file);
    my @early_close_data = grep {defined $_->{Trading} and $_->{Trading} =~ /Partial/} @$csv;
    my $data = _process(@early_close_data);

    return $data;
}

sub _process {
    my @data = @_;

    my $output;
    foreach my $data (@data) {
        my $date          = $data->{'Date'};
        next unless $date;
        my $calendar_code = $data->{'Code'};
        my $description       = $data->{'Holidays/Events'};

        if ($date =~ /(\d{1,2})\/(\d{1,2})\/(\d{2})$/) {
            my $year = $3;
            if ($year < 99) {
                $year = '20' . $year;
            }
            $date = Date::Utility->new($year . '-' . sprintf('%02d', $1) . '-' . sprintf('%02d', $2));
        } elsif ($date =~ /(\d{1,2})\/(\d{1,2})\/(\d{4})$/) {
            $date = Date::Utility->new($3 . '-' . sprintf('%02d', $1) . '-' . sprintf('%02d', $2));
        }

        push @{$output->{$date->truncate_to_day->date_ddmmmyyyy}}, {calendar_code => $calendar_code, desc => $description};
    }

    return $output;
}
