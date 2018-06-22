#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;
no warnings 'uninitialized';    ## no critic (ProhibitNoWarnings) # TODO fix these warnings
use open qw[ :encoding(UTF-8) ];
use LWP::UserAgent;
use Text::Trim;
use File::Copy;
use HTML::Entities;
use IO::Socket::SSL qw( SSL_VERIFY_NONE );
use Try::Tiny;
use Digest::MD5;

use Brands;
use LandingCompany::Registry;

use f_brokerincludeall;

use BOM::User::Client;

use BOM::Config::Runtime;
use BOM::Backoffice::Request qw(request);
use BOM::User;
use BOM::Platform::Client::IDAuthentication;
use BOM::User::Utility;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit ();
use BOM::Platform::Client::DoughFlowClient;
use BOM::Platform::Doughflow qw( get_sportsbook );
use BOM::Database::Model::HandoffToken;
use BOM::Database::ClientDB;
use BOM::Config;
use BOM::Backoffice::FormAccounts;
use BOM::Database::Model::AccessToken;
use BOM::Backoffice::Config;
use BOM::Backoffice::Script::DocumentUpload;
use Finance::MIFIR::CONCAT qw(mifir_concat);
use BOM::Platform::Client::DocumentUpload;
use Media::Type::Simple;

use constant MAX_FILE_SIZE => 8 * 2**20;

BOM::Backoffice::Sysinit::init();

my %input = %{request()->params};

PrintContentType();

# /etc/mime.types should exist but just in case...
my $mts;
if (open my $mime_defs, '<', '/etc/mime.types') {
    $mts = Media::Type::Simple->new($mime_defs);
    close $mime_defs;
} else {
    warn "Can't open MIME types definition file: $!";
    $mts = Media::Type::Simple->new();
}

my $dbloc   = BOM::Config::Runtime->instance->app_config->system->directory->db;
my $loginid = $input{loginID};
if (not $loginid) { print "<p> Empty loginID.</p>"; code_exit_BO(); }
$loginid = trim(uc $loginid);
my $encoded_loginid = encode_entities($loginid);
my $self_post       = request()->url_for('backoffice/f_clientloginid_edit.cgi');
my $self_href       = request()->url_for('backoffice/f_clientloginid_edit.cgi', {loginID => $loginid});

# given a bad-enough loginID, BrokerPresentation can die, leaving an unformatted screen..
# let the client-check offer a chance to retry.
eval { BrokerPresentation("$encoded_loginid CLIENT DETAILS") };    ## no critic (RequireCheckingReturnValueOfEval)

my $client = eval { BOM::User::Client->new({loginid => $loginid}) } || do {
    my $err = $@;
    print "<p>ERROR: Client [$encoded_loginid] not found.</p>";
    if ($err) {
        warn("Error: $err");
        print "<p>(Support: details in errorlog)</p>";
    }
    code_exit_BO(
        qq[<form action="$self_post" method="get">
                Try Again: <input type="text" name="loginID" value="$encoded_loginid"></input>
              </form>]
    );
};

my $user = $client->user;

my $broker         = $client->broker;
my $encoded_broker = encode_entities($broker);
my $clerk          = BOM::Backoffice::Auth0::from_cookie()->{nickname};

if ($broker eq 'MF') {
    if ($input{mifir_reset}) {
        $client->mifir_id('');
        $client->save;
    }
    if ($input{mifir_set_concat}) {
        use POSIX qw(locale_h);
        use locale;
        my $old_locale = setlocale(LC_CTYPE);
        setlocale(LC_CTYPE, 'C.UTF-8');
        $client->mifir_id(
            mifir_concat({
                    cc         => $client->citizen,
                    date       => $client->date_of_birth,
                    first_name => $client->first_name,
                    last_name  => $client->last_name,
                }));
        $client->save;
        setlocale(LC_CTYPE, $old_locale);
    }
}

