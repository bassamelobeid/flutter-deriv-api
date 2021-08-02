#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use Scalar::Util qw(looks_like_number);
use Date::Utility;
use HTML::Entities;

use BOM::User::Client;
use BOM::Database::ClientDB;

use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Form;

use f_brokerincludeall;
use BOM::Backoffice::Sysinit ();
use Log::Any qw($log);
BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation("Setting Client Self Exclusion");

my $title = 'Setting Client Self Exclusion';

my $loginid = request()->param('loginid') || '';

my $client = eval { BOM::User::Client::get_instance({'loginid' => $loginid}) };
if (not $client) {
    code_exit_BO("Error: Wrong Login ID ($loginid) could not get client object.", $title);
}

# Not available for Virtual Accounts
if ($client->is_virtual) {
    code_exit_BO("We're sorry but the Self Exclusion facility is not available for Virtual Accounts.", $title);
}

# some limits are not updatable in regulated landing companies
my $regulated_lc          = $client->landing_company->is_eu;
my $deposit_limit_enabled = $client->landing_company->deposit_limit_enabled;

my $broker = $client->broker;

my $self_exclusion = $client->get_self_exclusion;

if (   !$regulated_lc
    && request()->param('fix_begin_date')
    && $self_exclusion
    && $self_exclusion->max_deposit
    && !$self_exclusion->max_deposit_begin_date)
{
    # calling get_limit_expiration_date to get the date at which max_deposit was updated for the last time
    my $last_update_date = get_limit_expiration_date($client->db->dbic, $loginid, 'max_deposit');
    $client->set_exclusion->max_deposit_begin_date($last_update_date);
    $client->save;

    my $self_exclusion_link = request()->url_for('backoffice/f_setting_selfexclusion.cgi', {loginid => $loginid});
    code_exit_BO(
        '<p>Maximum deposit begin date was successfully set to '
            . $last_update_date
            . " for $loginid </p>"
            . "<p><a class='link' href='$self_exclusion_link'>Go back to self-exclusion settings</a></p>",
        $title
    );
}

my $client_details_link = request()->url_for(
    "backoffice/f_clientloginid_edit.cgi",
    {
        broker  => $broker,
        loginID => $loginid
    });

Bar($title);

my $self_exclusion_form = BOM::Backoffice::Form::get_self_exclusion_form({
    client          => $client,
    lang            => request()->language,
    restricted_only => 0
});

my $db = $client->db->dbic;

my $page = "<h3>Self-exclusion settings for <a class='link' href='$client_details_link'>" . encode_entities($loginid) . '</a></h3>';

=head2 make_row

get values required for creating self-exclusion table

=over

=item * C<name> - required. Name of a limit.

=item * C<values> - required. List of values including amount and expiration date for each limit

=back

=cut

sub make_row {
    my ($name, @values) = @_;
    my $expiration_date = $values[2] // '';
    return
          '<tr><td>'
        . $name
        . '</td><td><strong>'
        . (join ' ', @values[0 .. 1])
        . '</strong></td><td><strong>'
        . $expiration_date
        . '</strong></td></tr>';
}

if (request()->http_method eq 'POST') {
    # Server side validations
    $self_exclusion_form->set_input_fields(request()->params);

    my $v;
    $v = request()->param('MAXOPENPOS');
    $client->set_exclusion->max_open_bets(looks_like_number($v) && $v ? $v : undef);
    $v = request()->param('DAILYTURNOVERLIMIT');
    $client->set_exclusion->max_turnover(looks_like_number($v) && $v ? $v : undef);
    $v = request()->param('7DAYTURNOVERLIMIT');
    $client->set_exclusion->max_7day_turnover(looks_like_number($v) && $v ? $v : undef);
    $v = request()->param('30DAYTURNOVERLIMIT');
    $client->set_exclusion->max_30day_turnover(looks_like_number($v) && $v ? $v : undef);
    $v = request()->param('MAXCASHBAL');
    $client->set_exclusion->max_balance(looks_like_number($v) && $v ? $v : undef);
    $v = request()->param('SESSIONDURATION');
    $client->set_exclusion->session_duration_limit(looks_like_number($v) && $v ? $v : undef);

    unless ($regulated_lc) {
        $v = request()->param('DAILYLOSSLIMIT');
        $client->set_exclusion->max_losses(looks_like_number($v) && $v ? $v : undef);
        $v = request()->param('7DAYLOSSLIMIT');
        $client->set_exclusion->max_7day_losses(looks_like_number($v) && $v ? $v : undef);
        $v = request()->param('30DAYLOSSLIMIT');
        $client->set_exclusion->max_30day_losses(looks_like_number($v) && $v ? $v : undef);
    }

    if ($deposit_limit_enabled) {
        $v = request()->param('DAILYDEPOSITLIMIT');
        $client->set_exclusion->max_deposit_daily(looks_like_number($v) && $v ? $v : undef);
        $v = request()->param('7DAYDEPOSITLIMIT');
        $client->set_exclusion->max_deposit_7day(looks_like_number($v) && $v ? $v : undef);
        $v = request()->param('30DAYDEPOSITLIMIT');
        $client->set_exclusion->max_deposit_30day(looks_like_number($v) && $v ? $v : undef);
    }

    my $form_exclusion_until_date = request()->param('EXCLUDEUNTIL') || undef;

    $form_exclusion_until_date = Date::Utility->new($form_exclusion_until_date) if $form_exclusion_until_date;

    my $exclude_until_date;

    if ($client->get_self_exclusion->exclude_until) {
        $exclude_until_date = Date::Utility->new($client->get_self_exclusion->exclude_until);
    }

    # If no change has been made in the exclude_until field, then ignore the checking
    if (!$exclude_until_date || !$form_exclusion_until_date || $form_exclusion_until_date->date ne $exclude_until_date->date) {
        if (allow_uplift_self_exclusion($client, $exclude_until_date, $form_exclusion_until_date)) {

            if ($form_exclusion_until_date) {
                $client->set_exclusion->exclude_until($form_exclusion_until_date->date);
            } else {
                $client->set_exclusion->exclude_until(undef);
            }
        } else {
            print "<p class=\"aligncenter error\">>WARNING: Client's self-exclusion date cannot be changed</p>";
        }
    }

    my $timeout_until = request()->param('TIMEOUTUNTIL') || undef;
    $timeout_until = Date::Utility->new($timeout_until)->epoch if $timeout_until;
    $client->set_exclusion->timeout_until($timeout_until);

    if ($client->save) {
        #print message inform Client everything is ok
        print "<p class=\"success\">Thank you. the client settings have been updated.</p>";
    } else {
        print "<p class=\"error\">Sorry, the client settings have not been updated, please try it again.</p>";
        $log->warn("Error: cannot write to self_exclusion table $!");
    }
}

