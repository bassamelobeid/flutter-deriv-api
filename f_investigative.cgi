#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;
no warnings 'uninitialized';    ## no critic (ProhibitNoWarnings) # TODO fix these warnings

use HTML::Entities;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use Data::Validate::Sanctions;
use Path::Tiny;
use f_brokerincludeall;
use BOM::Backoffice::Sysinit ();
use BOM::Config;
use LandingCompany::Registry;
use CGI;
use BOM::Backoffice::FileUpload;
use BOM::Backoffice::CustomSanctionScreening;

BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation('INVESTIGATIVE TOOLS');

my $sanctions   = Data::Validate::Sanctions->new(sanction_file => BOM::Config::sanction_file);
my @all_cryptos = LandingCompany::Registry::all_crypto_currencies();

my $self = request()->url_for('backoffice/f_investigative.cgi');
my $cgi  = CGI->new;

if (request()->param('whattodo') eq 'unsanctions') {
    my $error_message;
    if ($sanctions->is_sanctioned(request()->param('fname'), request()->param('lname'))) {
        $error_message = "<b>"
            . encode_entities(request()->param('fname')) . " "
            . encode_entities(request()->param('lname'))
            . " IS IN THE UN SANCTIONS LIST!!</b>";
    } else {
        $error_message =
            encode_entities(request()->param('fname')) . " " . encode_entities(request()->param('lname')) . " is not in the sanctions list.";
    }

    code_exit_BO($error_message, 'UN Sanctions Query');
}

Bar("ANTI FRAUD TOOLS");

print "<h3>User login history</h3>";
print "<FORM ACTION=\"" . request()->url_for('backoffice/f_viewloginhistory.cgi') . "\" METHOD=POST>";
print
    "<div class='row row-align-top'><label>Email, or list of emails (space separated):</label><textarea name='email' rows=2 cols=40></textarea></div>";
print "<div class='row row-align-top'><INPUT type=submit class='btn btn--primary' value='View user login history'></div>";
print "</FORM>";
print "<hr>";
print "<h3>Query UN Sanctions list</h3><FORM ACTION=\"" . request()->url_for('backoffice/f_investigative.cgi') . "\" METHOD=POST>";
print "<INPUT type=hidden name=whattodo value=unsanctions>";
print "<label>First name:</label><INPUT type=text size=15 maxlength=35 name=fname value='Usama' data-lpignore='true' /> ";
print "<label>Last name:</label><INPUT type=text size=15 maxlength=35 name=lname value='bin Laden' data-lpignore='true' /> ";
print "<input type=submit class='btn btn--primary' value='Query UN Sanctions database'>";
print "</form>";

Bar("Custom Sanction Screening");

BOM::Backoffice::Request::template()->process(
    'backoffice/sanction_screening.html.tt',
    {
        data_url => $self,
    }) || die BOM::Backoffice::Request::template()->error(), "\n";

if (BOM::Backoffice::FileUpload::is_post_request($cgi)) {
    my $input = request()->params;

    my $batch_file = BOM::Backoffice::FileUpload::get_batch_file($input->{screening_csv_file});
    # Check if file is CSV and size is within limits
    my $error_message = BOM::Backoffice::FileUpload::validate_file($batch_file);
    if ($error_message) {
        code_exit_BO($error_message);
    }
    my ($csv_data, $csv_error) = BOM::Backoffice::CustomSanctionScreening::read_custom_sanction_csv_file($cgi);
    if ($csv_error) {
        print "<p class=\"error\">Error: $csv_error</p>";
    } else {
        my $save_success = BOM::Backoffice::CustomSanctionScreening::save_custom_sanction_data_to_redis($csv_data);
        if ($save_success) {
            print "<p class=\"success\">File saved successfully.</p>";
        } else {
            print "<p class=\"error\">Error saving file!!</p>";
        }
    }
}

Bar("IP related");

BOM::Backoffice::Request::template()->process(
    'backoffice/ip_search.html.tt',
    {
        ip_search_url => request()->url_for('backoffice/ip_search.cgi'),
        ip            => $ENV{REMOTE_ADDR},
    }) || die BOM::Backoffice::Request::template()->error(), "\n";

Bar("Crypto Fraudulent Addresses");

BOM::Backoffice::Request::template()->process(
    'backoffice/crypto_fraudulent_addresses.html.tt',
    {
        data_url  => request()->url_for('backoffice/crypto_fraudulent_addresses.cgi'),
        page      => 1,
        max_pages => 1,
    }) || die BOM::Backoffice::Request::template()->error(), "\n";

Bar("Crypto Wrong Currency Deposit");

BOM::Backoffice::Request::template()->process(
    'backoffice/crypto_wrong_currency_deposit.html.tt',
    {
        data_url         => request()->url_for('backoffice/crypto_wrong_currency_deposit.cgi'),
        currency_options => \@all_cryptos,

    }) || die BOM::Backoffice::Request::template()->error(), "\n";

code_exit_BO();
