#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use Scalar::Util qw(looks_like_number);
use Date::Utility;
use HTML::Entities;

use BOM::User::Client;

use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Form;

use f_brokerincludeall;
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation("Setting Client Self Exclusion");

my $title = 'Setting Client Self Exclusion - restricted fields';

my $loginid = uc(request()->param('loginid'));

my $client = eval { BOM::User::Client::get_instance({'loginid' => $loginid}) };
if (not $client) {
    print "Error: Wrong Login ID ($loginid) could not get client object";
    code_exit_BO();
}

# Not available for Virtual Accounts
if ($client->is_virtual) {
    code_exit_BO("We're sorry but the Self Exclusion facility is not available for Virtual Accounts.", $title);
}

my $deposit_limit_enabled = $client->landing_company->deposit_limit_enabled;

my $self_exclusion = $client->get_self_exclusion;

my $self_exclusion_link = request()->url_for('backoffice/f_setting_selfexclusion_restricted.cgi', {loginid => $loginid});

Bar($title);

my $broker = $client->broker;

my $db = $client->db->dbic;

my $self_exclusion_form = BOM::Backoffice::Form::get_self_exclusion_form({
    client          => $client,
    lang            => request()->language,
    restricted_only => 1
});

my $client_details_link = request()->url_for(
    "backoffice/f_clientloginid_edit.cgi",
    {
        broker  => $broker,
        loginID => $loginid
    });

my $page = "<h3>Self-exclusion settings for <a class='link' href='$client_details_link'>" . encode_entities($loginid) . '</a></h3>';

# to generate existing limits
if ($self_exclusion) {
    my $info;

    $info .= make_row(
        'Maximum account cash balance',
        $client->currency,
        $self_exclusion->max_balance,
        get_limit_expiration_date($db, $loginid, 'max_balance', 30)) if $self_exclusion->max_balance;
    $info .= make_row(
        'Daily limit on losses   ',    # extra spaces are added to get a correct result from perltidy
        $client->currency,
        $self_exclusion->max_losses,
        get_limit_expiration_date($db, $loginid, 'max_losses', 1)) if $self_exclusion->max_losses;
    $info .= make_row(
        '7-Day limit on losses',
        $client->currency,
        $self_exclusion->max_7day_losses,
        get_limit_expiration_date($db, $loginid, 'max_7day_losses', 7)) if $self_exclusion->max_7day_losses;
    $info .= make_row(
        '30-Day limit on losses',
        $client->currency,
        $self_exclusion->max_30day_losses,
        get_limit_expiration_date($db, $loginid, 'max_30day_losses', 30)) if $self_exclusion->max_30day_losses;

    $info .= make_row(
        'Daily limit on deposits',
        $client->currency,
        $self_exclusion->max_deposit_daily,
        get_limit_expiration_date($db, $loginid, 'max_deposit_daily', 1)) if $deposit_limit_enabled and $self_exclusion->max_deposit_daily;
    $info .= make_row(
        '7-day limit on deposits',
        $client->currency,
        $self_exclusion->max_deposit_7day,
        get_limit_expiration_date($db, $loginid, 'max_deposit_7day', 7)) if $deposit_limit_enabled and $self_exclusion->max_deposit_7day;
    $info .= make_row(
        '30-day limit on deposits',
        $client->currency,
        $self_exclusion->max_deposit_30day,
        get_limit_expiration_date($db, $loginid, 'max_deposit_30day', 30)) if $deposit_limit_enabled and $self_exclusion->max_deposit_30day;

    if ($info) {
        $page .=
              '<p>Currently set values are:</p><table class="alternate border">'
            . '<thead><tr><th>Limit name</th><th>Limit value</th><th>Expiration date</th></tr></thead><tbody>'
            . $info
            . '</tbody></table><br>';
    }

    $page .= '<p>You may change it by editing the corresponding value:</p>';
}

# first time (not submitted)
if (request()->http_method eq 'GET' or request()->param('action') ne 'process') {
    $page .= $self_exclusion_form->build();
    print $page;
    code_exit_BO();
}

# Server side validations
$self_exclusion_form->set_input_fields(request()->params);

# print the form again if there is any error
if (not $self_exclusion_form->validate()) {
    $page .= $self_exclusion_form->build();
    print $page;
    code_exit_BO();
}

my $v;
$v = request()->param('DAILYLOSSLIMIT');
$client->set_exclusion->max_losses(looks_like_number($v) ? $v : undef);
$v = request()->param('7DAYLOSSLIMIT');
$client->set_exclusion->max_7day_losses(looks_like_number($v) ? $v : undef);
$v = request()->param('30DAYLOSSLIMIT');
$client->set_exclusion->max_30day_losses(looks_like_number($v) ? $v : undef);

if ($deposit_limit_enabled) {
    $v = request()->param('DAILYDEPOSITLIMIT');
    $client->set_exclusion->max_deposit_daily(looks_like_number($v) ? $v : undef);
    $v = request()->param('7DAYDEPOSITLIMIT');
    $client->set_exclusion->max_deposit_7day(looks_like_number($v) ? $v : undef);
    $v = request()->param('30DAYDEPOSITLIMIT');
    $client->set_exclusion->max_deposit_30day(looks_like_number($v) ? $v : undef);
}

if ($client->save) {
    #print message inform Client everything is ok
    print "<p class=\"aligncenter\">Thank you. the client settings have been updated.</p>";
} else {
    print "<p class=\"aligncenter\">Sorry, the client settings have not been updated, please try it again.</p>";
    warn("Error: cannot write to self_exclusion table $!");
}

print qq{<a class='link' href='$client_details_link'>&laquo; Return to client details</a>};
print qq{<br/><a class='link' href='$self_exclusion_link'>&laquo; Go back to restricted self-exclusion settings</a>};

code_exit_BO();
