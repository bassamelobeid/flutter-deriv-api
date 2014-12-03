#!/usr/bin/perl
package main;

use strict 'vars';

use f_brokerincludeall;
use BOM::Platform::Plack qw( PrintContentType );
use BOM::MarketData::HolidayCalendar;
system_initialize();
PrintContentType();

BOM::Platform::Auth0::can_access(['Quants']);

# Upload holiday files
my $cgi                                   = new CGI;
my $filetoupload                          = $cgi->param('filetoupload');
my $manually_update_individual_holiday    = $cgi->param('manually_update_individual_holiday');
my $upload_exchange_currencies_excel_file = $cgi->param('upload_exchange_currencies_excel_file');
my $update_pseudo_holiday                 = $cgi->param('update_pseudo_holiday');
my $symbol                                = $cgi->param('symbol');
my $holiday_date                          = $cgi->param('holiday_date');
my $holiday_event                         = $cgi->param('holiday_name');
my $source                                = $cgi->param('source');
my $type                                  = $cgi->param('type');
my $pseudo_start_date                     = $cgi->param('pseudo_start_date');
my $pseudo_end_date                       = $cgi->param('pseudo_end_date');
my $parser                                = BOM::MarketData::HolidayCalendar->new;

my ($surfaces, $filename) = $parser->process_holidays({
        'filetoupload'                          => $filetoupload,
        'manual_update_individual_holiday'      => $manually_update_individual_holiday,
        'upload_exchange_currencies_excel_file' => $upload_exchange_currencies_excel_file,
        'update_pseudo_holiday'                 => $update_pseudo_holiday,
        'symbol'                                => $symbol,
        'holiday_date'                          => $holiday_date,
        'holiday_event'                         => $holiday_event,
        'source'                                => $source,
        'pseudo_start_date'                     => $pseudo_start_date,
        'pseudo_end_date'                       => $pseudo_end_date,
        'type'                                  => $type,

});

code_exit_BO();
