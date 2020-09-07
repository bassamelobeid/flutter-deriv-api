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
    print "Error: wrong loginid ($loginid) could not get client object";
    code_exit_BO();
}

# Not available for Virtual Accounts
if ($client->is_virtual) {
    code_exit_BO("We're sorry but the Self Exclusion facility is not available for Virtual Accounts.", $title);
}

my $self_exclusion = $client->get_self_exclusion;

if (request()->param('fix_begin_date') && $self_exclusion && $self_exclusion->max_deposit && !$self_exclusion->max_deposit_begin_date) {
    # calling get_limit_expiration_date to get the date at which max_deposit was updated for the last time
    my $last_update_date = get_limit_expiration_date($client->db->dbic, $loginid, 'max_deposit');
    $client->set_exclusion->max_deposit_begin_date($last_update_date);
    $client->save;

    my $self_exclusion_link = request()->url_for('backoffice/f_setting_selfexclusion_restricted.cgi', {loginid => $loginid});
    code_exit_BO('<p>Maximum deposit begin date was successfully set to '
            . $last_update_date
            . " for $loginid </p>"
            . "<p><a href = '$self_exclusion_link'>Back to self exclusion settings </a></p>");
}

Bar($title);

my $broker = $client->broker;

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

my $page =
      "<h2> The Client loginid: <a href='$client_details_link'>"
    . encode_entities($loginid)
    . ' </a> restricted self-exclusion settings are editeable here.</h2>';

# to generate existing limits
if ($self_exclusion) {
    my $info;

    $info .= make_row('Maximum account cash balance', $client->currency, $self_exclusion->max_balance) if $self_exclusion->max_balance;
    $info .= make_row(
        'Daily limit on losses', $client->currency, $self_exclusion->max_losses,

    ) if $self_exclusion->max_losses;
    $info .= make_row(
        '7-Day limit on losses', $client->currency, $self_exclusion->max_7day_losses,

    ) if $self_exclusion->max_7day_losses;
    $info .= make_row(
        '30-Day limit on losses', $client->currency, $self_exclusion->max_30day_losses,

    ) if $self_exclusion->max_30day_losses;

    if ($self_exclusion->max_deposit) {
        $info .= make_row(
            'Maximum deposit limit',
            $client->currency,
            $self_exclusion->max_deposit,
            Date::Utility->new($self_exclusion->max_deposit_end_date)->date
        );

        my $begin_date =
            $self_exclusion->max_deposit_begin_date
            ? Date::Utility->new($self_exclusion->max_deposit_begin_date)->date
            : '<span style="color:red">EMPTY<span>';
        my $fix_url = request()->url_for(
            'backoffice/f_setting_selfexclusion_restricted.cgi',
            {
                loginid        => $loginid,
                fix_begin_date => 1
            });
        my $fix_link = $self_exclusion->max_deposit_begin_date ? '' : "<a href = '$fix_url'> Click to fix </a>";
        $info .= make_row('Maximum deposit limit start date', $begin_date, $fix_link, '');
    }

    if ($info) {
        $page .=
              '<h3>Currently set values are:</h3><table cellspacing="0" cellpadding="5" border="1" class="GreyCandy">'
            . '<tr><td><strong>Limit name</strong></td><td><strong>Limit value</strong></td><td><strong>Expiration date</strong></td></tr>'
            . $info
            . '</table>';
    }
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

my $form_max_deposit_date   = request()->param('MAXDEPOSITDATE') || undef;
my $form_max_deposit_amount = request()->param('MAXDEPOSIT')     || undef;

# user will not be allowed to set a max deposit without an expiry time
if ($form_max_deposit_date xor defined $form_max_deposit_amount) {
    code_exit_BO("Max deposit and Max deposit end date must be set together");
}

if ($form_max_deposit_date) {
    my $max_deposit_date = Date::Utility->new($form_max_deposit_date);
    my $now              = Date::Utility->new;
    code_exit_BO("Cannot set a Max deposit end date in the past") if $max_deposit_date->is_before($now);
    code_exit_BO("Max deposit is not a number") unless (looks_like_number($form_max_deposit_amount));

    $client->set_exclusion->max_deposit_end_date($max_deposit_date->date);
    $client->set_exclusion->max_deposit_begin_date($now->date);
    $client->set_exclusion->max_deposit($form_max_deposit_amount);
} else {
    $client->set_exclusion->max_deposit_end_date(undef);
    $client->set_exclusion->max_deposit_begin_date(undef);
    $client->set_exclusion->max_deposit(undef);
}

if ($client->save) {
    #print message inform Client everything is ok
    print "<p class=\"aligncenter\">Thank you. the client settings have been updated.</p>";
    print qq{<a href='$client_details_link'>&laquo; return to client details</a>};
} else {
    print "<p class=\"aligncenter\">Sorry, the client settings have not been updated, please try it again.</p>";
    warn("Error: cannot write to self_exclusion table $!");
}

code_exit_BO();
