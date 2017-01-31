#!/etc/rmg/bin/perl
package main;
use strict 'vars';
use open qw[ :encoding(UTF-8) ];

use LWP::UserAgent;
use Text::Trim;
use File::Copy;
use Locale::Country 'code2country';
use Data::Dumper;
use HTML::Entities;

use Brands;
use f_brokerincludeall;
use BOM::Platform::Runtime;
use BOM::Backoffice::Request qw(request);
use BOM::Platform::User;
use BOM::Platform::Client::IDAuthentication;
use BOM::Platform::Client::Utility;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Platform::Client::Utility ();
use BOM::Backoffice::Sysinit       ();
use BOM::Platform::Client::DoughFlowClient;
use BOM::Platform::Doughflow qw( get_sportsbook );
use BOM::Database::Model::HandoffToken;
use BOM::Database::ClientDB;
use BOM::System::Config;
use BOM::Backoffice::FormAccounts;

BOM::Backoffice::Sysinit::init();

my %input = %{request()->params};

PrintContentType();
my $dbloc   = BOM::Platform::Runtime->instance->app_config->system->directory->db;
my $loginid = $input{loginID};
if (not $loginid) { print "<p> Empty loginID.</p>"; code_exit_BO(); }
$loginid = trim(uc $loginid);
my $encoded_loginid = encode_entities($loginid);
my $self_post       = request()->url_for('backoffice/f_clientloginid_edit.cgi');
my $self_href       = request()->url_for('backoffice/f_clientloginid_edit.cgi', {loginID => $loginid});

# given a bad-enough loginID, BrokerPresentation can die, leaving an unformatted screen..
# let the client-check offer a chance to retry.
eval { BrokerPresentation("$encoded_loginid CLIENT DETAILS") };

my $client = eval { Client::Account->new({loginid => $loginid}) } || do {
    my $err = $@;
    print "<p>ERROR: Client [$encoded_loginid] not found.</p>";
    if ($err) {
        warn("Error: $err");
        print "<p>(Support: details in errorlog)</p>";
    }
    print qq[<form action="$self_post" method="post">
                Try Again: <input type="text" name="loginID" value="$encoded_loginid"></input>
              </form>];
    code_exit_BO();
};

my $broker         = $client->broker;
my $encoded_broker = encode_entities($broker);
my $staff          = BOM::Backoffice::Auth0::can_access(['CS']);
my $clerk          = BOM::Backoffice::Auth0::from_cookie()->{nickname};

# sync authentication status to Doughflow
if ($input{whattodo} eq 'sync_to_DF') {
    die "NO Doughflow for Virtual Client !!!" if ($client->is_virtual);

    my $df_client = BOM::Platform::Client::DoughFlowClient->new({'loginid' => $loginid});
    my $currency = $df_client->doughflow_currency;
    if (not $currency) {
        BOM::Backoffice::Request::template->process(
            'backoffice/client_edit_msg.tt',
            {
                message  => 'ERROR: Client never deposited before, no sync to Doughflow is allowed !!',
                error    => 1,
                self_url => $self_href,
            },
        ) || die BOM::Backoffice::Request::template->error();
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
        BOM::Backoffice::Request::template->process(
            'backoffice/client_edit_msg.tt',
            {
                message  => "FAILED syncing client authentication status to Doughflow, ERROR: $result->{_content}",
                error    => 1,
                self_url => $self_href,
            },
        ) || die BOM::Backoffice::Request::template->error();
        code_exit_BO();
    }

    my $msg =
          Date::Utility->new->datetime
        . " sync client authentication status to Doughflow by clerk=$clerk $ENV{REMOTE_ADDR}, "
        . 'loginid: '
        . $df_client->loginid
        . ', Email: '
        . $df_client->Email
        . ', Name: '
        . $df_client->CustName
        . ', Profile: '
        . $df_client->Profile;
    BOM::System::AuditLog::log($msg, $loginid, $clerk);

    BOM::Backoffice::Request::template->process(
        'backoffice/client_edit_msg.tt',
        {
            message  => "Successfully syncing client authentication status to Doughflow",
            self_url => $self_href,
        },
    ) || die BOM::Backoffice::Request::template->error();
    code_exit_BO();
}

