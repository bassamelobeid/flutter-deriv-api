#!/usr/bin/perl
package main;
use strict 'vars';
use open qw[ :encoding(UTF-8) ];

use LWP::UserAgent;
use Text::Trim;
use File::Copy;
use Locale::Country 'code2country';
use Data::Dumper;

use f_brokerincludeall;
use BOM::Platform::Runtime;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::Context;
use BOM::Platform::User;
use BOM::Platform::Client::IDAuthentication;
use BOM::Platform::Client::Utility;
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Platform::Client::Utility ();
use BOM::Platform::Sysinit         ();
use BOM::Platform::Client::DoughFlowClient;
use BOM::Platform::Helper::Doughflow qw( get_sportsbook );
use BOM::Database::Model::HandoffToken;
use BOM::Database::ClientDB;
use BOM::System::Config;
use BOM::Web::Form;

BOM::Platform::Sysinit::init();

my %input = %{request()->params};

PrintContentType();
my $language  = $input{l};
my $dbloc     = BOM::Platform::Runtime->instance->app_config->system->directory->db;
my $loginid   = trim(uc $input{loginID}) || die 'failed to pass loginID (note mixed case!)';
my $self_post = request()->url_for('backoffice/f_clientloginid_edit.cgi');
my $self_href = request()->url_for('backoffice/f_clientloginid_edit.cgi', {loginID => $loginid});

# given a bad-enough loginID, BrokerPresentation can die, leaving an unformatted screen..
# let the client-check offer a chance to retry.
eval { BrokerPresentation("$loginid CLIENT DETAILS") };

my $client = eval { BOM::Platform::Client->new({loginid => $loginid}) } || do {
    my $err = $@;
    print "<p>ERROR: Client [$loginid] not found.</p>";
    if ($err) {
        warn("Error: $err");
        print "<p>(Support: details in errorlog)</p>";
    }
    print qq[<form action="$self_post" method="post">
                Try Again: <input type="text" name="loginID" value="$loginid"></input>
              </form>];
    code_exit_BO();
};

my $broker = $client->broker;
my $staff  = BOM::Backoffice::Auth0::can_access(['CS']);
my $clerk  = BOM::Backoffice::Auth0::from_cookie()->{nickname};

# sync authentication status to Doughflow
if ($input{whattodo} eq 'sync_to_DF') {
    die "NO Doughflow for Virtual Client !!!" if ($client->is_virtual);

    my $df_client = BOM::Platform::Client::DoughFlowClient->new({'loginid' => $loginid});
    my $currency = $df_client->doughflow_currency;
    if (not $currency) {
        BOM::Platform::Context::template->process(
            'backoffice/client_edit_msg.tt',
            {
                message     => 'ERROR: Client never deposited before, no sync to Doughflow is allowed !!',
                error       => 1,
                self_url    => $self_href,
            },
        ) || die BOM::Platform::Context::template->error();
        code_exit_BO();
    }

    # create handoff token
    my $client_db = BOM::Database::ClientDB->new({
        client_loginid => $loginid,
    })->db;

    my $handoff_token = BOM::Database::Model::HandoffToken->new(
        db                 => $client_db,
        data_object_params => {
            key            => BOM::Database::Model::HandoffToken::generate_session_key,
            client_loginid => $loginid,
            expires        => time + 60,
        },
    );
    $handoff_token->save;

    my $doughflow_loc  = BOM::System::Config::third_party->{doughflow}->{location};
    my $doughflow_pass = BOM::System::Config::third_party->{doughflow}->{passcode};
    my $url            = $doughflow_loc . '/CreateCustomer.asp';

    # hit DF's CreateCustomer API
    my $ua = LWP::UserAgent->new(timeout => 60);
    $ua->ssl_opts(
        verify_hostname => 0,
        SSL_verify_mode => SSL_VERIFY_NONE
    );    #temporarily disable host verification as full ssl certificate chain is not available in doughflow.

    my $result = $ua->post(
        $url,
        $df_client->create_customer_property_bag({
                SecurePassCode => $doughflow_pass,
                Sportsbook     => get_sportsbook($broker, $currency),
                IP_Address     => '127.0.0.1',
                Password       => $handoff_token->key,
            }));
    if ($result->{'_content'} ne 'OK') {
        BOM::Platform::Context::template->process(
            'backoffice/client_edit_msg.tt',
            {
                message     => "FAILED syncing client authentication status to Doughflow, ERROR: $result->{_content}",
                error       => 1,
                self_url    => $self_href,
            },
        ) || die BOM::Platform::Context::template->error();
        code_exit_BO();
    }

    my $msg = Date::Utility->new->datetime . " sync client authentication status to Doughflow by clerk=$clerk $ENV{REMOTE_ADDR}, " .
            'loginid: '.$df_client->loginid.', Email: '.$df_client->Email.', Name: '.$df_client->CustName.', Profile: '.$df_client->Profile;
    BOM::System::AuditLog::log($msg, $loginid, $clerk);

    BOM::Platform::Context::template->process(
        'backoffice/client_edit_msg.tt',
        {
            message     => "Successfully syncing client authentication status to Doughflow",
            self_url    => $self_href,
        },
    ) || die BOM::Platform::Context::template->error();
    code_exit_BO();
}

