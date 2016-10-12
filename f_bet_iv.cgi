#!/etc/rmg/bin/perl
package main;

use strict 'vars';
use open qw[ :encoding(UTF-8) ];

use f_brokerincludeall;
use BOM::System::Config;
use subs::subs_dividend_from_excel_file;
use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;

use BOM::MarketData::Fetcher::CorporateAction;
use Bloomberg::FileDownloader;
use Bloomberg::RequestFiles;
use BOM::BloombergCalendar;
use BOM::TentativeEvents;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation('I.V. DATABASE');
my $broker = request()->broker_code;
my $staff  = BOM::Backoffice::Auth0::can_access(['Quants']);

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

unless ((grep { $_ eq 'binary_role_master_server' } @{BOM::System::Config::node()->{node}->{roles}})) {
    print
        "<font color=red><b>WARNING! You are not on the Master Live Server. Suggest you use these tools on the Master Live Server instead.</b></font><P>";
}

my $bbdl                  = Bloomberg::FileDownloader->new();
my $directory_listing_url = request()->url_for('backoffice/f_bbdl_list_directory.cgi');
print '<LI><b>BBDL FTP directory listing<b> - click this button to list the contents of the BBDL servers.';
print qq~
<form method=post action=$directory_listing_url>
<input type=hidden name=broker value=$broker>
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
            <option value='daily'>Daily (Normal)</option>
            <option value='oneshot'>Oneshot</option>
        </select>
        <select name=type>
            <option value=request>request file</option>
            <option value=cancel>cancel file</option>
        </select>
    <input type=submit value='Upload Request files'>
    <br><font color=gray>Note 1: If you select 'Convert all to oneshot' then the requests will be processed immediately, once only.
    <br>Note 2: if you want to over-write existing scheduled requests, upload CANCEL requests first.</font>
    </form>~;

my $single_file_upload_dir = request()->url_for('backoffice/f_bbdl_upload.cgi');
print qq~<P><LI>
<form method=post action=$single_file_upload_dir>
<input type=hidden name=broker value=$broker>
Upload a file to the Bloomberg Data License FTP folder:<br>
Filename: <input type=text size=20 name=filename value='scheduled.req'>
<input type=submit value='Upload File'><br>
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
<input type=hidden name=broker value=$broker>
Download Filename: <input type=text size=20 name=filename value='scheduled.out'>
<input type=submit value='Download File'>
</form>~;

# Upload Dividend
# Currently we can get a list of forecast dividend from Bloomberg but in excel format
Bar("Upload Dividend");
print generate_dividend_upload_form({
    broker     => $broker,
    upload_url => request()->url_for('backoffice/quant/market_data_mgmt/quant_market_tools_backoffice.cgi'),
});

# Upload calendar
#
Bar("Upload Calendar");
print BOM::BloombergCalendar::generate_holiday_upload_form({
    broker     => $broker,
    upload_url => request()->url_for('backoffice/f_upload_holidays.cgi'),
});

# Upload Correlations
# Currently we can get a table of correlation data from SuperDerivatives but in excel format
Bar("Upload Correlations");
print generate_correlations_upload_form({
    broker     => $broker,
    upload_url => request()->url_for('backoffice/quant/market_data_mgmt/quant_market_tools_backoffice.cgi'),
});

Bar("Update the news events database");

BOM::Platform::Context::template->process(
    'backoffice/economic_event_forms.html.tt',
    {
        ee_upload_url => request()->url_for('backoffice/quant/market_data_mgmt/quant_market_tools_backoffice.cgi'),
    },
) || die BOM::Platform::Context::template->error;

Bar("Update the tentative events");
print BOM::TentativeEvents::generate_tentative_events_form({
    upload_url => request()->url_for('backoffice/quant/market_data_mgmt/update_tentative_events.cgi'),
});

Bar("Corporate Actions");
my $corp_dm = BOM::MarketData::Fetcher::CorporateAction->new;
my $list    = $corp_dm->get_underlyings_with_corporate_action;

my ($disabled, $monitor);
foreach my $underlying_symbol (keys %$list) {
    my $actions = $list->{$underlying_symbol};
    foreach my $action_id (keys %$actions) {
        my $action = $actions->{$action_id};
        if ($action->{suspend_trading} xor $action->{enable}) {
            $disabled->{$underlying_symbol}->{action_id}       = $action_id;
            $disabled->{$underlying_symbol}->{description}     = $action->{description};
            $disabled->{$underlying_symbol}->{suspension_date} = $action->{disabled_date};
            $disabled->{$underlying_symbol}->{effective_date}  = $action->{effective_date};
            $disabled->{$underlying_symbol}->{comment}         = $action->{comment} if $action->{comment};
            $disabled->{$underlying_symbol}->{enable}          = $action->{enable} if $action->{enable};
        }

        if ($action->{monitor}) {
            $monitor->{$underlying_symbol}->{action_id}      = $action_id;
            $monitor->{$underlying_symbol}->{description}    = $action->{description};
            $monitor->{$underlying_symbol}->{effective_date} = $action->{effective_date};
            $monitor->{$underlying_symbol}->{comment}        = $action->{comment} if $action->{comment};
        }
    }
}
my $corp_table;
BOM::Platform::Context::template->process(
    'backoffice/corporate_action.html.tt',
    {
        disabled => $disabled,
        monitor  => $monitor
    },
    \$corp_table
) || die BOM::Platform::Context::template->error;
print $corp_table;

code_exit_BO();