# UPLOAD NEW ID DOC.
if ($input{whattodo} eq 'uploadID') {

    local $CGI::POST_MAX        = 1024 * 1600;    # max 1600K posts
    local $CGI::DISABLE_UPLOADS = 0;              # enable uploads

    my $cgi            = new CGI;
    my $broker_code    = $cgi->param('broker');
    my $docnationality = $cgi->param('docnationality');
    my $result         = "";
    my $used_doctypes  = {};                              #we need to keep list of used doctypes to provide for them uniq filenames
    foreach my $i (1 .. 4) {
        my $doctype         = $cgi->param('doctype_' . $i);
        my $filetoupload    = $cgi->param('FILE_' . $i);
        my $docformat       = $cgi->param('docformat_' . $i);
        my $expiration_date = $cgi->param('expiration_date_' . $i);
        my $comments        = substr(encode_entities($cgi->param('comments_' . $i)), 0, 255);

        if (not $filetoupload) {
            $result .= "<br /><p style=\"color:red; font-weight:bold;\">Error: You did not browse for a file to upload.</p><br />"
                if ($i == 1);
            next;
        }

        if ($doctype =~ /passport|proofid|driverslicense/ && $expiration_date !~ /\d{4}-\d{2}-\d{2}/) {
            $result .= "<br /><p style=\"color:red; font-weight:bold;\">Error: File $i: Missing or invalid date format entered - </p><br />";
            next;
        }

        if ($expiration_date ne '') {
            my ($current_date, $submitted_date);
            $current_date   = Date::Utility->new();
            $submitted_date = Date::Utility->new($expiration_date);

            if ($submitted_date->is_before($current_date) || $submitted_date->is_same_as($current_date)) {
                $result .=
                    "<br /><p style=\"color:red; font-weight:bold;\">Error: File $i: Expiration date should be greater than current date </p><br />";
                next;
            }

        }

        if ($doctype eq 'passport') {
            if ($docnationality && $docnationality =~ /[a-z]{2}/) {
                $client->citizen($docnationality);
            } else {
                $result .= "<br /><p style=\"color:red; font-weight:bold;\">Error: Please select correct nationality</p><br />";
                next;
            }
        }

        my $path = "$dbloc/clientIDscans/$broker";

        if (not -d $path) {
            system("mkdir -p $path");
        }

        # we use N seconds after current time, where N is number of same type documents uploaded before
        # we don't flag such files with anything different (like _1) for it not to affect any other legacy code
        my $time = time() + $used_doctypes->{$doctype}++;

        my $newfilename = "$path/$loginid.$doctype.$time.$docformat";
        copy($filetoupload, $newfilename) or die "[$0] could not copy uploaded file to $newfilename: $!";
        my $filesize = (stat $newfilename)[7];

        my $upload_submission = {
            document_type              => $doctype,
            document_format            => $docformat,
            document_path              => $newfilename,
            authentication_method_code => 'ID_DOCUMENT',
            expiration_date            => $expiration_date,
            comments                   => $comments,
        };

        #needed because CR based submissions don't return a result when an empty string is submitted in expiration_date;
        if ($expiration_date eq '') {
            delete $upload_submission->{'expiration_date'};
        }

        $client->add_client_authentication_document($upload_submission);

        $client->save;

        $result .= "<br /><p style=\"color:#eeee00; font-weight:bold;\">Ok! File $i: $newfilename is uploaded (filesize $filesize).</p><br />";
    }
    print $result;
}

