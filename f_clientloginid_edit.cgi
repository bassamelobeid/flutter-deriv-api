#!/usr/bin/perl
package main;
use strict 'vars';
use open qw[ :encoding(UTF-8) ];

use Text::Trim;
use File::Copy;
use Locale::Country 'code2country';
use Data::Dumper;

use f_brokerincludeall;
use BOM::Utility::Log4perl qw( get_logger );
use BOM::Platform::Runtime;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::Context;
use BOM::Platform::Client::IDAuthentication;
use BOM::Platform::Client::Utility;
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Platform::SessionCookie;
use BOM::Platform::Authorization;
use BOM::Platform::Client::Utility ();
use BOM::Platform::Sysinit         ();
use BOM::View::CGIForm;

BOM::Platform::Sysinit::init();

my %input = %{request()->params};

PrintContentType();
my $language  = $input{l};
my $dbloc     = BOM::Platform::Runtime->instance->app_config->system->directory->db;
my $logger    = get_logger();
my $loginid   = trim(uc $input{loginID}) || die 'failed to pass loginID (note mixed case!)';
my $self_post = request()->url_for('backoffice/f_clientloginid_edit.cgi');
my $self_href = request()->url_for('backoffice/f_clientloginid_edit.cgi', {loginID => $loginid});

if ($input{impersonate_user}) {
    my $token = BOM::Platform::Authorization->issue_token(
        client_id       => 1,
        expiration_time => time + 86400,
        login_id        => $loginid,
        scopes          => ['price', 'chart', 'trade'],
    );
    my $cookie = BOM::Platform::SessionCookie->new(
        impersonating => 1,
        loginid       => $loginid,
        token         => $token,
    );
    my $session_cookie = CGI::cookie(
        -name    => BOM::Platform::Runtime->instance->app_config->cgi->cookie_name->login,
        -value   => $cookie->value,
        -domain  => request()->cookie_domain,
        -secure  => 1,
        -path    => '/',
        -expires => '+30d',
    );

    my $lcookie = CGI::cookie(
        -name    => 'loginid',
        -value   => $loginid,
        -domain  => request()->cookie_domain,
        -secure  => 0,
        -path    => '/',
        -expires => time + 86400,
    );
    PrintContentType({'cookies' => [$session_cookie, $lcookie]});
    eval { BrokerPresentation("$loginid CLIENT DETAILS") };
    print '<font color=green><b>SUCCESS!</b></font></p>';
    print qq[You are impersonating $loginid on our <a href="/" target="impersonated">main web site<a/>.];

    code_exit_BO();
}

# given a bad-enough loginID, BrokerPresentation can die, leaving an unformatted screen..
# let the client-check offer a chance to retry.
eval { BrokerPresentation("$loginid CLIENT DETAILS") };

my $client = eval { BOM::Platform::Client->new({loginid => $loginid}) } || do {
    my $err = $@;
    print "<p>ERROR: Client [$loginid] not found.</p>";
    if ($err) {
        $logger->error($err);
        print "<p>(Support: details in errorlog)</p>";
    }
    print qq[<form action="$self_post" method="post">
                Try Again: <input type="text" name="loginID" value="$loginid"></input>
              </form>];
    code_exit_BO();
};

my $broker = request()->broker->code;
my $staff  = BOM::Platform::Auth0::can_access(['CS']);
my $clerk  = BOM::Platform::Auth0::from_cookie()->{nickname};

# UPLOAD NEW ID DOC.
if ($input{whattodo} eq 'uploadID') {

    local $CGI::POST_MAX        = 1024 * 100 * 4;    # max 400K posts
    local $CGI::DISABLE_UPLOADS = 0;                 # enable uploads

    my $cgi          = new CGI;
    my $doctype      = $cgi->param('doctype');
    my $filetoupload = $cgi->param('FILE');
    my $docformat    = $cgi->param('docformat');

    if (not $filetoupload) {
        print "<br /><p style=\"color:red; font-weight:bold;\">Error: You did not browse for a file to upload.</p><br />";
        code_exit_BO();
    }

    my $newfilename = "$dbloc/clientIDscans/$broker/$loginid.$doctype." . (time()) . ".$docformat";

    if (not -d "$dbloc/clientIDscans/$broker") {
        system("mkdir -p $dbloc/clientIDscans/$broker");
    }

    copy($filetoupload, $newfilename) or die "[$0] could not copy uploaded file to $newfilename: $!";
    my $filesize = (stat $newfilename)[7];

    # if no doc status, set pending..
    if (not $client->get_authentication('ID_DOCUMENT')) {
        $client->set_authentication('ID_DOCUMENT')->status('pending');
    }

    $client->add_client_authentication_document({    # Rose
        document_type              => $doctype,
        document_format            => $docformat,
        document_path              => $newfilename,
        authentication_method_code => 'ID_DOCUMENT',
    });

    $client->save;

    print "<br /><p style=\"color:green; font-weight:bold;\">Ok! File $newfilename is uploaded (filesize $filesize).</p><br />";

    code_exit_BO();
}

