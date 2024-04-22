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
use Date::Utility;

use f_brokerincludeall;
use BOM::Backoffice::Sysinit ();
use Log::Any                 qw($log);
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
my $exclude_date          = {
    "EXCLUDEUNTIL" => "exclude_until",
    "TIMEOUTUNTIL" => "timeout_until"
};
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

=item * C<values>: name, value, expiration, changed_stamp, changed_by

=back

=cut

sub make_row {
    my @values = @_;

    my $val =
        defined $values[1]
        ? '<td><strong>' . $values[1] . '</strong><td>' . $values[2] . '</td>'
        : '<td colspan=2><i>none</i></td>';

    return
          '<tr><td>'
        . $values[0] . '</td>'
        . $val . '<td>'
        . $values[3]
        . '</td><td>'
        . ($values[4] // '<i>none</i>')
        . '</td><td>'
        . $values[5]
        . '</td></tr>';
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

    for my $field (qw(EXCLUDEUNTIL TIMEOUTUNTIL)) {
        my $date_until = request()->param($field) || undef;
        if ($date_until) {
            my $date_util = Date::Utility->new($date_until);
            $date_until = $date_util->epoch;
        }
        my $field_param = $exclude_date->{$field};
        for my $sibling_id ($client->user->bom_real_loginids) {
            my $sibling = BOM::User::Client::get_instance({'loginid' => $sibling_id});
            $sibling->set_exclusion->$field_param($date_until);
            $sibling->save;
        }
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
    my $audit = +{map { (delete $_->{field} => $_) } $client->get_self_exclusion_audit->@*};

    my $info;
    $info .=
        '<thead><tr><th>Limit name</th><th>Limit value</th><th>Expiration date</th><th>Self-exclusion set date</th><th>Previous limit</th><th>Set by</th></tr></thead><tbody>';
    $info .= make_row(
        'Maximum account cash balance',
        $self_exclusion->max_balance ? $self_exclusion->max_balance . ' ' . $client->currency : undef,
        get_limit_expiration_date($db, $loginid, 'max_balance', 30),
        $audit->{max_balance}->{changed_stamp},
        $audit->{max_balance}->{prev_value},
        $audit->{max_balance}->{changed_by}) if exists $audit->{max_balance};
    $info .= make_row(
        'Daily turnover limit',
        $self_exclusion->max_turnover ? $self_exclusion->max_turnover . ' ' . $client->currency : undef,
        get_limit_expiration_date($db, $loginid, 'max_turnover', 1),
        $audit->{max_turnover}->{changed_stamp},
        $audit->{max_turnover}->{prev_value},
        $audit->{max_turnover}->{changed_by}) if exists $audit->{max_turnover};
    $info .= make_row(
        'Daily limit on losses',
        $self_exclusion->max_losses ? $self_exclusion->max_losses . ' ' . $client->currency : undef,
        get_limit_expiration_date($db, $loginid, 'max_losses', 1),
        $audit->{max_losses}->{changed_stamp},
        $audit->{max_losses}->{prev_value},
        $audit->{max_losses}->{changed_by}) if exists $audit->{max_losses};
    $info .= make_row(
        'Daily deposit limit',
        $self_exclusion->max_deposit_daily ? $self_exclusion->max_deposit_daily . ' ' . $client->currency : undef,
        get_limit_expiration_date($db, $loginid, 'max_deposit_daily', 1),
        $audit->{max_deposit_daily}->{changed_stamp},
        $audit->{max_deposit_daily}->{prev_value},
        $audit->{max_deposit_daily}->{changed_by}) if $deposit_limit_enabled and exists $audit->{max_deposit_daily};
    $info .= make_row(
        '7-Day turnover limit',
        $self_exclusion->max_7day_turnover ? $self_exclusion->max_7day_turnover . ' ' . $client->currency : undef,
        get_limit_expiration_date($db, $loginid, 'max_7day_turnover', 7),
        $audit->{max_7day_turnover}->{changed_stamp},
        $audit->{max_7day_turnover}->{prev_value},
        $audit->{max_7day_turnover}->{changed_by}) if exists $audit->{max_7day_turnover};
    $info .= make_row(
        '7-Day limit on losses',
        $self_exclusion->max_7day_losses ? $self_exclusion->max_7day_losses . ' ' . $client->currency : undef,
        get_limit_expiration_date($db, $loginid, 'max_7day_losses', 7),
        $audit->{max_7day_losses}->{changed_stamp},
        $audit->{max_7day_losses}->{prev_value},
        $audit->{max_7day_losses}->{changed_by}) if exists $audit->{max_7day_losses};
    $info .= make_row(
        '7-Day deposit limit',
        $self_exclusion->max_deposit_7day ? $self_exclusion->max_deposit_7day . ' ' . $client->currency : undef,
        get_limit_expiration_date($db, $loginid, 'max_deposit_7day', 7),
        $audit->{max_deposit_7day}->{changed_stamp},
        $audit->{max_deposit_7day}->{prev_value},
        $audit->{max_deposit_7day}->{changed_by}) if $deposit_limit_enabled and exists $audit->{max_deposit_7day};
    $info .= make_row(
        '30-Day turnover limit',
        $self_exclusion->max_30day_turnover ? $self_exclusion->max_30day_turnover . ' ' . $client->currency : undef,
        get_limit_expiration_date($db, $loginid, 'max_30day_turnover', 30),
        $audit->{max_30day_turnover}->{changed_stamp},
        $audit->{max_30day_turnover}->{prev_value},
        $audit->{max_30day_turnover}->{changed_by}) if exists $audit->{max_30day_turnover};
    $info .= make_row(
        '30-Day limit on losses',
        $self_exclusion->max_30day_losses ? $self_exclusion->max_30day_losses . ' ' . $client->currency : undef,
        get_limit_expiration_date($db, $loginid, 'max_30day_losses', 30),
        $audit->{max_30day_losses}->{changed_stamp},
        $audit->{max_30day_losses}->{prev_value},
        $audit->{max_30day_losses}->{changed_by}) if exists $audit->{max_30day_losses};
    $info .= make_row(
        '30-Day deposit limit',
        $self_exclusion->max_deposit_30day ? $self_exclusion->max_deposit_30day . ' ' . $client->currency : undef,
        get_limit_expiration_date($db, $loginid, 'max_deposit_30day', 30),
        $audit->{max_deposit_30day}->{changed_stamp},
        $audit->{max_deposit_30day}->{prev_value},
        $audit->{max_deposit_30day}->{changed_by}) if $deposit_limit_enabled and exists $audit->{max_deposit_30day};
    $info .= make_row(
        'Maximum number of open positions',
        $self_exclusion->max_open_bets,
        get_limit_expiration_date($db, $loginid, 'max_open_bets', 1),
        $audit->{max_open_bets}->{changed_stamp},
        $audit->{max_open_bets}->{prev_value},
        $audit->{max_open_bets}->{changed_by}) if exists $audit->{max_open_bets};
    $info .= make_row(
        'Session duration limit',
        $self_exclusion->session_duration_limit ? $self_exclusion->session_duration_limit . ' minutes' : undef,
        get_limit_expiration_date($db, $loginid, 'session_duration_limit', 1),
        $audit->{session_duration_limit}->{changed_stamp},
        $audit->{session_duration_limit}->{prev_value},
        $audit->{session_duration_limit}->{changed_by}) if exists $audit->{session_duration_limit};
    $info .= make_row(
        'Website exclusion',
        $self_exclusion->exclude_until ? ''                                                       : undef,
        $self_exclusion->exclude_until ? Date::Utility->new($self_exclusion->exclude_until)->date : '',
        $audit->{exclude_until}->{changed_stamp},
        $audit->{exclude_until}->{prev_value} ? Date::Utility->new($audit->{exclude_until}->{prev_value})->date : undef,
        $audit->{exclude_until}->{changed_by}) if exists $audit->{exclude_until};
    $info .= make_row(
        'Website Timeout until',
        $self_exclusion->timeout_until ? ''                                                                           : undef,
        $self_exclusion->timeout_until ? Date::Utility->new($self_exclusion->timeout_until)->datetime_yyyymmdd_hhmmss : '',
        $audit->{timeout_until}->{changed_stamp},
        $audit->{timeout_until}->{prev_value} ? Date::Utility->new($audit->{timeout_until}->{prev_value})->datetime_yyyymmdd_hhmmss : undef,
        $audit->{timeout_until}->{changed_by}) if exists $audit->{timeout_until};

    if ($info) {
        $page .= '<p>Currently set values are:</p><table class="border alternate">' . $info . '</tbody></table><br>';
    }

    $page .= '<p>You may change it by editing the corresponding value:</p>';
}

$page .= $self_exclusion_form->build();
print $page;
code_exit_BO();
