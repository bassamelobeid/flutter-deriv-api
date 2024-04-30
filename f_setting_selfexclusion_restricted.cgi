#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use Scalar::Util qw(looks_like_number);
use Date::Utility;
use HTML::Entities;

use BOM::User::Client;

use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Utility;
use BOM::Backoffice::Form;

use f_brokerincludeall;
use BOM::Backoffice::Sysinit ();
use Log::Any                 qw($log);
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

if (request()->http_method eq 'POST') {
    # Server side validations
    $self_exclusion_form->set_input_fields(request()->params);

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
        print "<p class=\"success\">Thank you. the client settings have been updated.</p>";
    } else {
        print "<p class=\"error\">Sorry, the client settings have not been updated, please try it again.</p>";
        $log->warn("Error: cannot write to self_exclusion table $!");
    }
}

# to generate existing limits
if ($self_exclusion) {
    my $info;
    my $audit = +{map { (delete $_->{field} => $_) } $client->get_self_exclusion_audit->@*};

    $info .= make_row(
        'Daily limit on losses',
        $self_exclusion->max_losses ? $self_exclusion->max_losses . ' ' . $client->currency : undef,
        get_limit_expiration_date($db, $loginid, 'max_losses', 1),
        $audit->{max_losses}->{changed_stamp},
        $audit->{max_losses}->{prev_value},
        $audit->{max_losses}->{changed_by}) if exists $audit->{max_losses};
    $info .= make_row(
        'Daily limit on deposits',
        $self_exclusion->max_deposit_daily ? $self_exclusion->max_deposit_daily . ' ' . $client->currency : undef,
        get_limit_expiration_date($db, $loginid, 'max_deposit_daily', 1),
        $audit->{max_deposit_daily}->{changed_stamp},
        $audit->{max_deposit_daily}->{prev_value},
        $audit->{max_deposit_daily}->{changed_by}) if $deposit_limit_enabled and exists $audit->{max_deposit_daily};
    $info .= make_row(
        '7-Day limit on losses',
        $self_exclusion->max_7day_losses ? $self_exclusion->max_7day_losses . ' ' . $client->currency : undef,
        get_limit_expiration_date($db, $loginid, 'max_7day_losses', 7),
        $audit->{max_7day_losses}->{changed_stamp},
        $audit->{max_7day_losses}->{prev_value},
        $audit->{max_7day_losses}->{changed_by}) if exists $audit->{max_7day_losses};
    $info .= make_row(
        '7-day limit on deposits',
        $self_exclusion->max_deposit_7day ? $self_exclusion->max_deposit_7day . ' ' . $client->currency : undef,
        get_limit_expiration_date($db, $loginid, 'max_deposit_7day', 7),
        $audit->{max_deposit_7day}->{changed_stamp},
        $audit->{max_deposit_7day}->{prev_value},
        $audit->{max_deposit_7day}->{changed_by}) if $deposit_limit_enabled and exists $audit->{max_deposit_7day};
    $info .= make_row(
        '30-Day limit on losses',
        $self_exclusion->max_30day_losses ? $self_exclusion->max_30day_losses . ' ' . $client->currency : undef,
        get_limit_expiration_date($db, $loginid, 'max_30day_losses', 30),
        $audit->{max_30day_losses}->{changed_stamp},
        $audit->{max_30day_losses}->{prev_value},
        $audit->{max_30day_losses}->{changed_by}) if exists $audit->{max_30day_losses};
    $info .= make_row(
        '30-Day limit on deposits',
        $self_exclusion->max_deposit_30day ? $self_exclusion->max_deposit_30day . ' ' . $client->currency : undef,
        get_limit_expiration_date($db, $loginid, 'max_deposit_30day', 30),
        $audit->{max_deposit_30day}->{changed_stamp},
        $audit->{max_deposit_30day}->{prev_value},
        $audit->{max_deposit_30day}->{changed_by}) if $deposit_limit_enabled and exists $audit->{max_deposit_30day};
    update_self_exclusion_time_settings($client);

    if ($info) {
        $page .=
              '<p>Currently set values are:</p><table class="alternate border">'
            . '<thead><tr><th>Limit name</th><th>Limit value</th><th>Expiration date</th><th>Self-exclusion set date</th><th>Previous limit</th><th>Set by</th></tr></thead><tbody>'
            . $info
            . '</tbody></table><br>';
    }

    $page .= '<p>You may change it by editing the corresponding value:</p>';
}

$page .= $self_exclusion_form->build();
print $page;

code_exit_BO();