# PERFORM ON-DEMAND ID CHECKS
if (my $check_str = $input{do_id_check}) {
    $logger->info("doing a $check_str for $client");
    my $result;
    my $id_auth = BOM::Platform::Client::IDAuthentication->new(
        client        => $client,
        force_recheck => 1
    );
    for ($check_str) {
        $result =
              /CheckID/ ? $id_auth->_fetch_checkid()
            : /ProveID/ ? $id_auth->_fetch_proveid()
            :             die("unknown IDAuthentication method $_");
    }
    $logger->info("result: " . Dumper($result));
    print qq[<p><b>"$check_str" completed</b></p>
             <p><a href="$self_href">&laquo;Return to Client Details<a/></p>];
    code_exit_BO();
}

# SAVE DETAILS
if ($input{edit_client_loginid} =~ /^\D+\d+$/) {

    #error checks
    unless ($client->is_virtual) {
        if (length($input{'last_name'}) < 1) {
            print "<p style=\"color:red; font-weight:bold;\">ERROR ! LNAME field appears incorrect or empty.</p></p>";
            code_exit_BO();
        }
        if (length($input{'first_name'}) < 1) {
            print "<p style=\"color:red; font-weight:bold;\">ERROR ! FNAME field appears incorrect or empty.</p></p>";
            code_exit_BO();
        }
        if (length($input{'mrms'}) < 1) {
            print "<p style=\"color:red; font-weight:bold;\">ERROR ! MRMS field appears to be empty.</p></p>";
            code_exit_BO();
        }
        if (!grep(/^$input{'mrms'}$/, BOM::View::CGIForm::GetSalutations())) {
            print "<p style=\"color:red; font-weight:bold;\">ERROR ! MRMS field is invalid.</p></p>";
            code_exit_BO();
        }
    }
    if (length($input{'email'}) < 5) {
        print "<p style=\"color:red; font-weight:bold;\">ERROR ! EMAIL field appears incorrect or empty.</p></p>";
        code_exit_BO();
    }

    # new method is used here as we need to keep old values and then compare them to the changes
    my $client_old_email = $client->email;

    # client promo_code related fields
    if (BOM::Platform::Auth0::has_authorisation(['Marketing'])) {

        if (my $promo_code = uc $input{promo_code}) {

            my %pcargs = (
                code   => $promo_code,
                broker => $broker
            );
            if (!BOM::Database::AutoGenerated::Rose::PromoCode->new(%pcargs)->load(speculative => 1)) {
                print "<p style=\"color:red; font-weight:bold;\">ERROR: invalid promocode $promo_code</p>";
                code_exit_BO;
            }
            # add or update client promo code
            $client->promo_code($promo_code);
            $client->promo_code_status($input{promo_code_status} || 'NOT_CLAIM');

        } elsif ($client->promo_code) {
            $client->set_promotion->delete;
        }
    }

    $client->payment_agent_withdrawal_expiration_date($input{payment_agent_withdrawal_expiration_date} || undef);

    CLIENT_KEY:
    foreach my $key (keys %input) {

        if ($key eq 'mrms') {
            $client->salutation($input{$key});
            next CLIENT_KEY;
        }
        if ($key eq 'first_name') {
            $client->first_name($input{$key});
            next CLIENT_KEY;
        }
        if ($key eq 'last_name') {
            $client->last_name($input{$key});
            next CLIENT_KEY;
        }
        if ($key eq 'dob_day') {
            my $date_of_birth;
            if (    $input{'dob_day'}
                and $input{'dob_month'}
                and $input{'dob_year'})
            {
                my $day_number =
                    ($input{'dob_day'} < 10)
                    ? "0$input{'dob_day'}"
                    : $input{'dob_day'};
                $date_of_birth = $input{'dob_year'} . '-' . $input{'dob_month'} . '-' . $day_number;
            }

            $client->date_of_birth($date_of_birth);
            next CLIENT_KEY;
        }
        if ($key eq 'citizen') {
            $client->citizen($input{$key});
            next CLIENT_KEY;
        }
        if ($key eq 'address_1') {
            $client->address_1($input{$key});
            next CLIENT_KEY;
        }
        if ($key eq 'address_2') {
            $client->address_2($input{$key});
            next CLIENT_KEY;
        }
        if ($key eq 'city') {
            $client->city($input{$key});
            next CLIENT_KEY;
        }
        if ($key eq 'state') {
            $client->state($input{$key});
            next CLIENT_KEY;
        }
        if ($key eq 'postcode') {
            $client->postcode($input{$key});
            next CLIENT_KEY;
        }
        if ($key eq 'residence') {
            $client->residence($input{$key});
            next CLIENT_KEY;
        }
        if ($key eq 'small_timer') {
            $client->small_timer($input{$key});
            next CLIENT_KEY;
        }
        if (my ($id) = $key =~ /^expiration_date_([0-9]+)$/) {
            my $val = $input{$key} || next CLIENT_KEY;
            my ($doc) = grep { $_->id eq $id } $client->client_authentication_document;    # Rose
            next CLIENT_KEY unless $doc;
            my $date = $val eq 'clear' ? undef : BOM::Utility::Date->new($val)->date_yyyymmdd;
            unless (eval { $doc->expiration_date($date); 1 }) {
                my $err = $@;
                print qq{<p style="color:red">ERROR: Could not set expiry date for doc $id: $err</p>};
                code_exit_BO();
            }
            $doc->db($client->set_db('write'));
            $doc->save;
            next CLIENT_KEY;
        }
        if ($key eq 'custom_max_acbal') {
            $client->custom_max_acbal($input{$key});
            next CLIENT_KEY;
        }
        if ($key eq 'custom_max_daily_turnover') {
            $client->custom_max_daily_turnover($input{$key});
            next CLIENT_KEY;
        }
        if ($key eq 'custom_max_payout') {
            $client->custom_max_payout($input{$key});
            next CLIENT_KEY;
        }
        if ($key eq 'email') {
            $client->email($input{$key});
            next CLIENT_KEY;
        }
        if ($key eq 'phone') {
            $client->phone($input{$key});
            next CLIENT_KEY;
        }
        if ($key eq 'fax') {
            $client->fax($input{$key});
            next CLIENT_KEY;
        }
        if ($key eq 'secret_question') {
            $client->secret_question($input{$key});
            next CLIENT_KEY;
        }
        if ($key eq 'secret_answer') {
            $client->secret_answer(BOM::Platform::Client::Utility::encrypt_secret_answer($input{$key}));
            next CLIENT_KEY;
        }
        if ($key eq 'ip_security') {
            $client->restricted_ip_address($input{$key});
            next CLIENT_KEY;
        }
        if ($key eq 'cashier_lock_password') {
            $client->cashier_setting_password($input{$key});
            next CLIENT_KEY;
        }
        if ($key eq 'last_environment') {
            $client->latest_environment($input{$key});
            next CLIENT_KEY;
        }
        if ($key eq 'driving_license') {
            $client->driving_license($input{$key});
            next CLIENT_KEY;
        }
        if ($key eq 'is_vip') {
            $client->is_vip($input{$key});
            next CLIENT_KEY;
        }

        if ($key eq 'age_verification') {
            if ($input{$key} eq 'yes') {
                $client->set_status('age_verification', $clerk, 'No specific reason.');
            } else {
                $client->clr_status('age_verification');
            }
        }

        if ($key eq 'can_authenticate') {
            if ($input{$key} eq 'yes') {
                $client->set_status('can_authenticate', $clerk, 'No specific reason.');
            } else {
                $client->clr_status('can_authenticate');
            }
        }
    }

    if (not $client->save) {
        print "<p style=\"color:red; font-weight:bold;\">ERROR : Could not update client details for client $loginid</p></p>";
        code_exit_BO();
    }

    # change of email -> warn Client
    if (uc $client_old_email ne uc $client->email) {
        my $website_name  = BOM::Platform::Runtime->instance->website_list->get_by_broker_code($client->broker)->display_name;
        my $support_email = BOM::Platform::Context::request()->website->config->get('customer_support.email');
        $support_email = qq{"$website_name" <$support_email>};

        send_email({
                'from'             => $support_email,
                'to'               => $client_old_email,
                'subject'          => $loginid . ' - change in email address',
                'template_loginid' => $loginid,
                'message'          => [
                    localize(
                        'This is to confirm that your email address for your account [_1] on [_2] has been changed from [_3] to [_4]',
                        $loginid, $website_name, $client_old_email, $client->email
                    )
                ],
                'use_email_template' => 1,
            });
    }

    print '<p><b>SUCCESS!</b></p>';
    print qq[<a href="$self_href">&laquo;Return to Client Details<a/>];

    code_exit_BO();
}

