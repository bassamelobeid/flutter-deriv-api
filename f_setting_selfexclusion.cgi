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
BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation("Setting Client Self Exclusion");

my $loginid = request()->param('loginid') || '';
Bar("Setting Client Self Exclusion");

my $client = eval { BOM::User::Client::get_instance({'loginid' => $loginid}) };
if (not $client) {
    print "Error: wrong loginid ($loginid) could not get client object";
    code_exit_BO();
}

# Not available for Virtual Accounts
if ($client->is_virtual) {
    print '<h1>Self-Exclusion Facilities</h1>';
    print '<p class="aligncenter">We\'re sorry but the Self Exclusion facility is not available for Virtual Accounts.</p>';
    code_exit_BO();
}

# some limits are not updatable in regulated landing companies
my $regulated_lc = $client->landing_company->is_eu;

my $broker = $client->broker;

my $self_exclusion_form = BOM::Backoffice::Form::get_self_exclusion_form({
    client          => $client,
    lang            => request()->language,
    restricted_only => 0
});

my $client_details_link = request()->url_for(
    "backoffice/f_clientloginid_edit.cgi",
    {
        broker  => $broker,
        loginID => $loginid
    });

my $db = $client->db->dbic;

my $page =
      "<h2> The Client loginid: <a href='$client_details_link'>"
    . encode_entities($loginid)
    . ' </a> self-exclusion settings are as follows. You may change it by editing the corresponding value.</h2>';

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
# to generate existing limits
if (my $self_exclusion = $client->get_self_exclusion) {
    my $info;
    $info .= '<tr><td><strong>Limit name</strong></td><td><strong>Limit value</strong></td><td><strong>Expiration date</strong></td></tr>';
    $info .= make_row(
        'Maximum account cash balance',
        $client->currency,
        $self_exclusion->max_balance,
        get_limit_expiration_date($db, $loginid, 'max_balance', 30)) if $self_exclusion->max_balance;
    $info .= make_row(
        'Daily turnover limit',
        $client->currency,
        $self_exclusion->max_turnover,
        get_limit_expiration_date($db, $loginid, 'max_turnover', 1)) if $self_exclusion->max_turnover;
    $info .=
        make_row('Daily limit on losses', $client->currency, $self_exclusion->max_losses, get_limit_expiration_date($db, $loginid, 'max_losses', 1))
        if $self_exclusion->max_losses;
    $info .= make_row(
        '7-Day turnover limit',
        $client->currency,
        $self_exclusion->max_7day_turnover,
        get_limit_expiration_date($db, $loginid, 'max_7day_turnover', 7)) if $self_exclusion->max_7day_turnover;
    $info .= make_row(
        '7-Day limit on losses',
        $client->currency,
        $self_exclusion->max_7day_losses,
        get_limit_expiration_date($db, $loginid, 'max_7day_losses', 7)) if $self_exclusion->max_7day_losses;
    $info .= make_row(
        '30-Day turnover limit',
        $client->currency,
        $self_exclusion->max_30day_turnover,
        get_limit_expiration_date($db, $loginid, 'max_30day_turnover', 30)) if $self_exclusion->max_30day_turnover;
    $info .= make_row(
        '30-Day limit on losses',
        $client->currency,
        $self_exclusion->max_30day_losses,
        get_limit_expiration_date($db, $loginid, 'max_30day_losses', 30)) if $self_exclusion->max_30day_losses;

    $info .=
        make_row('Maximum number of open positions', $self_exclusion->max_open_bets, '', get_limit_expiration_date($db, $loginid, 'max_open_bets', 1))
        if $self_exclusion->max_open_bets;

    $info .= make_row(
        'Session duration limit',
        $self_exclusion->session_duration_limit,
        'minutes', get_limit_expiration_date($db, $loginid, 'session_duration_limit', 1)) if $self_exclusion->session_duration_limit;

    $info .= make_row('Website exclusion', '', '', Date::Utility->new($self_exclusion->exclude_until)->date)
        if $self_exclusion->exclude_until;

    $info .= make_row('Website Timeout until', '', '', Date::Utility->new($self_exclusion->timeout_until)->datetime_yyyymmdd_hhmmss)
        if $self_exclusion->timeout_until;

    $info .= make_row(
        'Maximum deposit limit',
        $client->currency,
        $self_exclusion->max_deposit,
        Date::Utility->new($self_exclusion->max_deposit_end_date)->date
    ) if $self_exclusion->max_deposit;

    $info .= make_row('Maximum deposit limit start date', Date::Utility->new($self_exclusion->max_deposit_begin_date)->date, '', '')
        if $self_exclusion->max_deposit_begin_date;

    if ($info) {
        $page .= '<h3>Currently set values are:</h3><table cellspacing="0" cellpadding="5" border="1" class="GreyCandy">' . $info . '</table>';
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
$v = request()->param('MAXOPENPOS');
$client->set_exclusion->max_open_bets(looks_like_number($v) ? $v : undef);
$v = request()->param('DAILYTURNOVERLIMIT');
$client->set_exclusion->max_turnover(looks_like_number($v) ? $v : undef);
$v = request()->param('7DAYTURNOVERLIMIT');
$client->set_exclusion->max_7day_turnover(looks_like_number($v) ? $v : undef);
$v = request()->param('30DAYTURNOVERLIMIT');
$client->set_exclusion->max_30day_turnover(looks_like_number($v) ? $v : undef);
$v = request()->param('MAXCASHBAL');
$client->set_exclusion->max_balance(looks_like_number($v) ? $v : undef);
$v = request()->param('SESSIONDURATION');
$client->set_exclusion->session_duration_limit(looks_like_number($v) ? $v : undef);

unless ($regulated_lc) {
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
        $client->set_exclusion->max_deposit($form_max_deposit_amount);
        $client->set_exclusion->max_deposit_end_date($max_deposit_date->date);
        $client->set_exclusion->max_deposit_begin_date(Date::Utility->new->date);
    } else {
        $client->set_exclusion->max_deposit_end_date(undef);
        $client->set_exclusion->max_deposit_begin_date(undef);
        $client->set_exclusion->max_deposit(undef);
    }
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
        print "<p class=\"aligncenter\"><font color=red><b>WARNING: </b></font>Client's self-exclusion date cannot be changed</p>";
    }
}

