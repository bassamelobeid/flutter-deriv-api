#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use BOM::BloombergCalendar;
use File::Temp ();
use File::Copy;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();
PrintContentType();

BOM::Backoffice::Auth0::can_access(['Quants']);

# Upload holiday files
my $cgi           = CGI->new;
my $calendar_type = $cgi->param('calendar-type');
my $calendar;

if ($cgi->param('upload_excel')) {
    my $file     = $cgi->param('filetoupload');
    my $fh       = File::Temp->new(SUFFIX => '.csv');
    my $filename = $fh->filename;
    copy($file, $filename);
    $calendar = BOM::BloombergCalendar::parse_calendar($filename, $calendar_type);
} elsif ($cgi->param('manual_holiday_upload')) {
    my $calendar_type = $cgi->param('calendar-type');
    my $symbol_str    = $cgi->param('symbol');
    my @symbols       = split ' ', $symbol_str;
    my $holiday_date  = $cgi->param('holiday_date');
    my $holiday_desc  = $cgi->param('holiday_desc');
    # sanity check
    die "Incomplete entry\n" unless ($symbol_str and $holiday_date and $holiday_desc);
    $calendar->{Date::Utility->new($holiday_date)->truncate_to_day->epoch}{$holiday_desc} = \@symbols;
} elsif ($cgi->param('manual_partial_trading_upload')) {
    my $calendar_type = $cgi->param('calendar-type');
    my $symbol_str    = $cgi->param('symbol');
    my @symbols       = split ' ', $symbol_str;
    my $date          = $cgi->param('date');
    my $time          = $cgi->param('time');
    my $description   = $cgi->param('description');
    # sanity check
    die "Incomplete entry\n" unless ($symbol_str and $date and $time and $description);
    $calendar->{Date::Utility->new($date)->truncate_to_day->epoch}{$time} = \@symbols;
}

BOM::BloombergCalendar::save_calendar($calendar, $calendar_type);

code_exit_BO();