Bar("NAVIGATION");

print qq[<style>
        div.flat { display: inline-block }
        table.collapsed { border-collapse: collapse }
        table.collapsed td { padding: 0px 8px 0px 4px }
    </style>
];

# find next and prev real clients but give up after a few tries in each direction.
my $attempts = 3;
my ($prev_client, $next_client, $prev_loginid, $next_loginid);
my $client_broker = $client->broker;
(my $number = $loginid) =~ s/$client_broker//;
my $len = length($number);
for (1 .. $attempts) {
    $prev_loginid = sprintf "$client_broker%0*d", $len, $number-$_;
    last if $prev_client = BOM::Platform::Client->new({loginid => $prev_loginid});
}
for (1 .. $attempts) {
    $next_loginid = sprintf "$client_broker%0*d", $len, $number+$_;
    last if $next_client = BOM::Platform::Client->new({loginid => $next_loginid});
}

if ($prev_client) {
    print qq{
        <div class="flat">
            <form action="$self_post" method="post">
                <input type="hidden" name="loginID" value="$prev_loginid">
                <input type="submit" value="Previous Client ($prev_client)">
            </form>
        </div>
    }
} else {
    print qq{<div class="flat">(No Client down to $prev_loginid)</div>};
}

if ($next_client) {
    print qq{
        <div class="flat">
            <form action="$self_post" method="post">
                <input type="hidden" name="loginID" value="$next_loginid">
                <input type="submit" value="Next client ($next_client)">
            </form>
        </div>
    }
} else {
    print qq{<div class="flat">(No client up to $next_loginid)</div>};
}

