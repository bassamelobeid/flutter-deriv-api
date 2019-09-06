#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;
no warnings 'uninitialized';    ## no critic (ProhibitNoWarnings) # TODO fix these warnings
use open qw[ :encoding(UTF-8) ];
use Text::Trim;
use File::Copy;
use HTML::Entities;
use Try::Tiny;
use Digest::MD5;
use Media::Type::Simple;
use Date::Utility;
use List::UtilsBy qw(rev_sort_by);

use LandingCompany::Registry;
use Finance::MIFIR::CONCAT qw(mifir_concat);

use f_brokerincludeall;

use BOM::Config;
use BOM::Config::Runtime;
use BOM::User::Client;
use BOM::Config::RedisReplicated;
use BOM::Backoffice::Request qw(request);
use BOM::User;
use BOM::User::FinancialAssessment;
use BOM::Platform::Client::IDAuthentication;
use BOM::User::Utility;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit ();
use BOM::Platform::Client::DoughFlowClient;
use BOM::Platform::Doughflow qw( get_sportsbook );
use BOM::Platform::Event::Emitter;
use BOM::Database::ClientDB;
use BOM::Config;
use BOM::Backoffice::FormAccounts;
use BOM::Database::Model::AccessToken;
use BOM::Backoffice::Config;
use BOM::Database::DataMapper::Copier;
use BOM::Platform::S3Client;

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

my $well_formatted = $loginid =~ m/^[A-Z]{2,4}[\d]{4,10}$/;
my $client;
$client = try { return BOM::User::Client->new({loginid => $loginid}) } if $well_formatted;
my $error_message = $well_formatted ? "Client [$encoded_loginid] not found." : "Invalid loginid provided.";
code_exit_BO(
    qq[<p>ERROR: $error_message </p>
            <form action="$self_post" method="get">
                Try Again: <input type="text" name="loginID" value="$encoded_loginid"></input>
            </form>]
) unless $client;

my $user = $client->user;

my @user_clients;
push @user_clients, $client;
foreach my $lid ($user->bom_loginids) {
    next if ($lid eq $client->loginid);

    push @user_clients, BOM::User::Client->new({loginid => $lid});
}

my @mt_logins = sort grep { /^MT\d+$/ } $user->loginids;
my $is_virtual_only = (@user_clients == 1 and @mt_logins == 0 and $client->is_virtual);
my $broker          = $client->broker;
my $encoded_broker  = encode_entities($broker);
my $clerk           = BOM::Backoffice::Auth0::get_staffname();

if ($input{del_document_list}) {
    my $documents = $input{del_document_list};
    my @documents = ref $documents ? @$documents : ($documents);
    my $full_msg  = "";
    my $loginid   = "";
    my $client;

    for my $document (@documents) {
        # if the checkbox is checked and unchecked, the EventListener will still send input value as 0.
        # this line is to escape this case.
        next unless $document;
        my @tokens          = split(/\./, $document);
        my $current_loginid = $tokens[0];
        my ($doc_id)        = $tokens[2] =~ m{(\d+)};
        if ((not defined $client) or ($client->loginid ne $current_loginid)) {
            $client = BOM::User::Client::get_instance({loginid => $current_loginid});
        }
        if ($client) {
            $client->set_db('write');
            my ($doc) = $client->find_client_authentication_document(query => [id => $doc_id]);    # Rose
            if ($doc) {
                if ($doc->delete) {
                    $full_msg .= "<p style=\"color:#eeee00; font-weight:bold;\">SUCCESS - $document is deleted!</p>";
                } else {
                    $full_msg .= "<p style=\"color:red; font-weight:bold;\">ERROR: did not remove $document record from db</p>";
                }
            } else {
                $full_msg .= "<p style=\"color:red; font-weight:bold;\">ERROR: could not find $document record in db</p>";
            }

        } else {
            $full_msg .= "<p style=\"color:red; font-weight:bold;\">ERROR: with client login $loginid</p>";
        }
    }

    print $full_msg;
    code_exit_BO(qq[<p><a href="$self_href">&laquo;Return to Client Details<a/></p>]);
}

