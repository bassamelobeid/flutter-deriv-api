#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use Bloomberg::BloombergCalendar;
use File::Temp ();
use File::Copy;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();
use BOM::Config::Chronicle;
use Date::Utility;
use Quant::Framework::Calendar;

PrintContentType();

# Upload holiday files
my $cgi           = CGI->new;
my $calendar_type = $cgi->param('calendar-type');
my $calendar_hash;
my $calendar_name;

if ($cgi->param('upload_excel')) {
    my $file     = $cgi->param('filetoupload');
    my $fh       = File::Temp->new(SUFFIX => '.csv');
    my $filename = $fh->filename;
    copy($file, $filename);
    $calendar_hash = Bloomberg::BloombergCalendar::parse_calendar($filename, $calendar_type);
    # since partial_trading is handled separately in the function below, calendar_name is set to holidays
    $calendar_name = 'holidays';
    _save_early_closes_calendar($calendar_hash->{early_closes_data}) if defined $calendar_hash->{early_closes_data};
} elsif ($cgi->param('manual_holiday_upload')) {
    $calendar_name = 'holidays';
    $calendar_type = 'manual_' . $calendar_type;
    my $symbol_str   = $cgi->param('symbol');
    my @symbols      = split ' ', $symbol_str;
    my $holiday_date = $cgi->param('holiday_date');
    my $holiday_desc = $cgi->param('holiday_desc');
    # sanity check
    die "Incomplete entry\n" unless ($symbol_str and $holiday_date and $holiday_desc);
    my $existing = {};
    $existing = BOM::Config::Chronicle::get_chronicle_reader()->get('holidays', 'manual_holidays') unless $cgi->param('delete');
    my $date_key = Date::Utility->new($holiday_date)->truncate_to_day->epoch;
    $existing->{$date_key}{$holiday_desc} = [uniq(@symbols, @{$existing->{$date_key}{$holiday_desc} // []})];
    $calendar_hash->{calendar} = $existing;

} elsif ($cgi->param('manual_partial_trading_upload')) {
    $calendar_name = 'partial_trading';
    $calendar_type = 'manual_' . $calendar_type;
    my $symbol_str  = $cgi->param('symbol');
    my @symbols     = split ' ', $symbol_str;
    my $date        = $cgi->param('date');
    my $time        = $cgi->param('time');
    my $description = $cgi->param('description');
    # sanity check
    die "Incomplete entry\n" unless ($symbol_str and $date and $time and $description);
    my $existing = {};
    $existing = BOM::Config::Chronicle::get_chronicle_reader()->get($calendar_name, $calendar_type) unless $cgi->param('delete');
    my $date_key = Date::Utility->new($date)->truncate_to_day->epoch;
    $existing->{$date_key}{$time} = [uniq(@symbols, @{$existing->{$date_key}{$time} // []})];
    $calendar_hash->{calendar} = $existing;
}

my $action = $cgi->param('delete') ? 'delete_entry' : 'save';
save_calendar($calendar_hash->{calendar}, $calendar_name, $calendar_type, $action);

sub save_calendar {
    my ($calendar, $calendar_name, $calendar_type, $action) = @_;

    my $updated = Quant::Framework::Calendar->new(
        recorded_date    => Date::Utility->new,
        calendar         => $calendar,
        calendar_name    => $calendar_name,
        type             => $calendar_type,
        chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
        chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
    )->$action;

    return $updated;
}

# format data for early_closes data from our source.
sub _save_early_closes_calendar {
    my $data = shift;
    my $calendar_data;
    my $calendar = Quant::Framework->new->trading_calendar(BOM::Config::Chronicle::get_chronicle_reader());
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

    Quant::Framework::Calendar->new(
        chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
        chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
        recorded_date    => Date::Utility->new,
        calendar_name    => 'partial_trading',
        type             => 'early_closes',
        calendar         => $calendar_data,
    )->save;
    return;
}

code_exit_BO();