# view client's statement/portfolio/profit table
my $history_url = request()->url_for('backoffice/f_manager_history.cgi');
my $statmnt_url = request()->url_for('backoffice/f_manager_statement.cgi');
print qq{<br/>
    <div class="flat">
    <form id="jumpToClient" action="$self_post" method="POST">
        View client files: <input type="text" size="12" maxlength="15" name="loginID" value="$loginid">&nbsp;&nbsp;
        <select name="jumpto" id="jumpToSelect"
                onchange="SetSelectOptionVisibility(this.options[this.selectedIndex].innerHTML)">
            <option value="$self_post"  >Details</option>
            <option value="$history_url">Statement</option>
            <option value="$statmnt_url">Portfolio</option>
        </select>
        &nbsp;&nbsp;<input type="submit" value="View">
        <input type="hidden" name="broker" value="$broker">
        <input type="hidden" name="l" value="$language">
        <input type="hidden" name="currency" value="default">
        <div class="flat" id="StatementOption" style="display:none">
            <input type="checkbox" value="yes" name="depositswithdrawalsonly">Deposits and Withdrawals only
        </div>
    </form>
    </div>
};

if (my $statuses = build_client_warning_message($loginid)) {
    Bar("$loginid STATUSES");
    print $statuses;
}

# Show Self-Exclusion link if this client has self-exclusion settings.
if ($client->self_exclusion) {
    Bar("$loginid SELF-EXCLUSION SETTINGS");
    print "$loginid has enabled <a id='self-exclusion' href=\""
        . request()->url_for(
        'backoffice/f_setting_selfexclusion.cgi',
        {
            broker  => $broker,
            loginid => $loginid
        }) . "\">self-exclusion</a> settings.";
}