# sync authentication status to Doughflow
if ($input{whattodo} eq 'sync_to_DF') {
    die "NO Doughflow for Virtual Client !!!" if ($client->is_virtual);

    my $df_client = BOM::Platform::Client::DoughFlowClient->new({'loginid' => $loginid});
    my $currency = $df_client->doughflow_currency;
    if (not $currency) {
        BOM::Backoffice::Request::template()->process(
            'backoffice/client_edit_msg.tt',
            {
                message  => 'ERROR: Client never deposited before, no sync to Doughflow is allowed !!',
                error    => 1,
                self_url => $self_href,
            },
        ) || die BOM::Backoffice::Request::template()->error();
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

    my $doughflow_loc  = BOM::Config::third_party()->{doughflow}->{request()->brand};
    my $doughflow_pass = BOM::Config::third_party()->{doughflow}->{passcode};
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
        BOM::Backoffice::Request::template()->process(
            'backoffice/client_edit_msg.tt',
            {
                message  => "FAILED syncing client authentication status to Doughflow, ERROR: $result->{_content}",
                error    => 1,
                self_url => $self_href,
            },
        ) || die BOM::Backoffice::Request::template()->error();
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
    BOM::User::AuditLog::log($msg, $loginid, $clerk);

    BOM::Backoffice::Request::template()->process(
        'backoffice/client_edit_msg.tt',
        {
            message  => "Successfully syncing client authentication status to Doughflow",
            self_url => $self_href,
        },
    ) || die BOM::Backoffice::Request::template()->error();
    code_exit_BO();
}

# UPLOAD NEW ID DOC.
if ($input{whattodo} eq 'uploadID') {

    local $CGI::POST_MAX        = 1024 * 1600;    # max 1600K posts
    local $CGI::DISABLE_UPLOADS = 0;              # enable uploads

    my $cgi            = CGI->new;
    my $docnationality = $cgi->param('docnationality');
    my $result         = "";

    foreach my $i (1 .. 4) {
        my $doctype         = $cgi->param('doctype_' . $i);
        my $filetoupload    = $cgi->upload('FILE_' . $i);
        my $page_type       = $cgi->param('page_type_' . $i);
        my $expiration_date = $cgi->param('expiration_date_' . $i);
        my $document_id     = substr(encode_entities($cgi->param('document_id_' . $i) . ''), 0, 30);
        my $comments        = substr(encode_entities($cgi->param('comments_' . $i) . ''), 0, 255);

        if (not $filetoupload) {
            $result .= "<br /><p style=\"color:red; font-weight:bold;\">Error: You did not browse for a file to upload.</p><br />"
                if ($i == 1);
            next;
        }

        if ($doctype =~ /passport|proofid|driverslicense/ && $document_id eq '') {
            $result .= "<br /><p style=\"color:red; font-weight:bold;\">Error: File $i: Missing document_id for $doctype</p><br />";
            next;
        }

        if ($doctype =~ /passport|proofid|driverslicense/ && $expiration_date eq '') {
            $result .= "<br /><p style=\"color:red; font-weight:bold;\">Error: File $i: Missing date for $doctype</p><br />";
            next;
        }

        if ($expiration_date ne '') {
            my ($current_date, $submitted_date, $error);
            $current_date = Date::Utility->new();
            try {
                $submitted_date = Date::Utility->new($expiration_date);
            }
            catch {
                $error = (split "\n", $_)[0];    #handle Date::Utility's confess() call
            };
            if ($error) {
                $result .=
                    "<br /><p style=\"color:red; font-weight:bold;\">Error: File $i: Expiration date($expiration_date) error: $error</p><br />";
                next;
            } elsif ($submitted_date->is_before($current_date) || $submitted_date->is_same_as($current_date)) {
                $result .=
                    "<br /><p style=\"color:red; font-weight:bold;\">Error: File $i: Expiration date should be greater than current date </p><br />";
                next;
            }

        }

        if ($broker eq 'JP') {
            $client->citizen($docnationality) if $docnationality and ($docnationality =~ /^[a-z]{2}$/i or $docnationality eq 'Unknown');
        } elsif ($doctype =~ /passport|proofid/) {    # citizenship may only be changed when uploading passport or proofid
            if ($docnationality and $docnationality =~ /^[a-z]{2}$/i) {
                $client->citizen($docnationality);
            } else {
                $result .= "<br /><p style=\"color:red; font-weight:bold;\">Error: Please select correct nationality</p><br />";
                next;
            }
        } elsif (!$client->citizen) {                 # client citizenship presents when uploading docs (for all broker codes)
            $result .=
                "<br /><p style=\"color:red; font-weight:bold;\">Error: Please update client citizenship before uploading documents.</p><br />";
            next;
        }

        unless ($client->get_db eq 'write') {
            $client->set_db('write');
        }

        my $error_occured;
        try {
            $client->_set_staff;
        }
        catch {
            $error_occured = $_;
        };

        die "Unable to set staff info, with error: $error_occured" if $error_occured;

        my $file_size = (stat($filetoupload))[7];
        if ($file_size > MAX_FILE_SIZE) {
            $result .=
                "<br /><p style=\"color:red; font-weight:bold;\">Error: File $i: Exceeds maximum file size (" . MAX_FILE_SIZE . " bytes).</p><br />";
            next;
        }

        my $file_checksum         = Digest::MD5->new->addfile($filetoupload)->hexdigest;
        my $abs_path_to_temp_file = $cgi->tmpFileName($filetoupload);
        my $mime_type             = $cgi->uploadInfo($filetoupload)->{'Content-Type'};
        my ($file_ext)            = $cgi->param('FILE_' . $i) =~ /\.([^.]+)$/;

        # try to get file extension from mime type, else get it from filename
        my $docformat = lc($mts->ext_from_type($mime_type) // $file_ext);

        my $query_result = BOM::Platform::Client::DocumentUpload::start_document_upload(
            client          => $client,
            doctype         => $doctype,
            docformat       => $docformat,
            file_checksum   => $file_checksum,
            expiration_date => $expiration_date,
            document_id     => $document_id
        );

        unless ($query_result->{file_id}) {
            $result .= "<br /><p style=\"color:red; font-weight:bold;\">Error: File $i: $query_result->{error}->{msg}</p><br />";
            next;
        }

        my $file_id = $query_result->{file_id};

        my $new_file_name = "$loginid.$doctype.$file_id";
        $new_file_name .= $page_type eq '' ? ".$docformat" : "_$page_type.$docformat";

        my $document_upload = BOM::Backoffice::Script::DocumentUpload->new(config => BOM::Backoffice::Config::config()->{document_auth_s3});

        my $checksum = $document_upload->upload($new_file_name, $abs_path_to_temp_file, $file_checksum)
            or die "Upload failed for $filetoupload";

        $query_result = BOM::Platform::Client::DocumentUpload::finish_document_upload(
            client    => $client,
            file_id   => $file_id,
            comments  => $comments,
            page_type => $page_type,
        );

        unless ($query_result->{file_id}) {
            $result .= "<br /><p style=\"color:red; font-weight:bold;\">Error: File $i: $query_result->{error}->{msg}</p><br />";
            next;
        } else {
            $result .= "<br /><p style=\"color:#eeee00; font-weight:bold;\">Ok! File $i: $new_file_name is uploaded.</p><br />";
        }
    }
    print $result;
    code_exit_BO(qq[<p><a href="$self_href">&laquo;Return to Client Details<a/></p>]);
}

# Disabe 2FA if theres is a request for that.
if ($input{whattodo} eq 'disable_2fa' and $user->is_totp_enabled) {
    $user->is_totp_enabled(0);
    $user->secret_key('');
    $user->save;

    print "<p style=\"color:#eeee00; font-weight:bold;\">2FA Disabled</p>";
    code_exit_BO(qq[<p><a href="$self_href">&laquo;Return to Client Details<a/></p>]);
}

# PERFORM ON-DEMAND ID CHECKS
if (my $check_str = $input{do_id_check}) {
    my $result;
    my $id_auth = BOM::Platform::Client::IDAuthentication->new(
        client        => $client,
        force_recheck => 1
    );
    for ($check_str) {
        $result = /ProveID/ ? $id_auth->do_proveid() : die("unknown IDAuthentication method $_");
    }
    my $encoded_check_str = encode_entities($check_str);
    code_exit_BO(
        qq[<p><b>"$encoded_check_str" completed</b></p>
             <p><a href="$self_href">&laquo;Return to Client Details<a/></p>]
    );
}

# SAVE DETAILS
if ($input{edit_client_loginid} =~ /^\D+\d+$/) {
    #error checks
    unless ($client->is_virtual) {
        foreach (qw/last_name first_name salutation/) {
            if (length($input{$_}) < 1) {
                code_exit_BO("<p style=\"color:red; font-weight:bold;\">ERROR ! $_ field appears incorrect or empty.</p></p>");
            }
        }
        if (!grep(/^$input{'salutation'}$/, BOM::Backoffice::FormAccounts::GetSalutations())) {    ## no critic (RequireBlockGrep)
            code_exit_BO("<p style=\"color:red; font-weight:bold;\">ERROR ! MRMS field is invalid.</p></p>");
        }
    }

    # client promo_code related fields
    if (BOM::Backoffice::Auth0::has_authorisation(['Marketing'])) {

        if (my $promo_code = uc $input{promo_code}) {
            if ((LandingCompany::Registry::get_currency_type($client->currency) // '') eq 'crypto') {
                code_exit_BO('<p style="color:red; font-weight:bold;">ERROR: Promo code cannot be added to crypto currency accounts</p>');
            } else {
                my $encoded_promo_code = encode_entities($promo_code);
                my %pcargs             = (
                    code   => $promo_code,
                    broker => $broker
                );
                if (!BOM::Database::AutoGenerated::Rose::PromoCode->new(%pcargs)->load(speculative => 1)) {
                    code_exit_BO("<p style=\"color:red; font-weight:bold;\">ERROR: invalid promocode $encoded_promo_code</p>");
                }
                # add or update client promo code
                $client->promo_code($promo_code);
                $client->promo_code_status($input{promo_code_status} || 'NOT_CLAIM');
            }
        } elsif ($client->promo_code) {
            $client->set_promotion->delete;
        }
    }

    $client->payment_agent_withdrawal_expiration_date($input{payment_agent_withdrawal_expiration_date} || undef);

    my @simple_updates = qw/last_name
        first_name
        phone
        secret_question
        is_vip
        citizen
        address_1
        address_2
        city
        state
        postcode
        residence
        place_of_birth
        restricted_ip_address
        cashier_setting_password
        salutation
        /;
    exists $input{$_} && $client->$_($input{$_}) for @simple_updates;

    # Handing the professional client status (For all existing clients)
    my $result = "";

    # Only allow CR and MF
    foreach my $existing_client (map { $user->clients_for_landing_company($_) } qw/costarica maltainvest/) {
        my $existing_client_loginid = encode_entities($existing_client->loginid);

        if ($input{professional_client}) {
            $existing_client->set_status('professional', $clerk, 'Mark as professional as requested');
            $existing_client->clr_status('professional_requested');
        } else {
            $existing_client->clr_status('professional');
        }

        if (not $existing_client->save) {
            $result .= "<p>Failed to update professional status of client: $existing_client_loginid</p>";
        }
    }

    # Print clients that were not updated
    print $result if $result;

    # Filter keys for tax residence
    my (@tax_residence_multiple, $tax_residence);
    if (ref $input{tax_residence} eq 'ARRAY') {
        @tax_residence_multiple = @{$input{tax_residence}};
    } else {
        @tax_residence_multiple = ($input{tax_residence});
    }
    $tax_residence = join(",", sort grep { length } @tax_residence_multiple);

    my @number_updates = qw/
        custom_max_acbal
        custom_max_daily_turnover
        custom_max_payout
        /;
    foreach my $key (@number_updates) {
        if ($input{$key} =~ /^(|[1-9](\d+)?)$/) {
            $client->$key($input{$key});
        } else {
            code_exit_BO(qq{<p style="color:red">ERROR: Invalid $key, minimum value is 1 and it can be integer only</p>});
        }
    }

    CLIENT_KEY:
    foreach my $key (keys %input) {
        if ($key eq 'dob_day') {
            my $date_of_birth;
            $date_of_birth = sprintf "%04d-%02d-%02d", $input{'dob_year'}, $input{'dob_month'}, $input{'dob_day'}
                if $input{'dob_day'} && $input{'dob_month'} && $input{'dob_year'};

            $client->date_of_birth($date_of_birth);
            next CLIENT_KEY;
        }

        if (my ($document_field, $id) = $key =~ /^(expiration_date|comments|document_id)_([0-9]+)$/) {
            my $val = encode_entities($input{$key} // '') || next CLIENT_KEY;
            my ($doc) = grep { $_->id eq $id } $client->client_authentication_document;    # Rose
            next CLIENT_KEY unless $doc;
            my $new_value;
            if ($document_field eq 'expiration_date') {
                try {
                    $new_value = Date::Utility->new($val)->date_yyyymmdd if $val ne 'clear';
                }
                catch {
                    my $err = (split "\n", $_)[0];                                         #handle Date::Utility's confess() call
                    print qq{<p style="color:red">ERROR: Could not parse $document_field for doc $id with $val: $err</p>};
                    next CLIENT_KEY;
                };
            } elsif ($document_field eq 'comments') {
                $new_value = substr($val, 0, 255);
            } elsif ($document_field eq 'document_id') {
                $new_value = substr($val, 0, 30);
            }
            next CLIENT_KEY if $new_value eq $doc->$document_field();
            my $set_success = try {
                $doc->$document_field($new_value);
                1;
            };
            if (not $set_success) {
                print qq{<p style="color:red">ERROR: Could not set $document_field for doc $id with $val: $_</p>};
                next CLIENT_KEY;
            }
            $doc->db($client->set_db('write'));
            $doc->save;
            next CLIENT_KEY;
        }
        if ($key eq 'secret_answer') {
            # algorithm provide different encrypted string from the same text based on some randomness
            # so we update this encrypted field only on value change - we don't want our trigger log trash

            my $secret_answer = BOM::User::Utility::decrypt_secret_answer($client->secret_answer);
            $secret_answer = Encode::decode("UTF-8", $secret_answer)
                unless (Encode::is_utf8($secret_answer));

            $client->secret_answer(BOM::User::Utility::encrypt_secret_answer($input{$key}))
                if ($input{$key} ne $secret_answer);

            next CLIENT_KEY;
        }

        if ($key eq 'age_verification') {
            if ($input{$key} eq 'yes') {
                $client->set_status('age_verification', $clerk, 'No specific reason.')
                    unless $client->get_status('age_verification');
            } else {
                $client->clr_status('age_verification');
            }
        }

        if ($key eq 'client_aml_risk_classification' and not $client->is_virtual) {
            $client->aml_risk_classification($input{$key});
        }

        if ($key eq 'client_authentication' and $input{$key}) {
            my $auth_method = $input{$key};

            # Remove existing status to make the auth methods mutually exclusive
            $_->delete for @{$client->client_authentication_method};

            $client->set_authentication('ID_NOTARIZED')->status('pass')        if $auth_method eq 'ID_NOTARIZED';
            $client->set_authentication('ID_DOCUMENT')->status('pass')         if $auth_method eq 'ID_DOCUMENT';
            $client->set_authentication('ID_DOCUMENT')->status('needs_action') if $auth_method eq 'NEEDS_ACTION';
        }

        if ($key eq 'myaffiliates_token' and $input{$key}) {
            $client->myaffiliates_token($input{$key});
        }

        if ($input{mifir_id} and $client->mifir_id eq '' and $broker eq 'MF') {
            code_exit_BO(
                "<p style=\"color:red; font-weight:bold;\">ERROR : Could not update client details for client $encoded_loginid: MIFIR_ID line too long</p>"
            ) if (length($input{mifir_id}) > 35);
            $client->mifir_id($input{mifir_id});
        }

        if ($key eq 'tax_residence') {
            code_exit_BO("<p style=\"color:red; font-weight:bold;\">Tax residence cannot be set empty if value already exists</p>")
                if ($client->tax_residence and not $tax_residence);
            $client->tax_residence($tax_residence);
        }

        if ($key eq 'tax_identification_number') {
            code_exit_BO("<p style=\"color:red; font-weight:bold;\">Tax residence cannot be set empty if value already exists</p>")
                if ($client->tax_identification_number and not $input{tax_identification_number});
            $client->tax_identification_number($input{tax_identification_number});
        }
    }

    if (not $client->save) {
        code_exit_BO("<p style=\"color:red; font-weight:bold;\">ERROR : Could not update client details for client $encoded_loginid</p></p>");
    }

    print "<p style=\"color:#eeee00; font-weight:bold;\">Client details saved</p>";
    code_exit_BO(qq[<p><a href="$self_href">&laquo;Return to Client Details<a/></p>]);
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
    last if $prev_client = BOM::User::Client->new({loginid => $prev_loginid});
}

for (1 .. $attempts) {
    $next_loginid = sprintf "$client_broker%0*d", $len, $number + $_;
    last if $next_client = BOM::User::Client->new({loginid => $next_loginid});
}

my $encoded_prev_loginid = encode_entities($prev_loginid);
my $encoded_next_loginid = encode_entities($next_loginid);

if ($prev_client) {
    print qq{
        <div class="flat">
            <form action="$self_post" method="get">
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
            <form action="$self_post" method="get">
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
my $risk_report_url = request()->url_for('backoffice/client_risk_report.cgi');
print qq{<br/>
    <div class="flat">
    <form action="$self_post" method="get">
        <input type="text" size="15" maxlength="15" name="loginID" value="$encoded_loginid">
    </form>
    </div>

    <div class="flat">
    <form action="$risk_report_url" method="get">
    <input type="hidden" name="loginid" value="$encoded_loginid">
    <input type="submit" name="action" value="show risk report">
    </form>
    </div>

    <div class="flat">
    <form action="$statmnt_url" method="get">
        <input type="hidden" name="loginID" value="$encoded_loginid">
        <input type="submit" value="View $encoded_loginid Portfolio">
        <input type="hidden" name="broker" value="$encoded_broker">
        <input type="hidden" name="currency" value="default">
    </form>
    </div>
    <div class="flat">
    <form action="$history_url" method="get">
    <input type="hidden" name="loginID" value="$encoded_loginid">
    <input type="submit" value="View $encoded_loginid statement">
    <input type="checkbox" value="yes" name="depositswithdrawalsonly">Deposits and Withdrawals only
    </form>
    </div>

<div  style="float: right">
<form action="$impersonate_url" method="get">
<input type='hidden' size=30 name="impersonate_loginid" value="$encoded_loginid">
<input type='hidden' name='broker' value='$encoded_broker'>
<input type="submit" value="Impersonate"></form>
</div>
};

Bar("$loginid STATUSES");
if (my $statuses = build_client_warning_message($loginid)) {
    print $statuses;
}
BOM::Backoffice::Request::template()->process(
    'backoffice/account/untrusted_form.html.tt',
    {
        edit_url => request()->url_for('backoffice/untrusted_client_edit.cgi'),
        reasons  => get_untrusted_client_reason(),
        broker   => $broker,
        clientid => $loginid,
        actions  => get_untrusted_types(),
    }) || die BOM::Backoffice::Request::template()->error();

# Show Self-Exclusion link
Bar("$loginid SELF-EXCLUSION SETTINGS");
print "Configure <a id='self-exclusion' href=\""
    . request()->url_for(
    'backoffice/f_setting_selfexclusion.cgi',
    {
        broker  => $broker,
        loginid => $loginid
    }) . "\">self-exclusion</a> settings for $encoded_loginid.";

Bar("$loginid PAYMENT AGENT DETAILS");

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
Bar("CLIENT " . $client_info);

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

my $siblings;
if ($user) {
    $siblings = $user->bom_loginid_details;
    my @mt_logins = sort map { $_->loginid } grep { $_->loginid =~ /^MT\d+$/ } $user->loginid;

    if (%$siblings or @mt_logins > 0) {
        print "<p>Corresponding accounts: </p><ul>";

        # show all BOM loginids for user, include disabled acc
        foreach my $lid (sort keys %$siblings) {
            next if ($lid eq $client->loginid);
            my $link_href = request()->url_for(
                'backoffice/f_clientloginid_edit.cgi',
                {
                    broker  => $siblings->{$lid}->{broker_code},
                    loginID => $lid,
                });
            print "<li><a href='$link_href'>" . encode_entities($lid) . "</a></li>";
        }

        # show MT5 a/c
        foreach my $mt_ac (@mt_logins) {
            print "<li>" . encode_entities($mt_ac) . "</li>";
        }

        print "</ul>";
    }
}

my $log_args = {
    broker   => $broker,
    category => 'client_details',
    loginid  => $loginid
};
my $new_log_href = request()->url_for('backoffice/show_audit_trail.cgi', $log_args);
print qq{<p>Click for <a href="$new_log_href">history of changes</a> to $encoded_loginid</p>};

print qq[<form action="$self_post" method="get">
    <input type="submit" value="Save Client Details">
    <input type="hidden" name="broker" value="$encoded_broker">
    <input type="hidden" name="loginID" value="$encoded_loginid">];

print_client_details($client);

print qq{<input type=submit value="Save Client Details"></form>};

if (not $client->is_virtual) {
    Bar("Sync Client Authentication Status to Doughflow");
    print qq{
        <p>Click to sync client authentication status to Doughflow: </p>
        <form action="$self_post" method="get">
            <input type="hidden" name="whattodo" value="sync_to_DF">
            <input type="hidden" name="broker" value="$encoded_broker">
            <input type="hidden" name="loginID" value="$encoded_loginid">
            <input type="submit" value="Sync now !!">
        </form>
    };
}

Bar("Two-Factor Authentication");
print 'Enabled : <b>' . ($user->is_totp_enabled ? 'Yes' : 'No') . '</b>';
print qq{
    <br/><br/>
    <form action="$self_post" method="get">
        <input type="hidden" name="whattodo" value="disable_2fa">
        <input type="hidden" name="broker" value="$encoded_broker">
        <input type="hidden" name="loginID" value="$encoded_loginid">
        <input type="submit" value = "Disable 2FA"/>
        <span style="color:red;">This will disable the 2FA feature. Only user can enable then.</span>
    </form>
} if $user->is_totp_enabled;

Bar("$loginid Tokens");
foreach my $l (sort keys %$siblings) {
    my $tokens = BOM::Database::Model::AccessToken->new->get_all_tokens_by_loginid($l);
    foreach my $t (@$tokens) {
        $t =~ /(.{4})$/;
        print "Access Token [" . $l . "]: $1 <br\>";
    }
}

Bar("Email Consent");
print '<br/>';
print 'Email consent for marketing: ' . ($user->email_consent ? 'Yes' : 'No');
print '<br/><br/>';

if (not $client->is_virtual) {
    #upload new ID doc
    Bar("Upload new ID document");
    BOM::Backoffice::Request::template()->process(
        'backoffice/client_edit_upload_doc.html.tt',
        {
            self_post => $self_post,
            broker    => $encoded_broker,
            loginid   => $encoded_loginid,
            countries => Brands->new(name => request()->brand)->countries_instance->countries,
        });
}

my $fa_score = $client->financial_assessment_score();
if (my $TE = $client->trading_experience()) {
    Bar("Trading Experience");
    print_fa_table($TE);
    print '<p>Trading experience score: ' . $fa_score->{trading_score} . '</p><br/>';
    print '<br/><p>CFD Score: ' . $fa_score->{cfd_score} . '</p>';
}
if (my $FI = $client->financial_information()) {
    Bar("Financial Information");
    print_fa_table($FI);
    print '<br/><p>Financial information score: ' . $fa_score->{financial_information_score} . '</p><br/>';
}

sub print_fa_table {
    my $section = shift;

    my @hdr = ('Question', 'Answer', 'Score');

    print '<br/><table style="width:100%;" border="1" class="sortable"><thead><tr>';
    print '<th scope="col">' . encode_entities($_) . '</th>' for @hdr;
    print '</thead><tbody>';
    print '<tr><td>' . $section->{$_}->{label} . '</td><td>' . $section->{$_}->{answer} . '</td><td>' . $section->{$_}->{score} . '</td></tr>'
        for keys $section;
    print '</tbody></table>';

    return undef;
}

Bar($user->email . " Login history");
print '<div><br/>';
my $limit         = 200;
my $login_history = $user->find_login_history(
    sort_by => 'history_date desc',
    limit   => $limit
);

BOM::Backoffice::Request::template()->process(
    'backoffice/user_login_history.html.tt',
    {
        user    => $user,
        history => $login_history,
        limit   => $limit
    });
code_exit_BO();

1;
