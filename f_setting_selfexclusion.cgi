#!/usr/bin/perl
package main;
use strict 'vars';

use Scalar::Util qw(looks_like_number);
use BOM::Utility::Log4perl qw( get_logger );
use BOM::Platform::Plack qw( PrintContentType );
use BOM::View::CGIForm;

use f_brokerincludeall;
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

PrintContentType();
BrokerPresentation("Setting Client Self Exclusion");
BOM::Platform::Auth0::can_access(['CS']);

my $loginid = request()->param('loginid');
Bar("Setting Client Self Exclusion");

# Not available for Virtual Accounts
if ($loginid =~ /^VRT/) {
    print '<h1>' . localize('Self-Exclusion Facilities') . '</h1>';
    print '<p class="aligncenter">' . localize('We\'re sorry but the Self Exclusion facility is not available for Virtual Accounts.') . '</p>';
    get_logger->info("[$loginid] Virtual Accounts cannot set Self Exclusion limits.");
    code_exit_BO();
}

my $client = BOM::Platform::Client::get_instance({'loginid' => $loginid})
    || die "[$0] Could not get the client object instance for client [$loginid]";

my $broker = $client->broker;

my $self_exclusion_form = BOM::View::CGIForm::get_self_exclusion_form({
    client           => $client,
    lang             => request()->language,
    from_back_office => 1,
});

my $page =
    '<h2> The Client [loginid: ' . $loginid . '] self-exclusion settings are as follows. You may change it by editing the corresponding value.</h2>';

#to generate existing limits
if (my $self_exclusion = $client->self_exclusion) {
    $page .= '<ul>';
    $self_exclusion_form->set_field_value('MAXCASHBAL',         $self_exclusion->max_balance);
    $self_exclusion_form->set_field_value('DAILYTURNOVERLIMIT', $self_exclusion->max_turnover);
    $self_exclusion_form->set_field_value('MAXOPENPOS',         $self_exclusion->max_open_bets);
    $self_exclusion_form->set_field_value('SESSIONDURATION',    $self_exclusion->session_duration_limit);
    if (my $exclude_until_date = $self_exclusion->exclude_until) {
        $exclude_until_date = Date::Utility->new($exclude_until_date)->date_ddmmmyy;
        $self_exclusion_form->set_field_value('EXCLUDEUNTIL', $exclude_until_date);
    }

    if ($self_exclusion->max_balance) {
        $page .= '<li>'
            . localize('Maximum account cash balance is currently set to <strong>[_1] [_2]</strong>', $client->currency, $self_exclusion->max_balance)
            . '</li>';
    }
    if ($self_exclusion->max_turnover) {
        $page .= '<li>'
            . localize('Daily Turnover limit is currently set to <strong>[_1] [_2]</strong>', $client->currency, $self_exclusion->max_turnover)
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

my $v = request()->param('MAXOPENPOS');
$client->set_exclusion->max_open_bets(looks_like_number($v) ? $v : undef);
my $v = request()->param('DAILYTURNOVERLIMIT');
$client->set_exclusion->max_turnover(looks_like_number($v) ? $v : undef);
my $v = request()->param('MAXCASHBAL');
$client->set_exclusion->max_balance(looks_like_number($v) ? $v : undef);
my $v = request()->param('SESSIONDURATION');
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
    get_logger->error("Cannot write to self_exclusion table $!");
}

code_exit_BO();