# Show Payment-Agent panel if this client is also a Payment Agent.
if (my $payment_agent = $client->payment_agent) {
    Bar("$loginid IS OR HAS APPLIED TO BECOME A PAYMENT AGENT");

    print '<table class="collapsed">';

    foreach my $column ($payment_agent->meta->columns) {
        my $value = $payment_agent->$column;
        print "<tr><td>$column</td><td>=</td><td>$value</td></tr>";
    }

    print '</table>';
    print "<p><a href=\""
        . request()->url_for(
        'backoffice/f_setting_paymentagent.cgi',
        {
            broker   => $broker,
            loginid  => $loginid,
            whattodo => "show"
        }) . "\">Edit $loginid payment agent details</a></p>";
}

Bar("CLIENT $client");

my ($link_acc, $link_loginid);
if ($client->comment =~ /move UK clients to \w+ \(from (\w+)\)/) {
    $link_loginid = $1;
    $link_acc     = "<p>UK account, previously moved from ";
} elsif ($client->comment =~ /move UK clients to \w+ \(to (\w+)\)/) {
    $link_loginid = $1;
    $link_acc     = "<p>UK account, has been moved to ";
}
if ($link_acc) {
    $link_loginid =~ /(\D+)\d+/;
    my $link_href = request()->url_for(
        'backoffice/f_clientloginid_edit.cgi',
        {
            broker  => $1,
            loginid => $link_loginid
        });
    $link_acc .= "<a href='$link_href'>$link_loginid</a></p></br>";
    print $link_acc;
}

my $log_args = {
    broker   => $broker,
    category => 'client_details',
    loginid  => $loginid
};
my $new_log_href = request()->url_for('backoffice/show_audit_trail.cgi', $log_args);
print qq{<p>Click for <a href="$new_log_href">history of changes</a> to $loginid</p>};

print qq[<form action="$self_post" method="POST">
    <input type="submit" value="Save Client Details">
    <input type="submit" name="impersonate_user" value="Impersonate">
    <input type="hidden" name="broker" value="$broker">
    <input type="hidden" name="loginID" value="$loginid">
    <input type="hidden" name="l" value="$language">];

print_client_details($client, $staff);

print qq{<input type=submit value="Save Client Details"></form>};

#upload new ID doc
Bar("Upload new ID document");
print qq{
<br /><form enctype="multipart/form-data" ACTION="$self_post" method="POST">
	<select name="doctype">
		<option value="passport">Proof of Identity</option>
		<option value="proofaddress">Proof of Address</option>
		<option value="notarised">Notarised Docs</option>
		<option value="driverslicense">Drivers License</option>
                <option value="experianproveid">192 check</option>
		<option value="other">Other</option>
	</select>
	<select name=docformat>
		<option>JPG</option>
		<option>JPEG</option>
		<option>GIF</option>
		<option>PNG</option>
		<option>TIF</option>
		<option>PDF</option>
		<option>PCX</option>
		<option>EFX</option>
		<option>JFX</option>
		<option>DOC</option>
		<option>TXT</option>
	</select>
	<input type="FILE" name="FILE">
	<input type=hidden name=whattodo value=uploadID>
	<input type=hidden name=broker value=$broker>
	<input type=hidden name=loginID value=$loginid>
	<input type=hidden name=l value=$language>
	<input type=submit value="Upload new ID doc.">
</form>
};

Bar("$loginid Login history");

print '<div><br/>';

my $loglim = 200;
my $logins = $client->find_login_history(
    sort_by => 'id desc',
    limit   => $loglim
);

if (@$logins == 0) {
    print qq{<p>There is no login history</p>};
} else {

    print qq{<p color="red">Showing last $loglim logins only</p>} if @$logins > $loglim;

    print qq{<table class="collapsed">};
    foreach my $login (reverse @$logins) {
        my $date        = $login->login_date->strftime('%F %T');
        my $status      = $login->login_successful ? 'ok' : 'failed';
        my $environment = $login->login_environment;
        if (length($environment) > 100) {
            substr($environment, 100) = '..';
        }
        print qq{<tr><td>$date UTC</td><td>$status</td><td>$environment</td></tr>};
    }
    print qq{</table>};
}

print '</div>';

code_exit_BO();

1;
