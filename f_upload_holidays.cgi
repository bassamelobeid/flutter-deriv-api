#!/usr/bin/perl
package main;

use strict 'vars';

use BOM::BloombergCalendar;
#use f_brokerincludeall;
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();
PrintContentType();

BOM::Backoffice::Auth0::can_access(['Quants']);

# Upload holiday files
my $cgi = new CGI;
my $calendar_type = $cgi->param('calendar-type');
my $calendar;

if ($cgi->param('upload_excel')) {
    my $file = $cgi->param('filetoupload');
    BOM::BloombergCalendar::backup_file($file);
    $calendar = BOM::BloombergCalendar::parse_holiday($file, $calendar_type);
} elsif ($cgi->param('manual_holiday_upload')) {
    my $calendar_type = $cgi->param('calendar-type');
    my $symbol_str = $cgi->param('symbol');
    my @symbols = split ' ' , $symbol_str;
    my $holiday_date = $cgi->param('holiday_date');
    my $holiday_desc = $cgi->param('holiday_desc');
    # sanity check
    die "Incomplete entry\n" unless ($symbol_str and $holiday_date and $holiday_desc);
    foreach my $symbol (@symbols) {
        $calendar->{$symbol}{Date::Utility->new($holiday_date)->date_ddmmmyyyy} = $holiday_desc;
    }
} elsif ($cgi->param('manual_early_close_upload')) {
    my $calendar_type = $cgi->param('calendar-type');
    my $symbol_str = $cgi->param('symbol');
    my @symbols = split ' ' , $symbol_str;
    my $early_close_date = $cgi->param('early_close_date');
    my $early_close_desc = $cgi->param('early_close_desc');
    # sanity check
    die "Incomplete entry\n" unless ($symbol_str and $early_close_date and $early_close_desc);
    foreach my $symbol (@symbols) {
        $calendar->{$symbol}{Date::Utility->new($early_close_date)->date_ddmmmyyyy} = $early_close_desc;
    }
}

BOM::BloombergCalendar::save_calendar($calendar, $calendar_type);

code_exit_BO();