# PERFORM ON-DEMAND ID CHECKS
if (my $check_str = $input{do_id_check}) {
    my $result;
    my $id_auth = BOM::Platform::Client::IDAuthentication->new(
        client        => $client,
        force_recheck => 1
    );
    for ($check_str) {
        $result = /ProveID/ ? $id_auth->_fetch_proveid() : die("unknown IDAuthentication method $_");
    }
    my $encoded_check_str = encode_entities($check_str);
    print qq[<p><b>"$encoded_check_str" completed</b></p>
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
        if (!grep(/^$input{'mrms'}$/, BOM::Backoffice::FormAccounts::GetSalutations())) {
            print "<p style=\"color:red; font-weight:bold;\">ERROR ! MRMS field is invalid.</p></p>";
            code_exit_BO();
        }
    }

    # client promo_code related fields
    if (BOM::Backoffice::Auth0::has_authorisation(['Marketing'])) {

        if (my $promo_code = uc $input{promo_code}) {
            my $encoded_promo_code = encode_entities($promo_code);
            my %pcargs             = (
                code   => $promo_code,
                broker => $broker
            );
            if (!BOM::Database::AutoGenerated::Rose::PromoCode->new(%pcargs)->load(speculative => 1)) {
                print "<p style=\"color:red; font-weight:bold;\">ERROR: invalid promocode $encoded_promo_code</p>";
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
        if (my ($id) = $key =~ /^comments_([0-9]+)$/) {
            my $val = $input{$key};
            my ($doc) = grep { $_->id eq $id } $client->client_authentication_document;    # Rose
            my $comments = substr(encode_entities($val), 0, 255);
            next CLIENT_KEY unless $doc;
            next CLIENT_KEY if $comments eq $doc->comments();
            unless (eval { $doc->comments($comments); 1 }) {
                my $err = $@;
                print qq{<p style="color:red">ERROR: Could not set comments for doc $id: $err</p>};
                code_exit_BO();
            }
            $doc->db($client->set_db('write'));
            $doc->save;
            next CLIENT_KEY;
        }
        if (my ($id) = $key =~ /^expiration_date_([0-9]+)$/) {
            my $val = $input{$key} || next CLIENT_KEY;
            my ($doc) = grep { $_->id eq $id } $client->client_authentication_document;    # Rose
            next CLIENT_KEY unless $doc;
            my $date;
            if ($val ne 'clear') {
                $date = Date::Utility->new($val);
                next CLIENT_KEY if $date->is_same_as(Date::Utility->new($doc->expiration_date));
                $date = $date->date_yyyymmdd;
            }
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
            if ($input{$key} =~ /^(|[1-9](\d+)?)$/) {
                $client->custom_max_acbal($input{$key});
                next CLIENT_KEY;
            } else {
                print qq{<p style="color:red">ERROR: Invalid max account balance, minimum value is 1 and it can be integer only</p>};
                code_exit_BO();
            }
        }
        if ($key eq 'custom_max_daily_turnover') {
            if ($input{$key} =~ /^(|[1-9](\d+)?)$/) {
                $client->custom_max_daily_turnover($input{$key});
                next CLIENT_KEY;
            } else {
                print qq{<p style="color:red">ERROR: Invalid daily turnover limit, minimum value is 1 and it can be integer only</p>};
                code_exit_BO();
            }
        }
        if ($key eq 'custom_max_payout') {
            if ($input{$key} =~ /^(|[1-9](\d+)?)$/) {
                $client->custom_max_payout($input{$key});
                next CLIENT_KEY;
            } else {
                print qq{<p style="color:red">ERROR: Invalid max payout, minimum value is 1 and it can be integer only</p>};
                code_exit_BO();
            }
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

        if ($key eq 'client_aml_risk_classification' and not $client->is_virtual) {
            $client->aml_risk_classification($input{$key});
        }

        if ($key eq 'client_authentication') {
            if ($input{$key} eq 'ID_DOCUMENT' or $input{$key} eq 'ID_NOTARIZED') {
                $client->set_authentication($input{$key})->status('pass');
            }
            if ($input{$key} eq 'CLEAR_ALL') {
                foreach my $m (@{$client->client_authentication_method}) {
                    $m->delete;
                }
            }
        }
        if ($key eq 'myaffiliates_token') {
            # $client->myaffiliates_token_registered(1);
            $client->myaffiliates_token($input{$key}) if $input{$key};
        }

        $client->allow_omnibus($input{allow_omnibus});
    }

    if (not $client->save) {
        print "<p style=\"color:red; font-weight:bold;\">ERROR : Could not update client details for client $encoded_loginid</p></p>";
        code_exit_BO();
    }

    print "<p style=\"color:#eeee00; font-weight:bold;\">Client details saved</p>";
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
    last if $prev_client = Client::Account->new({loginid => $prev_loginid});
}
for (1 .. $attempts) {
    $next_loginid = sprintf "$client_broker%0*d", $len, $number + $_;
    last if $next_client = Client::Account->new({loginid => $next_loginid});
}

my $encoded_prev_loginid = encode_entities($prev_loginid);
my $encoded_next_loginid = encode_entities($next_loginid);

if ($prev_client) {
    print qq{
        <div class="flat">
            <form action="$self_post" method="post">
                <input type="hidden" name="loginID" value="$encoded_prev_loginid">
                <input type="submit" value="Previous Client ($encoded_prev_loginid)">
            </form>
        </div>
    }
} else {
    print qq{<div class="flat">(No Client down to $encoded_prev_loginid)</div>};
}

if ($next_client) {
    print qq{
        <div class="flat">
            <form action="$self_post" method="post">
                <input type="hidden" name="loginID" value="$encoded_next_loginid">
                <input type="submit" value="Next client ($encoded_next_loginid)">
            </form>
        </div>
    }
} else {
    print qq{<div class="flat">(No client up to $encoded_next_loginid)</div>};
}

# view client's statement/portfolio/profit table
my $history_url     = request()->url_for('backoffice/f_manager_history.cgi');
my $statmnt_url     = request()->url_for('backoffice/f_manager_statement.cgi');
my $impersonate_url = request()->url_for('backoffice/client_impersonate.cgi');
print qq{<br/>
    <div class="flat">
    <form id="jumpToClient" action="$self_post" method="POST">
        View client files: <input type="text" size="12" maxlength="15" name="loginID" value="$encoded_loginid">&nbsp;&nbsp;
        <select name="jumpto" id="jumpToSelect"
                onchange="SetSelectOptionVisibility(this.options[this.selectedIndex].innerHTML)">
            <option value="$self_post"  >Details</option>
            <option value="$history_url">Statement</option>
            <option value="$statmnt_url">Portfolio</option>
        </select>
        &nbsp;&nbsp;<input type="submit" value="View">
        <input type="hidden" name="broker" value="$encoded_broker">
        <input type="hidden" name="currency" value="default">
        <div class="flat" id="StatementOption" style="display:none">
            <input type="checkbox" value="yes" name="depositswithdrawalsonly">Deposits and Withdrawals only
        </div>
    </form>
    </div>

    <div style="float: right">
    <form action="$history_url" method="POST">
    <input type="hidden" name="loginID" value="$encoded_loginid">
    <input type="submit" value="View $encoded_loginid statement">
    </form>
    </div>
<div  style="float: right">
<form action="$impersonate_url" method="post">
<input type='hidden' size=30 name="impersonate_loginid" value="$encoded_loginid">
<input type='hidden' name='broker' value='$encoded_broker'>
<input type="submit" value="Impersonate"></form>

</div>
};

Bar("$encoded_loginid STATUSES");
if (my $statuses = build_client_warning_message($loginid)) {
    print $statuses;
}
BOM::Backoffice::Request::template->process(
    'backoffice/account/untrusted_form.html.tt',
    {
        edit_url => request()->url_for('backoffice/untrusted_client_edit.cgi'),
        reasons  => [get_untrusted_client_reason()],
        broker   => $broker,
        clientid => $loginid,
        actions  => get_untrusted_types(),
    }) || die BOM::Backoffice::Request::template->error();

# Show Self-Exclusion link if this client has self-exclusion settings.
if ($client->self_exclusion) {
    Bar("$encoded_loginid SELF-EXCLUSION SETTINGS");
    print "$encoded_loginid has enabled <a id='self-exclusion' href=\""
        . request()->url_for(
        'backoffice/f_setting_selfexclusion.cgi',
        {
            broker  => $broker,
            loginid => $loginid
        }) . "\">self-exclusion</a> settings.";
}

Bar("$encoded_loginid PAYMENT AGENT DETAILS");

# Show Payment-Agent details if this client is also a Payment Agent.
my $payment_agent = $client->payment_agent;
if ($payment_agent) {
    print '<table class="collapsed">';

    foreach my $column ($payment_agent->meta->columns) {
        my $value = $payment_agent->$column;
        print "<tr><td>$column</td><td>=</td><td>" . encode_entities($value) . "</td></tr>";
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
        }) . "\">$encoded_loginid payment agent details</a></p>";
} else {
    print '<p>Payment Agents are not available for this account.</p>';
}

my $statuses = join '/', map { uc $_->status_code } $client->client_status;
my $name = $client->first_name;
$name .= ' ' if $name;
$name .= $client->last_name;
my $client_info = sprintf "%s %s%s", $client->loginid, ($name || '?'), ($statuses ? " [$statuses]" : '');
Bar("CLIENT " . encode_entities($client_info));

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
    $link_acc .= "<a href='$link_href'>" . encode_entities($link_loginid) . "</a></p></br>";
    print $link_acc;
}

my $user = BOM::Platform::User->new({email => $client->email});
my @siblings = $user->clients(disabled_ok => 1);
my @mt_logins = $user->mt5_logins;

if (@siblings > 1 or @mt_logins > 0) {
    print "<p>Corresponding accounts: </p><ul>";

    # show all BOM loginids for user, include disabled acc
    foreach my $sibling (@siblings) {
        my $sibling_id = $sibling->loginid;
        next if ($sibling_id eq $client->loginid);
        my $link_href = request()->url_for(
            'backoffice/f_clientloginid_edit.cgi',
            {
                broker  => $sibling->broker_code,
                loginID => $sibling_id,
            });
        print "<li><a href='$link_href'>" . encode_entities($sibling_id) . "</a></li>";
    }

    # show MT5 a/c
    foreach my $mt_ac (@mt_logins) {
        print "<li>" . encode_entities($mt_ac) . "</li>";
    }

    print "</ul>";
}

my $log_args = {
    broker   => $broker,
    category => 'client_details',
    loginid  => $loginid
};
my $new_log_href = request()->url_for('backoffice/show_audit_trail.cgi', $log_args);
print qq{<p>Click for <a href="$new_log_href">history of changes</a> to $encoded_loginid</p>};

print qq[<form action="$self_post" method="POST">
    <input type="submit" value="Save Client Details">
    <input type="hidden" name="broker" value="$encoded_broker">
    <input type="hidden" name="loginID" value="$encoded_loginid">];

print_client_details($client, $staff);

print qq{<input type=submit value="Save Client Details"></form>};

if (not $client->is_virtual) {
    Bar("Sync Client Authentication Status to Doughflow");
    print qq{
        <p>Click to sync client authentication status to Doughflow: </p>
        <form action="$self_post" method="post">
            <input type="hidden" name="whattodo" value="sync_to_DF">
            <input type="hidden" name="broker" value="$encoded_broker">
            <input type="hidden" name="loginID" value="$encoded_loginid">
            <input type="submit" value="Sync now !!">
        </form>
    };
}

Bar("Email Consent");
print '<br/>';
print 'Email consent for marketing: ' . ($user->email_consent ? 'Yes' : 'No');
print '<br/><br/>';

#upload new ID doc
Bar("Upload new ID document");
BOM::Backoffice::Request::template->process(
    'backoffice/client_edit_upload_doc.html.tt',
    {
        self_post => $self_post,
        broker    => $encoded_broker,
        loginid   => $encoded_loginid,
        countries => Brands->new(name => request()->brand)->countries_instance->countries,
    });

my $financial_assessment = $client->financial_assessment();
if ($financial_assessment) {
    my $user_data_json = $financial_assessment->data;
    my $is_professional = $financial_assessment->is_professional ? 'yes' : 'no';
    Bar("Financial Assessment");
    print qq{<table class="collapsed">
        <tr><td>User Data</td><td><textarea rows=10 cols=150 id="financial_assessment_score">}
        . encode_entities($user_data_json) . qq{</textarea></td></tr>
        <tr><td></td><td><input id="format_financial_assessment_score" type="button" value="Format"/></td></tr>
        <tr><td>Is professional</td><td>$is_professional</td></tr>
        </table>
    };
}

Bar($user->email . " Login history");
print '<div><br/>';
my $limit         = 200;
my $login_history = $user->find_login_history(
    sort_by => 'history_date desc',
    limit   => $limit
);

BOM::Backoffice::Request::template->process(
    'backoffice/user_login_history.html.tt',
    {
        user    => $user,
        history => $login_history,
        limit   => $limit
    });

code_exit_BO();

1;