# to generate existing limits
if (my $self_exclusion = $client->get_self_exclusion) {
    my $info;
    $info .= '<thead><tr><th>Limit name</th><th>Limit value</th><th>Expiration date</th></tr></thead><tbody>';
    $info .= make_row(
        'Maximum account cash balance',
        $client->currency,
        $self_exclusion->max_balance,
        get_limit_expiration_date($db, $loginid, 'max_balance', 30)) if defined $self_exclusion->max_balance;
    $info .= make_row(
        'Daily turnover limit',
        $client->currency,
        $self_exclusion->max_turnover,
        get_limit_expiration_date($db, $loginid, 'max_turnover', 1)) if defined $self_exclusion->max_turnover;
    $info .=
        make_row('Daily limit on losses', $client->currency, $self_exclusion->max_losses, get_limit_expiration_date($db, $loginid, 'max_losses', 1))
        if defined $self_exclusion->max_losses;
    $info .= make_row(
        'Daily deposit limit',
        $client->currency,
        $self_exclusion->max_deposit_daily,
        get_limit_expiration_date($db, $loginid, 'max_deposit_daily', 1)) if $deposit_limit_enabled and defined $self_exclusion->max_deposit_daily;
    $info .= make_row(
        '7-Day turnover limit',
        $client->currency,
        $self_exclusion->max_7day_turnover,
        get_limit_expiration_date($db, $loginid, 'max_7day_turnover', 7)) if defined $self_exclusion->max_7day_turnover;
    $info .= make_row(
        '7-Day limit on losses',
        $client->currency,
        $self_exclusion->max_7day_losses,
        get_limit_expiration_date($db, $loginid, 'max_7day_losses', 7)) if defined $self_exclusion->max_7day_losses;
    $info .= make_row(
        '7-Day deposit limit',
        $client->currency,
        $self_exclusion->max_deposit_7day,
        get_limit_expiration_date($db, $loginid, 'max_deposit_7day', 7)) if $deposit_limit_enabled and defined $self_exclusion->max_deposit_7day;
    $info .= make_row(
        '30-Day turnover limit',
        $client->currency,
        $self_exclusion->max_30day_turnover,
        get_limit_expiration_date($db, $loginid, 'max_30day_turnover', 30)) if defined $self_exclusion->max_30day_turnover;
    $info .= make_row(
        '30-Day limit on losses',
        $client->currency,
        $self_exclusion->max_30day_losses,
        get_limit_expiration_date($db, $loginid, 'max_30day_losses', 30)) if defined $self_exclusion->max_30day_losses;
    $info .= make_row(
        '30-Day deposit limit',
        $client->currency,
        $self_exclusion->max_deposit_30day,
        get_limit_expiration_date($db, $loginid, 'max_deposit_30day', 30)) if $deposit_limit_enabled and defined $self_exclusion->max_deposit_30day;

    $info .=
        make_row('Maximum number of open positions', $self_exclusion->max_open_bets, '', get_limit_expiration_date($db, $loginid, 'max_open_bets', 1))
        if defined $self_exclusion->max_open_bets;

    $info .= make_row(
        'Session duration limit',
        $self_exclusion->session_duration_limit,
        'minutes', get_limit_expiration_date($db, $loginid, 'session_duration_limit', 1)) if defined $self_exclusion->session_duration_limit;

    $info .= make_row('Website exclusion', '', '', Date::Utility->new($self_exclusion->exclude_until)->date)
        if defined $self_exclusion->exclude_until;

    $info .= make_row('Website Timeout until', '', '', Date::Utility->new($self_exclusion->timeout_until)->datetime_yyyymmdd_hhmmss)
        if defined $self_exclusion->timeout_until;

    if ($info) {
        $page .= '<p>Currently set values are:</p><table class="border alternate">' . $info . '</tbody></table><br>';
    }

    $page .= '<p>You may change it by editing the corresponding value:</p>';
}

$page .= $self_exclusion_form->build();
print $page;
code_exit_BO();