if ($broker eq 'MF') {
    if ($input{view_action} eq "mifir_reset") {
        $client->mifir_id('');
        $client->save;
    }
    if ($input{view_action} eq "mifir_set_concat") {
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
    my $error = sync_to_doughflow($client, $clerk);

    if ($error) {
        BOM::Backoffice::Request::template()->process(
            'backoffice/client_edit_msg.tt',
            {
                message  => $error,
                error    => 1,
                self_url => $self_href,
            },
        ) || die BOM::Backoffice::Request::template()->error();
        code_exit_BO();
    } else {
        BOM::Backoffice::Request::template()->process(
            'backoffice/client_edit_msg.tt',
            {
                message  => "Successfully syncing client authentication status to Doughflow",
                self_url => $self_href,
            },
        ) || die BOM::Backoffice::Request::template()->error();
        code_exit_BO();
    }
}

if ($input{whattodo} eq 'delete_copier_tokens') {
    my $copier_ids = request()->param('copier_ids');
    my $trader_ids = request()->param('trader_ids');
    $copier_ids = [$copier_ids] if ref($copier_ids) ne 'ARRAY';
    $trader_ids = [$trader_ids] if ref($trader_ids) ne 'ARRAY';
    my $db           = $client->db;
    my $delete_count = 0;
    $delete_count = _delete_copiers($copier_ids, 'copier', $loginid, $db) if defined $copier_ids->[0];
    $delete_count += _delete_copiers($trader_ids, 'trader', $loginid, $db) if defined $trader_ids->[0];

    BOM::Backoffice::Request::template()->process(
        'backoffice/client_edit_msg.tt',
        {
            message  => "deleted $delete_count copier, trader connections ",
            self_url => $self_href,
        },
    ) || die BOM::Backoffice::Request::template()->error();
    code_exit_BO();
}
# sync authentication status to MT5
if ($input{whattodo} eq 'sync_to_MT5') {
    BOM::Platform::Event::Emitter::emit('sync_user_to_MT5', {loginid => $loginid});
    my $msg = Date::Utility->new->datetime . " sync client information to MT5 is requested by clerk=$clerk $ENV{REMOTE_ADDR}";
    BOM::User::AuditLog::log($msg, $loginid, $clerk);

    BOM::Backoffice::Request::template()->process(
        'backoffice/client_edit_msg.tt',
        {
            message  => "Successfully requested syncing client information to MT5",
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

    my @futures;
    my $s3_client = BOM::Platform::S3Client->new(BOM::Config::s3()->{document_auth});
    foreach my $i (1 .. 4) {
        my $doctype         = $cgi->param('doctype_' . $i);
        my $filetoupload    = $cgi->upload('FILE_' . $i);
        my $page_type       = $cgi->param('page_type_' . $i);
        my $expiration_date = $cgi->param('expiration_date_' . $i);
        my $document_id     = $input{'document_id_' . $i} // '';
        my $comments        = $input{'comments_' . $i} // '';

        next unless $filetoupload;

        if ($docnationality and $docnationality =~ /^[a-z]{2}$/i) {
            $client->citizen($docnationality);
        }

        unless ($client->get_db eq 'write') {
            $client->set_db('write');
        }

        if (not $client->save) {
            print "<p style=\"color:red; font-weight:bold;\">Failed to save client citizenship.</p>";
            code_exit_BO(qq[<p><a href="$self_href">&laquo;Return to Client Details<a/></p>]);
        }

        my $file_checksum         = Digest::MD5->new->addfile($filetoupload)->hexdigest;
        my $abs_path_to_temp_file = $cgi->tmpFileName($filetoupload);
        my $mime_type             = $cgi->uploadInfo($filetoupload)->{'Content-Type'};
        my ($file_ext)            = $cgi->param('FILE_' . $i) =~ /\.([^.]+)$/;

        # try to get file extension from mime type, else get it from filename
        my $docformat = lc($mts->ext_from_type($mime_type) // $file_ext);

        my $err;
        my $upload_info;
        try {
            $upload_info = $client->db->dbic->run(
                ping => sub {
                    $_->selectrow_hashref(
                        'SELECT * FROM betonmarkets.start_document_upload(?, ?, ?, ?, ?, ?, ?, ?)',
                        undef, $loginid, $doctype, $docformat, $expiration_date || undef,
                        $document_id, $file_checksum, $comments, $page_type || '',
                    );
                });
            $err = 'Document already exists.' unless $upload_info;
        }
        catch {
            $err = $_;
        };

        if ($err) {
            $result .= "<br /><p style=\"color:red; font-weight:bold;\">Error Uploading File $i: $err</p><br />";
            next;
        }

        my ($file_id, $new_file_name) = @{$upload_info}{qw/file_id file_name/};

        my $future = $s3_client->upload($new_file_name, $abs_path_to_temp_file, $file_checksum)->then(
            sub {
                my $err;
                try {
                    my $finish_upload_result = $client->db->dbic->run(
                        ping => sub {
                            $_->selectrow_array('SELECT * FROM betonmarkets.finish_document_upload(?)', undef, $file_id);
                        });
                    $err = 'Db returned unexpected file id on finish' unless $finish_upload_result == $file_id;
                }
                catch {
                    $err = 'Document upload failed on finish';
                    warn $err . $_;
                };
                return Future->fail("Database Falure: " . $err) if $err;
                BOM::Platform::Event::Emitter::emit(
                    'document_upload',
                    {
                        loginid                    => $loginid,
                        file_id                    => $file_id,
                        uploaded_manually_by_staff => 1
                    });
                return Future->done();
            });
        $future->set_label($new_file_name);
        push @futures, $future;
    }

    Future->wait_all(@futures)->get;
    for my $f (@futures) {
        my $file_name = $f->label;
        if ($f->is_done) {
            $result .= "<br/><p style=\"color:#eeee00; font-weight:bold;\">Successfully uploaded $file_name</p><br/>";
        } elsif ($f->is_failed) {
            my $failure = $f->failure;
            $result .= "<br/><p style=\"color:red; font-weight:bold;\">Error Uploading Document $file_name: $failure. </p><br/>";
        }
    }
    print $result;
    code_exit_BO(qq[<p><a href="$self_href">&laquo;Return to Client Details<a/></p>]);
}

# Disabe 2FA if theres is a request for that.
if ($input{whattodo} eq 'disable_2fa' and $user->is_totp_enabled) {
    $user->update_totp_fields(
        is_totp_enabled => 0,
        secret_key      => ''
    );

    print "<p style=\"color:#eeee00; font-weight:bold;\">2FA Disabled</p>";
    code_exit_BO(qq[<p><a href="$self_href">&laquo;Return to Client Details<a/></p>]);
}

# PERFORM ON-DEMAND ID CHECKS
if (my $check_str = $input{do_id_check}) {
    try {
        BOM::Platform::Client::IDAuthentication->new(client => $client)->proveid;
        code_exit_BO(
            qq[<p><b>ProveID completed</b></p>
                 <p><a href="$self_href">&laquo;Return to Client Details<a/></p>]
        );
    }
    catch {
        code_exit_BO(
            qq[<p><b>ProveID failed: $_</b></p>
                 <p><a href="$self_href">&laquo;Return to Client Details<a/></p>]
        );
    }
}

# DELETE EXISTING EXPERIAN RESULTS
if ($input{delete_existing_192}) {
    code_exit_BO(
        qq[<p><b>Existing Reports Deleted</b></p>
        <p><a href="$self_href">&laquo;Return to Client Details<a/></p>]
    ) if BOM::Platform::ProveID->new(client => $client)->delete_existing_reports();
}

# SAVE DETAILS
# TODO:  Once we switch to userdb, we will not need to loop through all clients
if ($input{edit_client_loginid} =~ /^\D+\d+$/) {

    _assemble_dob_input({
        client => $client,
        input  => \%input,
    });

    # Active client specific update details:
    my $auth_method = 'dummy';
    if ($input{client_authentication}) {
        $auth_method = $input{client_authentication};

        # Remove existing status to make the auth methods mutually exclusive
        $_->delete for @{$client->client_authentication_method};

        $client->set_authentication('ID_NOTARIZED')->status('pass') if $auth_method eq 'ID_NOTARIZED';
        my $already_passed_id_document = $client->get_authentication('ID_DOCUMENT') ? $client->get_authentication('ID_DOCUMENT')->status : '';
        if ($auth_method eq 'ID_DOCUMENT' && !($already_passed_id_document eq 'pass'))
        {    #Authenticated with scans, front end lets this get run again even if already set.

            $client->set_authentication('ID_DOCUMENT')->status('pass');
            BOM::Platform::Event::Emitter::emit('authenticated_with_scans', {loginid => $loginid});
        }

        if ($auth_method eq 'NEEDS_ACTION') {
            $client->set_authentication('ID_DOCUMENT')->status('needs_action');
            # if client is marked as needs action then we need to inform
            # CS for new POA document hence we need to remove any
            # key set for email already sent for POA
            BOM::Config::RedisReplicated::redis_write()->hdel("EMAIL_NOTIFICATION_POA", $client->binary_user_id);
        }
    }

    if (exists $input{professional_client}) {
        my $result;
        try {
            if ($input{professional_client}) {

                $client->status->multi_set_clear({
                    set        => ['professional'],
                    clear      => ['professional_requested', 'professional_rejected'],
                    staff_name => $clerk,
                    reason     => 'Mark as professional as requested',
                });
            } else {
                $client->status->multi_set_clear({
                    set        => ['professional_rejected'],
                    clear      => ['professional'],
                    staff_name => $clerk,
                    reason     => 'Revoke professional status',
                });
            }
        }
        catch {
            $result = "<p>Failed to update professional status of client: $loginid</p>";
        };
        # Print clients that were not updated
        print $result if $result;
    }

    # Social responsibility checks are only for MX-MLT clients
    # TODO: Remove this once the transition is done from redis to client object
    if (my $sr_risk_val = $input{client_social_responsibility_check}) {

        my $hash_name = 'social_responsibility';
        my $key_name  = $loginid . '_sr_risk_status';
        my $redis     = BOM::Config::RedisReplicated::redis_events_write();

        # There is no need to store clients with low risk in redis, as it is default
        if ($sr_risk_val eq 'low') {
            $redis->hdel($hash_name, $key_name);
        } else {
            $redis->hset($hash_name, $key_name, $sr_risk_val);
        }
    }

    # client promo_code related fields
    if (exists $input{promo_code}) {
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
    }
    # status change for existing promo code
    if (exists $input{promo_code_status} and not exists $input{promo_code}) {
        $client->promo_code_status($input{promo_code_status});
    }

    if (   ($input{first_name} and $input{first_name} ne $client->first_name)
        or ($input{last_name}     and $input{last_name} ne $client->last_name)
        or ($input{phone}         and $input{phone} ne $client->phone)
        or ($input{date_of_birth} and $input{date_of_birth} ne $client->date_of_birth))
    {
        my $duplicate_account_details = _check_duplicates({
            client => $client,
            input  => \%input
        });

        if (@$duplicate_account_details) {

            my $data = {
                loginid       => $duplicate_account_details->[0],
                first_name    => $duplicate_account_details->[1],
                last_name     => $duplicate_account_details->[2],
                date_of_birth => $duplicate_account_details->[3],
                phone         => $duplicate_account_details->[5],
                self_link     => $self_href
            };

            BOM::Backoffice::Request::template()->process('backoffice/duplicate_client_details.tt', $data)
                or die BOM::Backoffice::Request::template()->error();

            code_exit_BO();
        }
    }

    my $new_residence = delete $input{residence};

    my @clients_to_update;

    if ($new_residence) {

        # Check if residence is valid or not
        my $valid_change = _residence_change_validation({
            old_residence   => $client->residence,
            new_residence   => $new_residence,
            all_clients     => \@user_clients,
            is_virtual_only => $is_virtual_only,
            has_mt5_logins  => @mt_logins ? 1 : 0
        });

        unless ($valid_change) {
            my $self_href = request()->url_for('backoffice/f_clientloginid_edit.cgi', {loginID => $client->loginid});
            print qq{<p style="color:red">Invalid residence change, due to different broker codes or different country restrictions.</p>};
            code_exit_BO(qq[<p><a href="$self_href">&laquo;Return to Client Details<a/></p>]);
        }

        $_->residence($new_residence) for @user_clients;

        @clients_to_update = @user_clients;

    } else {

        # Two reasons for this check:
        # 1. If other fields were updated in virtual, we should not saving anything.
        # 2. In a real account, let's assume that didn't update the residence
        # but updated other fields (first_name, last_name)
        # Filter out virtual clients if residence is not updated VR does not have this data; only residence is needed.
        # Hence: we'll end up making an extra call to VR database when none of the fields were updated
        @clients_to_update = $client->is_virtual ? () : grep { not $_->is_virtual } @user_clients;
    }

    # Updates that apply to both active client and its corresponding clients
    foreach my $cli (@clients_to_update) {

        # For non-resident changes, we have to update only real accounts
        next if ($cli->is_virtual || $client->is_virtual);

        # Prevent last_name and first_name from being set blank
        foreach (qw/last_name first_name/) {
            next unless exists $input{$_};
            if ($input{$_} =~ /^\s*$/) {
                code_exit_BO("<p style=\"color:red; font-weight:bold;\">ERROR ! $_ field appears incorrect or empty.</p></p>");
            }
        }

        unless ($cli->get_db eq 'write') {
            $cli->set_db('write');
        }

        if (exists $input{pa_withdrawal_explicitly_allowed}) {
            if ($input{pa_withdrawal_explicitly_allowed}) {
                $cli->status->set('pa_withdrawal_explicitly_allowed', $clerk, 'allow withdrawal through payment agent');
            } else {
                $cli->status->clear_pa_withdrawal_explicitly_allowed;
            }
        }
        my @simple_updates = qw/last_name
            first_name
            phone
            secret_question
            citizen
            address_1
            address_2
            city
            state
            postcode
            place_of_birth
            restricted_ip_address
            cashier_setting_password
            salutation
            /;
        exists $input{$_} && $cli->$_($input{$_}) for @simple_updates;

        my $tax_residence;
        if (exists $input{tax_residence}) {
            # Filter keys for tax residence
            my @tax_residence_multiple =
                ref $input{tax_residence} eq 'ARRAY' ? @{$input{tax_residence}} : ($input{tax_residence});
            $tax_residence = join(",", sort grep { length } @tax_residence_multiple);
        }

        if ($input{date_of_birth}) {
            $cli->date_of_birth($input{date_of_birth});
        }

        CLIENT_KEY:
        foreach my $key (keys %input) {
            if (my ($document_field, $id) = $key =~ /^(expiration_date|comments|document_id)_([0-9]+)$/) {
                my $val = $input{$key} or next CLIENT_KEY;
                my ($doc) = grep { $_->id eq $id } $cli->client_authentication_document;    # Rose
                next CLIENT_KEY unless $doc;
                my $new_value;
                if ($document_field eq 'expiration_date') {
                    try {
                        $new_value = Date::Utility->new($val)->date_yyyymmdd if $val ne 'clear';
                        # indicate success
                        1
                    }
                    catch {
                        my $err = (split "\n", $_)[0];                                      #handle Date::Utility's confess() call
                        print qq{<p style="color:red">ERROR: Could not parse $document_field for doc $id with $val: $err</p>};
                        # indicate failure so we skip to the next key
                        0
                    } or next CLIENT_KEY;
                } else {
                    my $maxLength = ($document_field eq 'document_id') ? 30 : ($document_field eq 'comments') ? 255 : 0;
                    if (length($val) > $maxLength) {
                        print qq{<p style="color:red">ERROR: $document_field is too long. </p>};
                        next CLIENT_KEY;
                    }
                    $new_value = $val;
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
                next CLIENT_KEY;
            }
            if ($key eq 'secret_answer') {
                # algorithm provide different encrypted string from the same text based on some randomness
                # so we update this encrypted field only on value change - we don't want our trigger log trash

                my $secret_answer;
                try {
                    $secret_answer = BOM::User::Utility::decrypt_secret_answer($cli->secret_answer);
                }
                catch {
                    print qq{<p style="color:red">ERROR: Unable to extract secret answer. Client secret answer is outdated or invalid.</p>};
                    $secret_answer = '';
                };

                $cli->secret_answer(BOM::User::Utility::encrypt_secret_answer($input{$key}))
                    if ($input{$key} ne $secret_answer);

                next CLIENT_KEY;
            }

            if (exists $input{'age_verification'}) {
                foreach my $cli (@user_clients) {
                    if ($input{'age_verification'} eq 'yes') {
                        $cli->status->set('age_verification', $clerk, 'No specific reason.') unless $cli->status->age_verification;
                    } else {
                        $cli->status->clear_age_verification;
                    }
                }
            }

            if ($key eq 'client_aml_risk_classification') {
                $cli->aml_risk_classification($input{$key});
            }

            if ($input{mifir_id} and $cli->mifir_id eq '' and $broker eq 'MF') {
                code_exit_BO(
                    "<p style=\"color:red; font-weight:bold;\">ERROR : Could not update client details for client $encoded_loginid: MIFIR_ID line too long</p>"
                ) if (length($input{mifir_id}) > 35);
                $cli->mifir_id($input{mifir_id});
            }

            if ($key eq 'tax_residence') {
                code_exit_BO("<p style=\"color:red; font-weight:bold;\">Tax residence cannot be set empty if value already exists</p>")
                    if ($cli->tax_residence and not $tax_residence);
                $cli->tax_residence($tax_residence);
            }

            if ($key eq 'tax_identification_number') {
                code_exit_BO("<p style=\"color:red; font-weight:bold;\">Tax residence cannot be set empty if value already exists</p>")
                    if ($cli->tax_identification_number and not $input{tax_identification_number});
                $cli->tax_identification_number($input{tax_identification_number});
            }
        }
    }

    # Save details for all clients
    foreach my $cli (@clients_to_update) {
        my $sync_error;

        if (not $cli->save) {
            code_exit_BO("<p style=\"color:red; font-weight:bold;\">ERROR : Could not update client details for client $encoded_loginid</p></p>");

        } elsif (!$client->is_virtual && ($auth_method =~ /^(?:ID_NOTARIZED|ID_DOCUMENT$)/)) {
            # sync to doughflow once we authenticate real client
            # need to do after client save so that all information is upto date

            $sync_error = sync_to_doughflow($cli, $clerk);
        }

        print "<p style=\"color:#eeee00; font-weight:bold;\">Client " . $cli->loginid . " saved</p>";
        print "<p style=\"color:#eeee00;\">$sync_error</p>" if $sync_error;

        BOM::Platform::Event::Emitter::emit('sync_user_to_MT5', {loginid => $cli->loginid}) if ($cli->loginid eq $loginid);
    }

    # Sync onfido with latest updates
    BOM::Platform::Event::Emitter::emit('sync_onfido_details', {loginid => $client->loginid});

    BOM::Platform::Event::Emitter::emit('verify_address', {loginid => $client->loginid})
        if (any { exists $input{$_} } qw(address_1 address_2 city state postcode));
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
print qq{<br/>
    <div class="flat">
    <form action="$self_post" method="get">
        <input type="text" size="15" maxlength="15" name="loginID" value="$encoded_loginid">
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

my $statuses = join '/', map { uc $_ } @{$client->status->all};
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

print "<p>Corresponding accounts: </p><ul>";

# show all BOM loginids for user, include disabled acc
foreach my $lid (@user_clients) {
    next if ($lid->loginid eq $client->loginid);

    # get BOM loginids for the user, and get instance of each loginid's currency
    my $client = BOM::User::Client->new({loginid => $lid->loginid});
    my $currency = $client->default_account ? $client->default_account->currency_code : 'No currency selected';

    my $link_href = request()->url_for(
        'backoffice/f_clientloginid_edit.cgi',
        {
            broker  => $lid->broker_code,
            loginID => $lid->loginid,
        });

    print "<li><a href='$link_href'"
        . ($client->status->disabled ? ' style="color:red"' : '') . ">"
        . encode_entities($lid->loginid) . " ("
        . $currency
        . ") </a></li>";

}

# show MT5 a/c
foreach my $mt_ac (@mt_logins) {
    my ($id) = $mt_ac =~ /^MT(\d+)$/;
    print "<li>" . encode_entities($mt_ac);
    # If we have group information, display it
    if (my $group = BOM::Config::RedisReplicated::redis_mt5_user()->get("MT5_USER_GROUP::$id")) {
        print " (" . encode_entities($group) . ")";
    } else {
        # ... and if we don't, queue up the request. This may lead to a few duplicates
        # in the queue - that's fine, we check each one to see if it's already
        # been processed.
        BOM::Config::RedisReplicated::redis_mt5_user_write()->lpush('MT5_USER_GROUP_PENDING', join(':', $id, time));
        print ' (<span title="Try refreshing in a minute or so">no group info yet</span>)';
    }
    print "</li>";
}

print "</ul>";

eval {
    my $mt5_log_size = BOM::Config::RedisReplicated::redis_mt5_user()->llen("MT5_USER_GROUP_PENDING");

    print "<p style='color:red'>Note: MT5 groups might take time to appear, since there are "
        . encode_entities($mt5_log_size)
        . " item(s) being processed</p>"
        if $mt5_log_size > 500;

} or print encode_entities($@);
my $log_args = {
    broker   => $broker,
    category => 'client_details',
    loginid  => $loginid
};
my $new_log_href = request()->url_for('backoffice/show_audit_trail.cgi', $log_args);
print qq{<p>Click for <a href="$new_log_href">history of changes</a> to $encoded_loginid</p>};

print qq[<form action="$self_post?loginID=$encoded_loginid" id="clientInfoForm" method="post">
    <input type="submit" value="Save Client Details">
    <input type="hidden" name="broker" value="$encoded_broker">];

# Get latest client object to make sure it contains updated client info (after editing client details form)
$client = BOM::User::Client->new({loginid => $loginid});
print_client_details($client);

my $INPUT_SELECTOR = 'input:not([type="hidden"]):not([type="submit"]):not([type="reset"]):not([type="button"])';

print qq[
    <input type=submit value="Save Client Details"></form>
    <style>
        .data-changed {
            background: pink;
        }
    </style>
    <script>
        clientInfoForm.querySelectorAll('$INPUT_SELECTOR,select').forEach(input => {
            input.addEventListener('change', ev => ev.target.classList.add('data-changed'));
        });
        clientInfoForm.addEventListener('submit', ev => {
            clientInfoForm.querySelectorAll('$INPUT_SELECTOR:not(.data-changed),select:not(.data-changed)')
            .forEach(input => input.setAttribute('disabled', 'disabled'));
            clientInfoForm.querySelectorAll('.data-changed[type=checkbox]').forEach(checkbox => {
            if (checkbox.checked) return;
            const input = document.createElement("input");
            input.type = 'hidden';
            input.value = '0';
            input.name = checkbox.name;
            checkbox.parentElement.appendChild(input);})
        });
    </script>
];

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
    Bar("Sync Client Information to MT5");
    print qq{
        <p>Click to sync client information to MT5: </p>
        <form action="$self_post" method="get">
            <input type="hidden" name="whattodo" value="sync_to_MT5">
            <input type="hidden" name="loginID" value="$encoded_loginid">
            <input type="submit" value="Sync to MT5">
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
my $token_db = BOM::Database::Model::AccessToken->new();
my (@all_tokens, @deleted_tokens);

foreach my $l (@user_clients) {
    foreach my $t (@{$token_db->get_all_tokens_by_loginid($l->loginid)}) {
        $t->{loginid} = $l->loginid;
        $t->{token}   = obfuscate_token($t->{token});
        push @all_tokens, $t;
    }
    foreach my $t (@{$token_db->token_deletion_history($l->loginid)}) {
        $t->{loginid} = $l->loginid;
        push @deleted_tokens, $t;
    }
}

@all_tokens     = rev_sort_by { $_->{creation_time} } @all_tokens;
@deleted_tokens = rev_sort_by { $_->{deleted} } @deleted_tokens;

BOM::Backoffice::Request::template()->process(
    'backoffice/access_tokens.html.tt',
    {
        tokens  => \@all_tokens,
        deleted => \@deleted_tokens
    }) || die BOM::Backoffice::Request::template()->error();

Bar("$loginid Copiers/Traders");
my $copiers_data_mapper = BOM::Database::DataMapper::Copier->new({
    db             => $client->db,
    client_loginid => $loginid
});

my $copiers = $copiers_data_mapper->get_copiers_tokens_all({trader_id => $loginid});
my $traders = $copiers_data_mapper->get_traders_tokens_all({copier_id => $loginid});
map { $_->[3] = obfuscate_token($_->[2]) } @$copiers;
map { $_->[3] = obfuscate_token($_->[2]) } @$traders;

BOM::Backoffice::Request::template()->process(
    'backoffice/copy_trader_tokens.html.tt',
    {
        copiers   => $copiers,
        traders   => $traders,
        loginid   => $encoded_loginid,
        self_post => $self_post
    }) || die BOM::Backoffice::Request::template()->error();

Bar('Send Client Statement');
BOM::Backoffice::Request::template()->process(
    'backoffice/send_client_statement.tt',
    {
        today     => Date::Utility->new()->date_yyyymmdd(),
        broker    => $input{broker},
        client_id => $input{loginID},
        action    => request()->url_for('backoffice/f_send_statement.cgi')
    },
);

Bar("Email Consent");
print '<br/>';
print 'Email consent for marketing: ' . ($user->{email_consent} ? 'Yes' : 'No');
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
            countries => request()->brand->countries_instance->countries,
        });
}

my $built_fa =
    BOM::User::FinancialAssessment::build_financial_assessment(BOM::User::FinancialAssessment::decode_fa($client->financial_assessment()));
my $fa_score              = $built_fa->{scores};
my $trading_experience    = $built_fa->{trading_experience};
my $financial_information = $built_fa->{financial_information};
if ($trading_experience) {
    Bar("Trading Experience");
    print_fa_table(%$trading_experience);
    print '<p>Trading experience score: ' . $fa_score->{trading_experience} . '</p>';
    print '<p>CFD Score: ' . $fa_score->{cfd_score} . '</p><br/>';
}
if ($financial_information) {
    Bar("Financial Information");
    print_fa_table(%$financial_information);
    print '<p>Financial information score: ' . $fa_score->{financial_information} . '</p><br/>';
}

sub print_fa_table {
    my %section = @_;

    my @hdr = ('Question', 'Answer', 'Score');

    print '<br/><table style="width:100%;" border="1" class="sortable"><thead><tr>';
    print '<th scope="col">' . encode_entities($_) . '</th>' for @hdr;
    print '</thead><tbody>';
    for my $key (keys %section) {
        my $answer = $section{$key}->{answer} // 'Client did not answer this question.';
        print '<tr><td>' . $section{$key}->{label} . '</td><td>' . $answer . '</td><td>' . $section{$key}->{score} . '</td></tr>';
    }
    print '</tbody></table></br>';

    return undef;
}

Bar($user->{email} . " Login history");
print '<div><br/>';
my $limit         = 200;
my $login_history = $user->login_history(
    order => 'desc',
    limit => $limit
);

BOM::Backoffice::Request::template()->process(
    'backoffice/user_login_history.html.tt',
    {
        user    => $user,
        history => $login_history,
        limit   => $limit
    });

=head2 _delete_copiers

Takes incoming copier and token string and calls the routine that removes them
works for lists of copiers or traders.

Takes the following arguments

=over 4

=item ArrayRef of strings with combined clientid and token separated by "::" (CR900001::X9SrjksrY5, CR..  )

=item String  "copier"|"trader" depending on which the list contains.

=item String  client_id for the user being editied (globally = $loginid)

=item DB handle

=back

Returns number of tokens deleted as integer

=cut

sub _delete_copiers {
    my ($list, $type, $loginid, $db) = @_;

    my $copiers_data_mapper = BOM::Database::DataMapper::Copier->new({
        db             => $db,
        client_loginid => $loginid
    });
    my $delete_count = 0;
    foreach my $client_token (@$list) {
        my ($client_id, $token) = split('::', $client_token);
        # switch around ids depending if they are a copier or trader.
        my ($trader_id, $copier_id) = $type eq 'copier' ? ($loginid, $client_id) : ($client_id, $loginid);
        $delete_count += $copiers_data_mapper->delete_copiers({
            trader_id => $trader_id,
            copier_id => $copier_id,
            token     => $token || undef
        });
    }
    return $delete_count;
}

sub obfuscate_token {
    my $t = shift;

    $t =~ s/(.*)(.{4})$/('*' x length $1).$2/e;
    return $t;

}

sub _residence_change_validation {
    my $data = shift;

    my $new_residence = $data->{new_residence};
    my @all_clients   = @{$data->{all_clients}};

    my $countries_instance = request()->brand->countries_instance;

    # Get the list of landing companies, as per residence
    my $get_lc = sub {
        my ($residence) = @_;

        my @broker_list;

        my $gc = $countries_instance->gaming_company_for_country($residence);
        my $fc = $countries_instance->financial_company_for_country($residence);

        return () unless ($gc || $fc);

        # Either gc or fc is none, so that's why the check is needed
        push @broker_list, $gc if $gc;
        push @broker_list, $fc if $fc;

        return uniq @broker_list;
    };

    # Check if the new residence is allowed to trade on MT5 or not
    # NOTE: As per CS, financial accounts have a higher priority than gaming
    my $allowed_to_trade_mt5 = sub {
        my ($sub_account_type) = @_;

        my $mt5_lc = $countries_instance->mt_company_for_country(
            country          => $new_residence,
            account_type     => 'financial',
            sub_account_type => $sub_account_type
        );

        return $mt5_lc ne 'none';
    };

    my @new_lc = $get_lc->($new_residence);
    return undef unless @new_lc;

    # NOTE: GB residents are marked as unwelcome in their virtual, as per regulations
    if ($data->{is_virtual_only}) {
        my $client = $all_clients[0];

        if ($new_residence eq 'gb') {
            $client->status->set('unwelcome', 'SYSTEM', 'Pending proof of age');
        } else {
            $client->status->clear_unwelcome if $client->status->unwelcome;
        }

        return 1;
    }

    # Get the list of non-virtual landing companies from created clients
    my @current_lc;
    push @current_lc, $_->landing_company->short for grep { !$_->is_virtual } @all_clients;

    # Since we exclude VR clients, so if they don't have a real account but have a MT5
    # account, we need to get the landing companies in a different way
    @current_lc = $get_lc->($data->{old_residence}) unless @current_lc;

    # There is no need for repeated checks
    foreach my $broker (uniq @current_lc) {
        return undef unless any { $_ eq $broker } @new_lc;
    }

    # If the client has MT5 accounts but the new residence does not allow mt5 trading
    # The change should not happen (Regulations)
    if ($data->{has_mt5_logins}) {
        return undef unless ($allowed_to_trade_mt5->('standard') || $allowed_to_trade_mt5->('advanced'));
    }

    # If the loop above passes, then it is valid to change
    return 1;
}

sub _check_duplicates {
    my $data = shift;

    my $client = $data->{client};

    return [] if $client->is_virtual;

    my $input = $data->{input};

    my @dup_account_details = BOM::Database::ClientDB->new({broker_code => $input->{broker}})->get_duplicate_client({
        exclude_status => ['duplicate_account', 'disabled'],
        first_name    => $input->{first_name}    // $client->first_name,
        last_name     => $input->{last_name}     // $client->last_name,
        date_of_birth => $input->{date_of_birth} // $client->date_of_birth,
        phone         => $input->{phone}         // $client->phone,
        email         => $client->email
    });

    return \@dup_account_details;
}

# Appends date_of_birth to input hashref, assembled from 3 fields and
# using existing client dob if not is added.
sub _assemble_dob_input {
    my $data   = shift;
    my $client = $data->{client};
    my $input  = $data->{input};

    # virtual clients will always have empty dob fields, so no need to save
    return undef if $client->is_virtual;

    my @dob_fields = ('dob_year', 'dob_month', 'dob_day');
    my @dob_keys = grep { /dob_/ } keys %$input;

    # splits the client's dob out into [0] - year, [1] - month, [2] - day
    my @dob_values = ($client->date_of_birth // '') =~ /([0-9]+)-([0-9]+)-([0-9]+)/;

    my %new_dob = map { $dob_fields[$_] => $dob_values[$_] } 0 .. $#dob_fields;

    $new_dob{$_} = $input->{$_} for @dob_keys;

    if (grep { !$_ } values %new_dob) {
        my $self_href = request()->url_for('backoffice/f_clientloginid_edit.cgi', {loginID => $client->loginid});
        print qq{<p style="color:red">Error: Date of birth cannot be empty.</p>};
        code_exit_BO(qq[<p><a href="$self_href">&laquo;Return to Client Details<a/></p>]);
    }

    my $combined_new_dob = sprintf("%04d-%02d-%02d", $new_dob{'dob_year'}, $new_dob{'dob_month'}, $new_dob{'dob_day'});

    # Validate the client age
    my $dob_date = try {
        Date::Utility->new($combined_new_dob)
    }
    catch {
        code_exit_BO('Invalid Date Of Birth format');
    };

    my $countries_instance = request()->brand->countries_instance;
    code_exit_BO('Invalid country') unless $countries_instance;

    my $country = $countries_instance->countries_list->{$client->{residence}};
    code_exit_BO('Invalid country') unless $country;
    my $country_name = $country->{name};

    my $min_age      = $country->{minimum_age};
    my $minimum_date = Date::Utility->new->minus_time_interval($min_age . 'y');
    if ($dob_date->is_after($minimum_date)) {
        my $self_href = request()->url_for('backoffice/f_clientloginid_edit.cgi', {loginID => $client->loginid});
        print qq{<p style="color:red">Error: Client age must be $min_age or older for $country_name clients.</p>};
        code_exit_BO(qq[<p><a href="$self_href">&laquo;Return to Client Details<a/></p>]);
    }

    $input->{date_of_birth} = $combined_new_dob;

    return undef;
}

code_exit_BO();

1;
