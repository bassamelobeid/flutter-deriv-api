#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];

use f_brokerincludeall;
use BOM::Config;
use subs::subs_dividend_from_excel_file;
use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use HTML::Entities;

use Bloomberg::FileDownloader;
use Bloomberg::RequestFiles;
use Bloomberg::BloombergCalendar;
use BOM::Backoffice::EconomicEventTool;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Utility qw(master_live_server_error);
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::Sysinit ();
use BOM::Backoffice::CustomCommissionTool;
use BOM::Backoffice::PricePreview;
use BOM::Backoffice::EconomicEventPricePreview;
BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation('I.V. DATABASE');
my $broker = request()->broker_code;

my $disabled_write = not BOM::Backoffice::Auth0::has_quants_write_access();
my $disabled       = $disabled_write ? "disabled title='no write access'" : "";

Bar("Update volatilities");
my @all_markets = Finance::Asset::Market::Registry->instance->all_market_names;
print get_update_volatilities_form({'all_markets' => \@all_markets});

# Manually update interest rates
Bar("Update interest rate");
print get_update_interest_rates_form();

Bar("BLOOMBERG DATA LICENSE");
print '<p>BLOOMBERG DATA LICENSE (BBDL) is an FTP service where we can make requests to the Bloomberg system.
 <br>Note1: to view currently scheduled batch files, upload the JYSscheduled.req request file.
 Then wait a minute and download scheduled.out . </p>';

master_live_server_error()
    unless ((grep { $_ eq 'binary_role_master_server' } @{BOM::Config::node()->{node}->{roles}}));

my $bbdl                  = Bloomberg::FileDownloader->new();
my $directory_listing_url = request()->url_for('backoffice/f_bbdl_list_directory.cgi');
print '<LI><b>BBDL FTP directory listing<b> - click this button to list the contents of the BBDL servers.';
print qq~
<form method=post action=$directory_listing_url>
<input type=hidden name=broker value=~ . encode_entities($broker) . qq~>
 <input type=submit value='List Directory'> (click once; will be slow)
</form>~;

my $list_request_files_url = request()->url_for('backoffice/f_bbdl_scheduled_request_files.cgi');
print '<LI><p><b>BBDL scheduled request files listing<b> - click this link to generate the contents of the scheduled request files.</p>';
print qq~
<p>
<a href="$list_request_files_url">Generate files</a>
</p>
~;

my $request_files_upload_url = request()->url_for('backoffice/f_bbdl_upload_request_files.cgi');
print '<LI><b>Upload the request files<b> ';
print qq~<br><form method=post action=$request_files_upload_url>
    <select name=frequency>
            <option value='scheduled'>Scheduled (Normal)</option>
            <option value='oneshot'>Oneshot</option>
            <option value='adhoc'>Adhoc</option>
            <!-- The One-shot is a kind of scheduled request, which runs once. The request has a specific date and time supplied, and is never repeated.
            In ad hoc, request is serviced immediately, gathering the latest available data. -->
        </select>
        <select name=type>
            <option value=request>request file</option>
            <option value=cancel>cancel file</option>
        </select>
    <input type=submit $disabled value='Upload Request files'>
    <br><font color=gray>Note 1: Type of request options:
    <br> Scheduled: Select this option if you would like those master request files to be run with scheduled program flag such as daily, weekday and weekend and repeatly based on the flag.
    <br> Oneshot: Select this option if you just want to upload those master request files with program flag one shot and it will not repeat.
    <br> Adhoc: Select this option if you just want to upload those master request files with program flag adhoc and it will not repeat.
    <br> Note 1: The difference between oneshot and adhoc is the cost. For oneshot, it will be treated as scheduled, hence it will take into account the annual band fee while for adhoc, it is only charge on the month of request.    <br> Choose oneshot if you are certain that you are going to request the same ticker in coming future as it will avoid being double charge on the month of request.
    <br>Note 2: If you want to over-write existing scheduled requests, upload CANCEL requests first.</font>
    </form>~;

my $single_file_upload_dir = request()->url_for('backoffice/f_bbdl_upload.cgi');
print qq~<P><LI>
<form method=post action=$single_file_upload_dir>
<input type=hidden name=broker value=~ . encode_entities($broker) . qq~>
Upload a file to the Bloomberg Data License FTP folder:<br>
Filename: <input type=text size=20 name=filename value='scheduled.req' data-lpignore='true' />
<input type=submit $disabled value='Upload File'><br>
<textarea rows=10 cols=90 name=bbdl_file_content>START-OF-FILE
FIRMNAME=dl623471
REPLYFILENAME=scheduled.out
PROGRAMNAME=scheduled
END-OF-FILE
</textarea>
</form>~;

my $download_dir = request()->url_for('backoffice/f_bbdl_download.cgi');
print qq~
<LI>
<form method=post action=$download_dir>
<input type=hidden name=broker value=~ . encode_entities($broker) . qq~>
Download Filename: <input type=text size=20 name=filename value='scheduled.out' data-lpignore='true' />
<input type=submit value='Download File'>
</form>~;

# Dividend comparison tool
Bar("Compare Dividend Point");
print generate_dividend_comparison_form({
        broker     => $broker,
        upload_url => request()->url_for('backoffice/quant/market_data_mgmt/quant_market_tools_backoffice.cgi'),
    },
    $disabled_write
);

Bar("Upload Dividend Point");
print generate_dividend_point_upload_form({
        broker     => $broker,
        upload_url => request()->url_for('backoffice/quant/market_data_mgmt/quant_market_tools_backoffice.cgi'),
    },
    $disabled_write
);

# Upload Dividend
# Currently we can get a list of forecast dividend from Bloomberg but in excel format
Bar("Upload Dividend");
print generate_dividend_upload_form({
        broker     => $broker,
        upload_url => request()->url_for('backoffice/quant/market_data_mgmt/quant_market_tools_backoffice.cgi'),
    },
    $disabled_write
);

# Upload calendar
#
Bar("Upload Calendar");
my $form;

BOM::Backoffice::Request::template()->process(
    'backoffice/holiday_upload_form.html.tt',
    {
        broker     => $broker,
        upload_url => request()->url_for('backoffice/f_upload_holidays.cgi'),
        disabled   => $disabled_write,
    },
    \$form
) || die BOM::Backoffice::Request::template()->error();

print $form;

# Upload Correlations
# Currently we can get a table of correlation data from SuperDerivatives but in excel format
Bar("Upload Correlations");
print generate_correlations_upload_form({
        broker     => $broker,
        upload_url => request()->url_for('backoffice/quant/market_data_mgmt/quant_market_tools_backoffice.cgi'),
    },
    $disabled_write
);

Bar('Price Preview');
print BOM::Backoffice::PricePreview::generate_form(request()->url_for('backoffice/quant/market_data_mgmt/update_price_preview.cgi'));

Bar('Economic Event Price Preview');
print BOM::Backoffice::EconomicEventPricePreview::generate_economic_event_form(
    request()->url_for('backoffice/quant/market_data_mgmt/update_economic_event_price_preview.cgi'));

Bar("Update the news events database");
print BOM::Backoffice::EconomicEventTool::generate_economic_event_tool(
    request()->url_for('backoffice/quant/market_data_mgmt/update_economic_events.cgi'),
    $disabled_write);

Bar("Custom Commission Tool");
print BOM::Backoffice::CustomCommissionTool::generate_commission_form(
    request()->url_for('backoffice/quant/market_data_mgmt/update_custom_commission.cgi'),
    $disabled_write);

code_exit_BO();