my $timeout_until = request()->param('TIMEOUTUNTIL') || undef;
$timeout_until = Date::Utility->new($timeout_until)->epoch if $timeout_until;
$client->set_exclusion->timeout_until($timeout_until);

if ($client->save) {
    #print message inform Client everything is ok
    print "<p class=\"aligncenter\">Thank you. the client settings have been updated.</p>";
    print qq{<a href='$client_details_link'>&laquo; return to client details</a>};
} else {
    print "<p class=\"aligncenter\">Sorry, the client settings have not been updated, please try it again.</p>";
    warn("Error: cannot write to self_exclusion table $!");
}

=head2 get_limit_expiration_date

get limit name and find first modified date for current value, add number of days the
value is valid and return expiration date to be used in exclusion table

=over

=item * C<db> - required. Database handler object.

=item * C<loginid> - required. Client loginid.

=item * C<limit_name> - required. The name of limit we want to calculate expiration date for.

=item * C<added_day> - Number of day the data is valid for a certain limit. 0 if none provided.

=back

=cut

sub get_limit_expiration_date {
    my ($db, $loginid, $limit_name, $added_day) = @_;

    return undef unless ($db and $loginid and $limit_name);
    return undef
        unless any { $_ eq $limit_name }
    qw/max_balance max_turnover max_losses max_7day_turnover max_7day_losses max_30day_turnover max_30day_losses max_open_bets session_duration_limit/;

    my $latest_modified_date = $db->run(
        ping => sub {
            $_->selectrow_array('SELECT * FROM betonmarkets.get_self_exclusion_expiry_date(?,?)', undef, $loginid, $limit_name);
        });
    return undef if !defined $latest_modified_date;
    return Date::Utility->new($latest_modified_date)->plus_time_interval(($added_day // 0) . 'd')->date;
}

code_exit_BO;