# UPLOAD NEW ID DOC.
if ($input{whattodo} eq 'uploadID') {

    local $CGI::POST_MAX        = 1024 * 100 * 4;    # max 400K posts
    local $CGI::DISABLE_UPLOADS = 0;                 # enable uploads

    my $cgi          = new CGI;
    my $doctype      = $cgi->param('doctype');
    my $filetoupload = $cgi->param('FILE');
    my $docformat    = $cgi->param('docformat');
    my $expiration_date = $cgi->param('expiration_date');
    my $broker_code  = $cgi->param('broker');


    if (not $filetoupload) {
        print "<br /><p style=\"color:red; font-weight:bold;\">Error: You did not browse for a file to upload.</p><br />";
        code_exit_BO();
    }
    
    if ($doctype eq 'passport' && $expiration_date !~/\d{4}-\d{2}-\d{2}/ && ($broker_code eq 'MF'|| $broker_code eq 'MX')) {
        print "<br /><p style=\"color:red; font-weight:bold;\">Error: Missing or invalid date format entered - </p><br />";
        code_exit_BO();
    }
    
   if ($expiration_date ne '') {
        my ($current_date, $submitted_date);
        $current_date=Date::Utility->new();
        $submitted_date = Date::Utility->new($expiration_date);
        
        if($submitted_date->is_before($current_date)||$submitted_date->is_same_as($current_date)){
            print "<br /><p style=\"color:red; font-weight:bold;\">Error: Expiration date should be greater than current date </p><br />";
            code_exit_BO();
        }
            
    }

    my $newfilename = "$dbloc/clientIDscans/$broker/$loginid.$doctype." . (time()) . ".$docformat";

    if (not -d "$dbloc/clientIDscans/$broker") {
        system("mkdir -p $dbloc/clientIDscans/$broker");
    }

    copy($filetoupload, $newfilename) or die "[$0] could not copy uploaded file to $newfilename: $!";
    my $filesize = (stat $newfilename)[7];
    
    my $upload_submission={
        document_type              => $doctype,
        document_format            => $docformat,
        document_path              => $newfilename,
        authentication_method_code => 'ID_DOCUMENT',
        expiration_date            => $expiration_date
    };
    
    #needed because CR based submissions don't return a result when an empty string is submitted in expiration_date;
    if ($expiration_date eq ''){
        delete $upload_submission->{'expiration_date'};
    }
    
    $client->add_client_authentication_document($upload_submission);
    
    $client->save;
    
    print "<br /><p style=\"color:green; font-weight:bold;\">Ok! File $newfilename is uploaded (filesize $filesize).</p><br />";

    code_exit_BO();
}

