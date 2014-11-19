#!/usr/bin/perl
package main;

use strict 'vars';

use f_brokerincludeall;
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Market::PricingInputs::HolidayCalendar::BBHolidayCalendar;
system_initialize();
PrintContentType();

BOM::Platform::Auth0::can_access(['Quants']);

# Upload Moneyness volsurfaces
my $cgi                                   = new CGI;
my $filetoupload                          = $cgi->param('filetoupload');
my $manually_update_individual_holiday    = $cgi->param('manually_update_individual_holiday');
my $upload_exchange_currencies_excel_file = $cgi->param('upload_exchange_currencies_excel_file');
my $symbol                                = $cgi->param('symbol');
my $holiday_date                          = $cgi->param('holiday_date');
my $holiday_event                         = $cgi->param('holiday_name');
my $source                                = $cgi->param('source');
my $type                                  = $cgi->param('type');

my $parser = BOM::Market::PricingInputs::HolidayCalendar::BBHolidayCalendar->new;

my ($surfaces, $filename) = $parser->process_holidays({
        'filetoupload'                          => $filetoupload,
        'manual_update_individual_holiday'      => $manually_update_individual_holiday,
        'upload_exchange_currencies_excel_file' => $upload_exchange_currencies_excel_file,
        'symbol'                                => $symbol,
        'holiday_date'                          => $holiday_date,
        'holiday_event'                         => $holiday_event,
        'source'                                => $source,
        'type'                                  => $type,

});

code_exit_BO();
