#!/usr/bin/perl
package main;
use strict 'vars';

use Scalar::Util qw(looks_like_number);
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Backoffice::Form;

use f_brokerincludeall;
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

PrintContentType();
BrokerPresentation("Setting Client Self Exclusion");
BOM::Backoffice::Auth0::can_access(['CS']);

my $loginid = request()->param('loginid');
Bar("Setting Client Self Exclusion");

# Not available for Virtual Accounts
if ($loginid =~ /^VRT/) {
    print '<h1>' . localize('Self-Exclusion Facilities') . '</h1>';
    print '<p class="aligncenter">' . localize('We\'re sorry but the Self Exclusion facility is not available for Virtual Accounts.') . '</p>';
    code_exit_BO();
}

my $client = BOM::Platform::Client::get_instance({'loginid' => $loginid})
    || die "[$0] Could not get the client object instance for client [$loginid]";

my $broker = $client->broker;

my $self_exclusion_form = BOM::Backoffice::Form::get_self_exclusion_form({
    client           => $client,
    lang             => request()->language,
});

my $page =
    '<h2> The Client [loginid: ' . $loginid . '] self-exclusion settings are as follows. You may change it by editing the corresponding value.</h2>';

#to generate existing limits
if (my $self_exclusion = $client->get_self_exclusion) {
    $page .= '<ul>';

    if ($self_exclusion->max_balance) {
        $page .= '<li>'
            . localize('Maximum account cash balance is currently set to <strong>[_1] [_2]</strong>', $client->currency, $self_exclusion->max_balance)
            . '</li>';
    }
    if ($self_exclusion->max_turnover) {
        $page .= '<li>'
            . localize('Daily turnover limit is currently set to <strong>[_1] [_2]</strong>', $client->currency, $self_exclusion->max_turnover)
            . '</li>';
    }
    if ($self_exclusion->max_losses) {
        $page .= '<li>'
            . localize('Daily limit on losses is currently set to <strong>[_1] [_2]</strong>', $client->currency, $self_exclusion->max_losses)
            . '</li>';
    }
    if ($self_exclusion->max_7day_turnover) {
        $page .= '<li>'
            . localize('7-Day turnover limit is currently set to <strong>[_1] [_2]</strong>', $client->currency, $self_exclusion->max_7day_turnover)
            . '</li>';
    }
    if ($self_exclusion->max_7day_losses) {
        $page .= '<li>'
            . localize('7-Day limit on losses is currently set to <strong>[_1] [_2]</strong>', $client->currency, $self_exclusion->max_7day_losses)
            . '</li>';
    }
    if ($self_exclusion->max_open_bets) {
        $page .=
            '<li>' . localize('Maximum number of open positions is currently set to <strong>[_1]</strong>', $self_exclusion->max_open_bets) . '</li>';
    }
    if ($self_exclusion->session_duration_limit) {
        $page .= '<li>'
            . localize('Session duration limit is currently set to <strong>[_1] minutes.</strong>', $self_exclusion->session_duration_limit)
            . '</li>';
    }
    if ($self_exclusion->exclude_until) {
        $page .= '<li>' . localize('Website exclusion is currently set to <strong>[_1].</strong>', $self_exclusion->exclude_until) . '</li>';
    }
    $page .= '</ul>';
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
$v = request()->param('MAXOPENPOS');
$client->set_exclusion->max_open_bets(looks_like_number($v) ? $v : undef);
$v = request()->param('DAILYTURNOVERLIMIT');
$client->set_exclusion->max_turnover(looks_like_number($v) ? $v : undef);
$v = request()->param('DAILYLOSSLIMIT');
$client->set_exclusion->max_losses(looks_like_number($v) ? $v : undef);
$v = request()->param('7DAYTURNOVERLIMIT');
$client->set_exclusion->max_7day_turnover(looks_like_number($v) ? $v : undef);
$v = request()->param('7DAYLOSSLIMIT');
$client->set_exclusion->max_7day_losses(looks_like_number($v) ? $v : undef);
$v = request()->param('30DAYTURNOVERLIMIT');
$client->set_exclusion->max_30day_turnover(looks_like_number($v) ? $v : undef);
$v = request()->param('30DAYLOSSLIMIT');
$client->set_exclusion->max_30day_losses(looks_like_number($v) ? $v : undef);
$v = request()->param('MAXCASHBAL');
$client->set_exclusion->max_balance(looks_like_number($v) ? $v : undef);
$v = request()->param('SESSIONDURATION');
$client->set_exclusion->session_duration_limit(looks_like_number($v) ? $v : undef);

# by or-ing to 'undef' here we turn any blank exclude_until date to no-date.
$client->set_exclusion->exclude_until(request()->param('EXCLUDEUNTIL') || undef);

if ($client->save) {
    #print message inform Client everything is ok
    print "<p class=\"aligncenter\">Thank you. the client settings have been updated.</p>";
    print "<a href=\""
        . request()->url_for(
        "backoffice/f_clientloginid_edit.cgi",
        {
            broker  => $broker,
            loginID => $loginid
        }) . "\">&laquo; return to client details</a>";
} else {
    print "<p class=\"aligncenter\">Sorry, the client settings have not been updated, please try it again.</p>";
    warn("Error: cannot write to self_exclusion table $!");
}

code_exit_BO();