# PERFORM ON-DEMAND ID CHECKS
if (my $check_str = $input{do_id_check}) {
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
        if (!grep(/^$input{'mrms'}$/, BOM::Web::Form::GetSalutations())) {
            print "<p style=\"color:red; font-weight:bold;\">ERROR ! MRMS field is invalid.</p></p>";
            code_exit_BO();
        }
    }

    # client promo_code related fields
    if (BOM::Backoffice::Auth0::has_authorisation(['Marketing'])) {

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
        if (my ($id) = $key =~ /^expiration_date_([0-9]+)$/) {
            my $val = $input{$key} || next CLIENT_KEY;
            my ($doc) = grep { $_->id eq $id } $client->client_authentication_document;    # Rose
            next CLIENT_KEY unless $doc;
            my $date = $val eq 'clear' ? undef : Date::Utility->new($val)->date_yyyymmdd;
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
        if ($key eq 'phone') {
            $client->phone($input{$key});
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

        if ($key eq 'client_authentication') {
            if ($input{$key} eq 'ADDRESS' or $input{$key} eq 'ID_DOCUMENT' or $input{$key} eq 'ID_192') {
                $client->set_authentication($input{$key})->status('pass');
            }
            if ($input{$key} eq 'CLEAR ALL') {
                foreach my $m (@{$client->client_authentication_method}) {
                    $m->delete;
                }
            }
        }
        if ($key eq 'myaffiliates_token'){
            # $client->myaffiliates_token_registered(1);
            $client->myaffiliates_token($input{$key}) if $input{$key};
        }
    }

    if (not $client->save) {
        print "<p style=\"color:red; font-weight:bold;\">ERROR : Could not update client details for client $loginid</p></p>";
        code_exit_BO();
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
    $prev_loginid = sprintf "$client_broker%0*d", $len, $number - $_;
    last if $prev_client = BOM::Platform::Client->new({loginid => $prev_loginid});
}
for (1 .. $attempts) {
    $next_loginid = sprintf "$client_broker%0*d", $len, $number + $_;
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

Bar("$loginid PAYMENT AGENT DETAILS");

# Show Payment-Agent details if this client is also a Payment Agent.
my $payment_agent = $client->payment_agent;
if ($payment_agent) {
    print '<table class="collapsed">';

    foreach my $column ($payment_agent->meta->columns) {
        my $value = $payment_agent->$column;
        print "<tr><td>$column</td><td>=</td><td>$value</td></tr>";
    }

    print '</table>';
}

if ($client->landing_company->allows_payment_agents) {
    print "<p><a href=\""
        . request()->url_for(
        'backoffice/f_setting_paymentagent.cgi',
        {
            broker   => $broker,
            loginid  => $loginid,
            whattodo => $payment_agent ? "show" : "create"
        }) . "\">$loginid payment agent details</a></p>";
} else {
    print '<p>Payment Agents are not available for this account.</p>';
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
            loginID => $link_loginid
        });
    $link_acc .= "<a href='$link_href'>$link_loginid</a></p></br>";
    print $link_acc;
}

my $user = BOM::Platform::User->new({ email => $client->email });

# show all loginids for user, include disabled acc
my @siblings = $user->clients(disabled_ok=>1);

if (@siblings > 1) {
    print "<p>Corresponding accounts: </p><ul>";
    foreach my $sibling (@siblings) {
        my $sibling_id = $sibling->loginid;
        next if ($sibling_id eq $client->loginid);
        my $link_href = request()->url_for(
            'backoffice/f_clientloginid_edit.cgi',
            {
                broker  => $sibling->broker_code,
                loginID => $sibling_id,
            });
        print "<li><a href='$link_href'>$sibling_id</a></li>";
    }
    print "</ul>";
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
    <input type="hidden" name="broker" value="$broker">
    <input type="hidden" name="loginID" value="$loginid">
    <input type="hidden" name="l" value="$language">];

print_client_details($client, $staff);

print qq{<input type=submit value="Save Client Details"></form>};

if (not $client->is_virtual) {
    Bar("Sync Client Authentication Status to Doughflow");
    print qq{
        <p>Click to sync client authentication status to Doughflow: </p>
        <form action="$self_post" method="post">
            <input type="hidden" name="whattodo" value="sync_to_DF">
            <input type="hidden" name="broker" value="$broker">
            <input type="hidden" name="loginID" value="$loginid">
            <input type="hidden" name="l" value="$language">
            <input type="submit" value="Sync now !!">
        </form>
    };
}

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
	Expiration date:<input type="text" size=10 name="expiration_date"><i> format YYYY-MM-DD </i>
	<input type=submit value="Upload new ID doc.">
</form>
};

my $financial_assessment = $client->financial_assessment();
if ($financial_assessment) {
    my $user_data_json = $financial_assessment->data;
    my $is_professional = $financial_assessment->is_professional ? 'yes': 'no';
    Bar("Financial Assessment");
    print qq{<table class="collapsed">
        <tr><td>User Data</td><td><textarea rows=10 cols=150>$user_data_json</textarea></td></tr>
        <tr><td></td><td></td></tr>
        <tr><td>Is professional</td><td>$is_professional</td></tr>
        </table>
    };
}

Bar($user->email . " Login history");
print '<div><br/>';
my $limit = 200;
my $login_history = $user->find_login_history(
    sort_by => 'history_date desc',
    limit   => $limit
);

if (@$login_history == 0) {
    print qq{<p>There is no login history</p>};
} else {
    print qq{<p color="red">Showing last $limit logins only</p>} if @$login_history > $limit;
    print qq{<table class="collapsed">};
    foreach my $login (reverse @$login_history) {
        my $date        = $login->history_date->strftime('%F %T');
        my $action      = $login->action;
        my $status      = $login->successful ? 'ok' : 'failed';
        my $environment = $login->environment;
        print qq{<tr><td width='150'>$date UTC</td><td>$action</td><td>$status</td><td>$environment</td></tr>};
    }
    print qq{</table>};
}
print '</div>';

# to be removed soon, no more login history based on loginid
Bar("$loginid Login history");
print '<div><br/>';
my $loglim = 200;
my $logins = $client->find_login_history(
    sort_by => 'login_date desc',
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
