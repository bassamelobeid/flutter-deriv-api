package BOM::MarketData;

use feature 'state';
use strict;
use warnings;

use BOM::System::Chronicle;
use File::Temp ();
use Try::Tiny;
use File::Copy;
use Text::CSV::Slurp;
use Date::Utility;
use YAML::CacheLoader qw(LoadFile);

sub save_calendar {
    my ($calendar, $calendar_type) = @_;

    # don't have to include synthetics for country holidays
    _include_synthetic($calendar) if $calendar_type ne 'country-holiday';
    my $updated = map { BOM::System::Chronicle::set($calendar_type, $_, $calendar->{$_}) } keys %$calendar;

    return $updated;
}

sub parse_calendar {
    my ($file, $calendar_type) = @_;

    my $csv = Text::CSV::Slurp->load(file => $file);
    my @holiday_data;
    if ($calendar_type eq 'exchange-holiday') {
        @holiday_data = grep {defined $_->{Trading} and $_->{Trading} =~ /No/} @$csv
    } elsif ($calendar_type eq 'country-holiday') {
        @holiday_data = grep { defined $_->{Settle} and $_->{Settle} =~ /No/} @$csv
    } elsif ($calendar_type eq 'trading-time') {
        @holiday_data = grep {defined $_->{Trading} and $_->{Trading} =~ /Partial/} @$csv;
    }

    my $data = _process(@holiday_data);

    return $data;
}

sub backup_file {
    my $file = shift;

    my $fh = File::Temp->new(SUFFIX => '.csv');
    my $filename = $fh->filename;
    copy($file, $filename);

    return;
}

sub _process {
    my @data = @_;

    state $calendar_code_mapper = LoadFile('/home/git/regentmarkets/bom-backoffice/config/bloomberg_calendar_code_mapper.yml');

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
1;
