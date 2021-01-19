#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;
no warnings 'uninitialized';    ## no critic (ProhibitNoWarnings) # TODO fix these warnings
use open qw[ :encoding(UTF-8) ];
use Text::Trim;
use File::Copy;
use HTML::Entities;
use Syntax::Keyword::Try;
use Digest::MD5;
use Media::Type::Simple;
use Date::Utility;
use List::UtilsBy qw(rev_sort_by);
use List::Util qw(none uniq);
use LandingCompany::Registry;
use Finance::MIFIR::CONCAT qw(mifir_concat);
use Format::Util::Numbers qw(financialrounding);
use Scalar::Util qw(looks_like_number);

use f_brokerincludeall;

use BOM::Config;
use BOM::Config::Runtime;
use BOM::User::Client;
use BOM::Config::Redis;
use BOM::Backoffice::Request qw(request);
use BOM::User;
use BOM::User::Utility;
use BOM::User::FinancialAssessment;
use BOM::User::Password;
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
use BOM::User::Onfido;
use BOM::User::Phone;
use Log::Any qw($log);

BOM::Backoffice::Sysinit::init();
my %input = %{request()->params};
PrintContentType();

# Once a day we have zombie apocalipsis at backoffice production
# https://trello.com/c/sNvAuYNn/76-backoffice-memory-leak
# We have 30 seconds time out at Cloudflare,
# here we want to try to set up alarm with the same time out.
alarm(30);
local $SIG{ALRM} = sub {
    $log->errorf('Timeout processing request f_clientloginid_edit.cgi: %s', request()->params);
    code_exit_BO(qq[ERROR: Timeout loading page, try again later]);
};

# /etc/mime.types should exist but just in case...
my $mts;
if (open my $mime_defs, '<', '/etc/mime.types') {
    $mts = Media::Type::Simple->new($mime_defs);
    close $mime_defs;
} else {
    warn "Can't open MIME types definition file: $!";
    $mts = Media::Type::Simple->new();
}
my $dbloc = BOM::Config::Runtime->instance->app_config->system->directory->db;

my %details              = get_client_details(\%input, 'backoffice/f_clientloginid_edit.cgi');
my %doc_types_categories = BOM::User::Client::DOCUMENT_TYPE_CATEGORIES();
my @expirable_doctypes   = @{$doc_types_categories{POI}{doc_types}};
my @poi_doctypes         = @{$doc_types_categories{POI}{doc_types_appreciated}};
my @no_date_doctypes     = qw(other);

my $client          = $details{client};
my $user            = $details{user};
my $encoded_loginid = $details{encoded_loginid};
my $mt_logins       = $details{mt_logins};
my $user_clients    = $details{user_clients};
my $broker          = $details{broker};
my $encoded_broker  = $details{encoded_broker};
my $is_virtual_only = $details{is_virtual_only};
my $clerk           = $details{clerk};
my $self_post       = $details{self_post};
my $self_href       = $details{self_href};
my $loginid         = $client->loginid;

# Enabling onfido resubmission
my $redis             = BOM::Config::Redis::redis_replicated_write();
my $poi_status_reason = $input{poi_reason} // $client->status->reason('allow_poi_resubmission') // 'unselected';
# Add a comment about kyc email checkbox
$poi_status_reason = join(' ', $poi_status_reason, $input{kyc_email_checkbox} ? 'kyc_email' : ()) unless $poi_status_reason =~ /\skyc_email$/;

# POI resubmission logic
if ($input{allow_onfido_resubmission} or $input{poi_reason}) {
    $client->propagate_status('allow_poi_resubmission', $clerk, $poi_status_reason);
} elsif (defined $input{allow_onfido_resubmission}) {    # resubmission is unchecked
    $client->propagate_clear_status('allow_poi_resubmission');
} elsif ($input{kyc_email_checkbox} && $client->status->allow_poi_resubmission) {
    $client->propagate_status('allow_poi_resubmission', $clerk, $poi_status_reason);
}

# POA resubmission logic
my $poa_status_reason = $input{poa_reason} // $client->status->reason('allow_poa_resubmission') // 'unselected';
# Add a comment about kyc email checkbox
$poa_status_reason = join(' ', $poa_status_reason, $input{kyc_email_checkbox} ? 'kyc_email' : ()) unless $poa_status_reason =~ /\skyc_email$/;

if ($input{allow_poa_resubmission} or $input{poa_reason}) {
    $client->propagate_status('allow_poa_resubmission', $clerk, $poa_status_reason);
} elsif (defined $input{allow_poa_resubmission}) {    # resubmission is unchecked
    $client->propagate_clear_status('allow_poa_resubmission');
} elsif ($input{kyc_email_checkbox} && $client->status->allow_poa_resubmission) {
    $client->propagate_status('allow_poa_resubmission', $clerk, $poa_status_reason);
}

if ($input{kyc_email_checkbox}) {
    my $poi_reason = ($input{poi_reason} || $client->status->reason('allow_poi_resubmission'));
    $poi_reason =~ s/\skyc_email$//;
    $poi_reason = undef if $poi_reason && ($poi_reason eq "unselected" || $poi_reason eq "other");
    my $poa_reason = $input{poa_reason} || $client->status->reason('allow_poa_resubmission');
    $poa_reason =~ s/\skyc_email$//;
    $poa_reason = undef if $poa_reason && ($poa_reason eq "unselected" || $poa_reason eq "other");

    notify_resubmission_of_poi_poa_documents($loginid, $poi_reason, $poa_reason) if ($poi_reason || $poa_reason);
}

if (defined $input{run_onfido_check}) {
    my $applicant_data = BOM::User::Onfido::get_user_onfido_applicant($client->binary_user_id);
    my $applicant_id   = $applicant_data->{id};
    unless ($applicant_id) {
        print "<p style=\"color:red; font-weight:bold;\">No corresponding onfido applicant id found for client $loginid.</p>";
        code_exit_BO(qq[<p><a href="$self_href">&laquo;Return to Client Details<a/></p>]);
    }
    BOM::Platform::Event::Emitter::emit(
        ready_for_authentication => {
            loginid      => $loginid,
            applicant_id => $applicant_id,
        });
    print "<p style=\"color:#eeee00; font-weight:bold;\">Onfido trigger request sent.</p><br/>";
    code_exit_BO(qq[<p><a href="$self_href">&laquo;Return to Client Details<a/></p>]);
}

if ($input{delete_checked_documents} and $input{del_document_list}) {
    my $documents = $input{del_document_list};
    my @documents = ref $documents ? @$documents : ($documents);
    my $full_msg  = "";
    my $loginid   = "";
    my $client;

    for my $document (@documents) {

# if the checkbox is checked and unchecked, the EventListener will still send input value as 0.
# this line is to escape this case.
        next unless $document;

        my ($doc_id, $doc_loginid, $file_name) = $document =~ m/([0-9]+)-([A-Z0-9]+)-(.+)/;

        if (   (not defined $client)
            or ($client->loginid ne $doc_loginid))
        {
            $client = BOM::User::Client::get_instance({loginid => $doc_loginid});
        }
        if ($client) {
            $client->set_db('write');
            my ($doc) = $client->find_client_authentication_document(query => [id => $doc_id]);    # Rose
            if ($doc) {
                if ($doc->delete) {
                    $full_msg .= "<p style=\"color:#eeee00; font-weight:bold;\">SUCCESS - $file_name is deleted!</p>";
                } else {
                    $full_msg .= "<p style=\"color:red; font-weight:bold;\">ERROR: did not remove $file_name record from db</p>";
                }
            } else {
                $full_msg .= "<p style=\"color:red; font-weight:bold;\">ERROR: could not find $file_name record in db</p>";
            }

        } else {
            $full_msg .= "<p style=\"color:red; font-weight:bold;\">ERROR: with client login $loginid</p>";
        }
    }

    print $full_msg;
    code_exit_BO(qq[<p><a href="$self_href">&laquo;Return to Client Details</a></p>]);
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

    if ($input{view_action} =~ qr/^mifir_/) {
        my $event_args = {
            loginid    => $loginid,
            properties => {
                updated_fields => {
                    mifir_id => $client->mifir_id,
                }}};
        BOM::Platform::Event::Emitter::emit('profile_change', $event_args);
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
    $delete_count = _delete_copiers($copier_ids, 'copier', $loginid, $db)
        if defined $copier_ids->[0];
    $delete_count += _delete_copiers($trader_ids, 'trader', $loginid, $db)
        if defined $trader_ids->[0];

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
    my $s3_client =
        BOM::Platform::S3Client->new(BOM::Config::s3()->{document_auth});
    foreach my $i (1 .. 4) {
        my $doctype      = $cgi->param('doctype_' . $i);
        my $is_poi       = any { $_ eq $doctype } @poi_doctypes;
        my $is_expirable = any { $_ eq $doctype } @expirable_doctypes;
        my $no_date_doc  = any { $_ eq $doctype } @no_date_doctypes;

        my $filetoupload                = $cgi->upload('FILE_' . $i);
        my $page_type                   = $cgi->param('page_type_' . $i);
        my $issue_date                  = $is_expirable || $no_date_doc ? undef : $cgi->param('issue_date_' . $i);
        my $expiration_date             = !$is_expirable || $no_date_doc ? undef : $cgi->param('expiration_date_' . $i);
        my $document_id                 = $input{'document_id_' . $i} // '';
        my $comments                    = $input{'comments_' . $i} // '';
        my $is_expiration_date_optional = $cgi->param('is_expiration_date_optional_' . $i) eq "on";

        next unless $filetoupload;

        if (   $expiration_date
            && $expiration_date ne (eval { Date::Utility->new($expiration_date)->date_yyyymmdd } // ''))
        {
            print qq[<p style="color:red; font-weight:bold;">Expiration date "$expiration_date" is not a valid date.</p>];
            code_exit_BO(qq[<p><a href="$self_href">&laquo;Return to Client Details<a/></p>]);
        } elsif ($issue_date
            && $issue_date ne (eval { Date::Utility->new($issue_date)->date_yyyymmdd; } // ''))
        {
            print qq[<p style="color:red; font-weight:bold;">Issue date "$issue_date" is not a valid date.</p>];
            code_exit_BO(qq[<p><a href="$self_href">&laquo;Return to Client Details<a/></p>]);
        }

        if ($is_poi and not $expiration_date and not $is_expiration_date_optional) {
            print qq[<p style="color:red; font-weight:bold;">Expiration date is missing for the POI document $doctype.</p>];
            code_exit_BO(qq[<p><a href="$self_href">&laquo;Return to Client Details<a/></p>]);
        }

        if ($docnationality and $docnationality =~ /^[a-z]{2}$/i) {
            $client->citizen($docnationality);
        }

        unless ($client->get_db eq 'write') {
            $client->set_db('write');
        }

        if (not $client->save) {
            print "<p style=\"color:red; font-weight:bold;\">Failed to save client citizenship.</p>";
            code_exit_BO(qq[<p><a href="$self_href">&laquo;Return to Client Details</a></p>]);
        }

        my $file_checksum         = Digest::MD5->new->addfile($filetoupload)->hexdigest;
        my $abs_path_to_temp_file = $cgi->tmpFileName($filetoupload);
        my $mime_type             = $cgi->uploadInfo($filetoupload)->{'Content-Type'};
        my ($file_ext)            = $cgi->param('FILE_' . $i) =~ /\.([^.]+)$/;

        # try to get file extension from mime type, else get it from filename
        my $docformat = lc($mts->ext_from_type($mime_type) // $file_ext);

        my $upload_info;
        try {
            $upload_info = $client->db->dbic->run(
                ping => sub {
                    $_->selectrow_hashref(
                        'SELECT * FROM betonmarkets.start_document_upload(?, ?, ?, ?, ?, ?, ?, ?, ?)',
                        undef, $loginid, $doctype, $docformat, $expiration_date || undef,
                        $document_id, $file_checksum, $comments,
                        $page_type  || '',
                        $issue_date || undef
                    );
                });
            die 'Document already exists.' unless $upload_info;
        } catch {
            $result .= "<br /><p style=\"color:red; font-weight:bold;\">Error Uploading File $i: $@</p><br />";
            next;
        }

        my ($file_id, $new_file_name) =
            @{$upload_info}{qw/file_id file_name/};

        my $future = $s3_client->upload($new_file_name, $abs_path_to_temp_file, $file_checksum)->then(
            sub {
                my $err;
                try {
                    my $finish_upload_result = $client->db->dbic->run(
                        ping => sub {
                            $_->selectrow_array('SELECT * FROM betonmarkets.finish_document_upload(?)', undef, $file_id);
                        });
                    $err = 'Db returned unexpected file id on finish'
                        unless $finish_upload_result == $file_id;
                } catch {
                    $err = 'Document upload failed on finish';
                    warn $err . $@;
                }
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
    code_exit_BO(qq[<p><a href="$self_href">&laquo;Return to Client Details</a></p>]);
}

if ($input{whattodo} eq 'save_reversible_limits') {
    my $result;
    for my $param (keys %input) {
        next unless my ($cashier) = $param =~ /(\w+)_limit_new/;
        next unless $input{$param} ne ($input{$cashier . '_limit_old'} // '');
        my $val = trim($input{$param});

        try {
            if ($val) {
                die "$val is not numeric\n" unless looks_like_number($val);

                $client->db->dbic->run(
                    ping => sub {
                        $_->do('SELECT betonmarkets.manage_client_limit_by_cashier(?,?,?);', undef, $loginid, $cashier, $val / 100);
                    });
            } else {
                $client->db->dbic->run(
                    ping => sub {
                        $_->do('SELECT betonmarkets.delete_client_limit_by_cashier(?,?);', undef, $loginid, $cashier);
                    });
            }
            $result .= "<br/><p style=\"color:#eeee00; font-weight:bold;\">Updated client limit for $cashier</p><br/>\n";
        } catch ($e) {
            $result .= "<br/><p style=\"color:red; font-weight:bold;\">Error saving reversible limit: $e.</p><br/>\n";
        }
    }

    if ($result) {
        print $result;
        code_exit_BO(qq[<p><a href="$self_href">&laquo;Return to Client Details</a></p>]);
    }
}

# Disabe 2FA if theres is a request for that.
if ($input{whattodo} eq 'disable_2fa' and $user->is_totp_enabled) {
    $user->update_totp_fields(
        is_totp_enabled => 0,
        secret_key      => ''
    );

    print "<p style=\"color:#eeee00; font-weight:bold;\">2FA Disabled</p>";
    code_exit_BO(qq[<p><a href="$self_href">&laquo;Return to Client Details</a></p>]);
}

# PERFORM ON-DEMAND ID CHECKS
if (my $check_str = $input{do_id_check}) {
    try {
        BOM::Platform::Client::IDAuthentication->new(client => $client)->proveid;
    } catch {
        code_exit_BO(
            qq[<p><b>ProveID failed: $@</b></p>
                 <p><a href="$self_href">&laquo;Return to Client Details</a></p>]
        );
    }
    code_exit_BO(
        qq[<p><b>ProveID completed</b></p>
                 <p><a href="$self_href">&laquo;Return to Client Details</a></p>]
    );
}

# DELETE EXISTING EXPERIAN RESULTS
if ($input{delete_existing_192}) {
    code_exit_BO(
        qq[<p><b>Existing Reports Deleted</b></p>
        <p><a href="$self_href">&laquo;Return to Client Details</a></p>]
    ) if BOM::Platform::ProveID->new(client => $client)->delete_existing_reports();
}

# SAVE DETAILS
# TODO:  Once we switch to userdb, we will not need to loop through all clients
if ($input{edit_client_loginid} =~ /^\D+\d+$/) {
    my $error;
    # algorithm provide different encrypted string from the same text based on some randomness
    # so we update this encrypted field only on value change - we don't want our trigger log trash
    my $secret_answer = '';
    try {
        $secret_answer = BOM::User::Utility::decrypt_secret_answer($client->secret_answer) // '';
    } catch {
        print qq{<p style="color:red">ERROR: Unable to extract secret answer. Client secret answer is outdated or invalid.</p>};
    }

    my $text_validation_info = client_text_field_validation_info(
        $client,
        secret_answer => $secret_answer,
        %input
    );

    # only validate non-empty values
    for my $key (keys %$text_validation_info) {
        if ($input{$key}) {
            my $info      = $text_validation_info->{$key};
            my $old_value = ($key eq 'secret_answer') ? $secret_answer : $client->$key;

            # if value is not changed, ignore validation result
            if ($old_value ne $input{$key} and not $info->{is_valid}) {
                print qq{<p style="color:red">ERROR: <b>$info->{name}</b> validation failed: $info->{message}</p>};
                $error = 1;
            }
        }
    }
    code_exit_BO(qq[<p><a href="$self_href">&laquo;Return to Client Details</a></p>]) if ($error);

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

        if ($auth_method eq 'ID_NOTARIZED') {
            $client->set_authentication('ID_NOTARIZED', {status => 'pass'});
        }

        my $already_passed_id_document =
              $client->get_authentication('ID_DOCUMENT')
            ? $client->get_authentication('ID_DOCUMENT')->status
            : '';
        if ($auth_method eq 'ID_DOCUMENT'
            && !($already_passed_id_document eq 'pass'))
        {    #Authenticated with scans, front end lets this get run again even if already set.

            $client->set_authentication('ID_DOCUMENT', {status => 'pass'});
            BOM::Platform::Event::Emitter::emit('authenticated_with_scans', {loginid => $loginid});
        }

        my $already_passed_id_online =
              $client->get_authentication('ID_ONLINE')
            ? $client->get_authentication('ID_ONLINE')->status
            : '';
        if ($auth_method eq 'ID_ONLINE'
            && !($already_passed_id_online eq 'pass'))
        {
            $client->set_authentication('ID_ONLINE', {status => 'pass'});
        }

        if ($auth_method eq 'NEEDS_ACTION') {
            $client->set_authentication('ID_DOCUMENT', {status => 'needs_action'});
            # 'Needs Action' shouldn't replace the locks from the account because we'll lose the request authentication reason
            $client->status->setnx('allow_document_upload', $clerk, 'MARKED_AS_NEEDS_ACTION');

            # if client is marked as needs action then we need to inform
            # CS for new POA document hence we need to remove any
            # key set for email already sent for POA
            BOM::Config::Redis::redis_replicated_write()->hdel("EMAIL_NOTIFICATION_POA", $client->binary_user_id);
        }

        $client->save;
        $client->update_status_after_auth_fa();
        # Remove unwelcome status from MX client once it fully authenticated
        $client->status->clear_unwelcome
            if ($client->residence eq 'gb'
            and $client->landing_company->short eq 'iom'
            and $client->fully_authenticated
            and $client->status->unwelcome);
    }
    if ($input{age_verification} and not $client->is_virtual) {
        my @allowed_lc_to_sync = @{$client->landing_company->allowed_landing_companies_for_age_verification_sync};
        # Apply age verification for one client per each landing company since we have a DB trigger that sync age verification between the same landing companies.
        my @clients_to_update =
            map { [$client->user->clients_for_landing_company($_)]->[0] // () } @allowed_lc_to_sync;
        push @clients_to_update, $client;
        foreach my $client_to_update (@clients_to_update) {
            if ($input{'age_verification'} eq 'yes') {
                $client_to_update->status->setnx('age_verification', $clerk, 'Age verified client from Backoffice.');
            } else {
                $client_to_update->status->clear_age_verification;
            }
        }

        $client->update_status_after_auth_fa();
    }
    if (exists $input{professional_client}) {
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
        } catch {
            # Print clients that were not updated
            print "<p>Failed to update professional status of client: $loginid</p>";
        }
    }

    # TODO: Remove this once the transition is done from redis to client object
    if ((my $sr_risk_val = $input{client_social_responsibility_check})
        && $client->landing_company->social_responsibility_check_required)
    {

        my $key_name = $loginid . '_sr_risk_status';
        my $redis    = BOM::Config::Redis::redis_events_write();

        # There is no need to store clients with low risk in redis, as it is default
        # and also: if the status is changed from high, we don't need the expiry time
        if ($sr_risk_val eq 'low') {
            $redis->del($key_name);
        } else {
            $redis->set($key_name, $sr_risk_val);
        }
    }

    # client promo_code related fields
    if (exists $input{promo_code}) {
        if (BOM::Backoffice::Auth0::has_authorisation(['Marketing'])) {

            if (my $promo_code = uc $input{promo_code}) {
                my $encoded_promo_code = encode_entities($promo_code);
                my %pcargs             = (
                    code   => $promo_code,
                    broker => $broker
                );

                # add or update client promo code
                try {
                    $client->promo_code($promo_code);
                } catch {
                    code_exit_BO(sprintf('<p style="color:red; font-weight:bold;">ERROR: %s</p>', $_));
                };
                $client->promo_code_status($input{promo_code_status} || 'NOT_CLAIM');

            } elsif ($client->promo_code) {
                $client->set_promotion->delete;
            }
        }
    }

    # status change for existing promo code
    if (exists $input{promo_code_status} and not exists $input{promo_code}) {
        $client->promo_code_status($input{promo_code_status});
    }

    # account opening reason
    if (my $reason = $input{account_opening_reason}) {
        my $account_opening_reasons = ACCOUNT_OPENING_REASONS;
        if (none { $reason eq $_ } @{$account_opening_reasons}) {
            code_exit_BO('<p style="color:red; font-weight:bold;">ERROR: Not a valid account opening reason.</p>');
        }
    }

    # Prior to duplicate check and storing, strip off trailing and leading whitespace
    $error = $client->format_input_details(\%input);

    # Perform additional checks, but only for non-virtual accounts
    if (not $error and not $client->is_virtual) {
        $error = $client->validate_common_account_details({
            secret_answer => $secret_answer // '',
            %input
        });
    }

    if ($error) {
        my $message = $error->{error};
        code_exit_BO("<p style='color:red; font-weight:bold;'>ERROR: $message </p><p><a href='$self_href'>&laquo;Return to Client Details</a></p>");
    }

    # Do not check here for phone duplicate because CS will have to contact the client
    #$input{checks} = ['first_name', 'last_name', 'date_of_birth'];
    my $details_to_check_for_duplicate = {
        first_name    => $input{first_name},
        last_name     => $input{last_name},
        date_of_birth => $input{date_of_birth}};
    $error = $client->check_duplicate_account($details_to_check_for_duplicate);
    if ($error) {
        my $duplicate_account_details = $error->{details};
        my $data                      = {
            loginid       => $duplicate_account_details->[0],
            first_name    => $duplicate_account_details->[1],
            last_name     => $duplicate_account_details->[2],
            date_of_birth => $duplicate_account_details->[3],
            self_link     => $self_href
        };

        BOM::Backoffice::Request::template()->process('backoffice/duplicate_client_details.tt', $data)
            or die BOM::Backoffice::Request::template()->error();

        code_exit_BO();
    }

    my $new_residence = delete $input{residence};

    my (%clients_updated);

    if ($new_residence) {

        # Check if residence is valid or not
        my $valid_change = _residence_change_validation({
            old_residence   => $client->residence,
            new_residence   => $new_residence,
            all_clients     => $user_clients,
            is_virtual_only => $is_virtual_only,
            has_mt5_logins  => $mt_logins->@* ? 1 : 0
        });

        unless ($valid_change) {
            my $self_href = request()->url_for('backoffice/f_clientloginid_edit.cgi', {loginID => $client->loginid});
            print qq{<p style="color:red">Invalid residence change, due to different broker codes or different country restrictions.</p>};
            code_exit_BO(qq[<p><a href="$self_href">&laquo;Return to Client Details</a></p>]);
        }

        do {
            $_->residence($new_residence);
            $clients_updated{$_->loginid} = $_;
            }
            for $user_clients->@*;
    }

# Two reasons for this check:
# 1. If other fields were updated in virtual, we should not saving anything.
# 2. In a real account, let's assume that didn't update the residence
# but updated other fields (first_name, last_name)
# Filter out virtual clients if residence is not updated VR does not have this data; only residence is needed.
# Hence: we'll end up making an extra call to VR database when none of the fields were updated
    my @clients_to_update = $client->is_virtual ? () : grep { not $_->is_virtual } $user_clients->@*;

    # Updates that apply to both active client and its corresponding clients
    foreach my $cli (@clients_to_update) {

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

        if (exists $input{pa_withdrawal_explicitly_allowed}
            && update_needed($client, $cli, 'pa_withdrawal_explicitly_allowed', \%clients_updated))
        {
            if ($input{pa_withdrawal_explicitly_allowed}) {
                $cli->status->setnx('pa_withdrawal_explicitly_allowed', $clerk, 'allow withdrawal through payment agent');
            } else {
                $cli->status->clear_pa_withdrawal_explicitly_allowed;
            }
        }
        my @simple_updates = qw/last_name
            first_name
            phone
            citizen
            address_1
            address_2
            city
            state
            postcode
            place_of_birth
            restricted_ip_address
            salutation
            account_opening_reason
            /;
        exists $input{$_}
            && update_needed($client, $cli, $_, \%clients_updated)
            && $cli->$_($input{$_})
            for @simple_updates;

        my $secret_question = trim($input{secret_question});
        if (defined $secret_question and update_needed($client, $cli, $_, \%clients_updated)) {
            $cli->secret_question($secret_question);
        }

        my $tax_residence;
        if (exists $input{tax_residence}) {

            # Filter keys for tax residence
            my @tax_residence_multiple =
                ref $input{tax_residence} eq 'ARRAY'
                ? @{$input{tax_residence}}
                : ($input{tax_residence});
            $tax_residence = join(",", sort grep { length } @tax_residence_multiple);
        }

        if ($input{date_of_birth}
            && update_needed($client, $cli, 'date_of_birth', \%clients_updated))
        {
            $cli->date_of_birth($input{date_of_birth});
        }

        CLIENT_KEY:
        foreach my $key (keys %input) {
            if (my ($document_field, $id) = $key =~ /^(expiration_date|issue_date|comments|document_id)_([0-9]+)$/) {
                my $val = ($document_field =~ /^(expiration_date|issue_date)$/ && $input{$key} eq '') ? 'clear' : $input{$key};
                next CLIENT_KEY unless $val && update_needed($client, $cli, 'client_authentication_document', \%clients_updated);
                my ($doc) = grep { $_->id eq $id } $cli->client_authentication_document;    # Rose
                next CLIENT_KEY unless $doc;
                my $new_value;
                if ($document_field =~ /^(expiration_date|issue_date)$/) {
                    try {
                        $new_value = Date::Utility->new($val)->date_yyyymmdd if $val ne 'clear';
                    } catch {
                        my $err = (split "\n", $@)[0];                                      #handle Date::Utility's confess() call
                        print qq{<p style="color:red">ERROR: Could not parse $document_field for doc $id with $val: $err</p>};
                        next CLIENT_KEY;
                    }
                } else {
                    my $maxLength =
                          ($document_field eq 'document_id') ? 30
                        : ($document_field eq 'comments')    ? 255
                        :                                      0;
                    if (length($val) > $maxLength) {
                        print qq{<p style="color:red">ERROR: $document_field is too long. </p>};
                        next CLIENT_KEY;
                    }
                    $new_value = $val;
                }
                next CLIENT_KEY if $new_value && $new_value eq $doc->$document_field();
                try {
                    $doc->$document_field($new_value);
                } catch {
                    print qq{<p style="color:red">ERROR: Could not set $document_field for doc $id with $val: $@</p>};
                }
                next CLIENT_KEY;
            }

            next CLIENT_KEY
                unless update_needed($client, $cli, $key, \%clients_updated);
            if ($key eq 'secret_answer') {
                $cli->secret_answer(BOM::User::Utility::encrypt_secret_answer($input{$key}))
                    if ($input{$key} ne $secret_answer);

            } elsif ($key eq 'client_aml_risk_classification' && BOM::Backoffice::Auth0::has_authorisation(['Compliance'])) {
                $cli->aml_risk_classification($input{$key});

            } elsif ($key eq 'mifir_id'
                and $cli->mifir_id eq ''
                and $broker eq 'MF')
            {
                code_exit_BO(
                    "<p style=\"color:red; font-weight:bold;\">ERROR : Could not update client details for client $encoded_loginid: MIFIR_ID line too long</p>"
                ) if (length($input{$key}) > 35);
                $cli->mifir_id($input{$key});
            } elsif ($key eq 'tax_residence') {
                code_exit_BO("<p style=\"color:red; font-weight:bold;\">Tax residence cannot be set empty if value already exists</p>")
                    if ($cli->tax_residence and not $tax_residence);
                $cli->tax_residence($tax_residence);
            } elsif ($key eq 'tax_identification_number') {
                code_exit_BO("<p style=\"color:red; font-weight:bold;\">Tax residence cannot be set empty if value already exists</p>")
                    if ($cli->tax_identification_number
                    and not $input{tax_identification_number});
                $cli->tax_identification_number($input{tax_identification_number});
            }
        }
    }

    # Setting age_verification may change p2p advertiser approval via db trigger.
    # We need to fire an event if approval has changed.
    my $p2p_advertiser = $client->p2p_advertiser_info;
    if ($p2p_advertiser and $input{p2p_approved} ne $p2p_advertiser->{is_approved}) {
        BOM::Platform::Event::Emitter::emit('p2p_advertiser_updated', {client_loginid => $loginid});
    }

    # Save details for all clients
    foreach my $cli (values %clients_updated) {
        my $sync_error;

        if (not $cli->save) {
            code_exit_BO("<p style=\"color:red; font-weight:bold;\">ERROR : Could not update client details for client $encoded_loginid</p></p>");

        } elsif (!$client->is_virtual
            && ($auth_method =~ /^(?:ID_NOTARIZED|ID_DOCUMENT$)/))
        {
            # sync to doughflow once we authenticate real client
            # need to do after client save so that all information is upto date

            $sync_error = sync_to_doughflow($cli, $clerk);
        }

        print "<p style=\"color:#eeee00; font-weight:bold;\">Client " . $cli->loginid . " saved</p>";
        print "<p style=\"color:#eeee00;\">$sync_error</p>" if $sync_error;

        BOM::Platform::Event::Emitter::emit('sync_user_to_MT5', {loginid => $cli->loginid})
            if ($cli->loginid eq $loginid);
    }

    my %updated_fields = map { defined $input{$_} ? ($_ => $client->$_) : () }
        qw /account_opening_reason address_city address_line_1 address_line_2 address_postcode address_state
        allow_copiers citizen first_name last_name phone
        place_of_birth residence salutation secret_answer secret_question mifir_id tax_identification_number tax_residence/;

    $updated_fields{date_of_birth} = $client->date_of_birth->ymd if any { defined $input{$_} } qw/dob_month dob_year dob_day/;

    if (keys %updated_fields) {
        my $profile_change_args = {
            loginid    => $loginid,
            properties => {updated_fields => \%updated_fields},
        };
        BOM::Platform::Event::Emitter::emit('profile_change', $profile_change_args);

        # This line is duplicated form profile_change event handler in order to avoid an additional page refresh when status codes are auto-removed.
        $client->update_status_after_auth_fa();
    }

    # Sync onfido with latest updates
    BOM::Platform::Event::Emitter::emit('sync_onfido_details', {loginid => $client->loginid});

    BOM::Platform::Event::Emitter::emit('verify_address', {loginid => $client->loginid})
        if (any { exists $input{$_} } qw(address_1 address_2 city state postcode));
}

=head2 Trading Experience & Financial Information

The purpose of this section is to display the client's
financial assessment information and scores in tables.

Also, with a B<Compliance> access, it will render editable dropdowns
instead of labels which provide them the ability to update the
client's financial assessment information.

=cut

my $is_compliance = BOM::Backoffice::Auth0::has_authorisation(['Compliance']);
my %fa_updated;
if ($is_compliance) {
    if ($input{whattodo} =~ /^(trading_experience|financial_information)$/) {
        update_fa($client, $input{whattodo});
        $fa_updated{$input{whattodo}} = 1;
    }

    if ($input{whattodo} =~ /^force_financial_assessment$/) {
        force_fa($self_href, $client, $clerk);
        $fa_updated{$input{whattodo}} = 1;
    }
}

# for hidden form fields
my $p2p_advertiser = $client->p2p_advertiser_info;
my $p2p_approved   = $p2p_advertiser ? $p2p_advertiser->{is_approved} : '';

client_navigation($client, $self_post);

# view client's statement/portfolio/profit table
my $history_url     = request()->url_for('backoffice/f_manager_history.cgi');
my $statement_url   = request()->url_for('backoffice/f_manager_statement.cgi');
my $impersonate_url = request()->url_for('backoffice/client_impersonate.cgi');

BOM::Backoffice::Request::template()->process(
    'backoffice/client_statement_get.html.tt',
    {
        history_url     => $history_url,
        statement_url   => $statement_url,
        self_post       => $self_post,
        encoded_loginid => $encoded_loginid,
        encoded_broker  => $encoded_broker,
        checked         => '',
    });

print qq{
<div  style="float: right">
<form action="$impersonate_url" method="get">
<input type='hidden' size=30 name="impersonate_loginid" value="$encoded_loginid">
<input type='hidden' name='broker' value='$encoded_broker'>
<input type="submit" value="Impersonate"></form>
</div>
};

# Display only the latest 2 comments here for faster review by CS
my $comments_count  = 2;
my @client_comments = grep { defined } $client->get_comments()->@[0 .. $comments_count - 1];
if (@client_comments) {
    my $comments_url = request()->url_for('backoffice/f_client_comments.cgi', {loginid => $client->loginid});
    print qq~
        <div class="grd-margin-top">
            <b>Latest Comment(s)</b> (Displaying up to <b>$comments_count</b> most recent comments) -
            <a href="$comments_url">Add a new comment / View full list</a>
        </div>~;
    BOM::Backoffice::Request::template()->process(
        'backoffice/client_comments_table.html.tt',
        {
            comments => [@client_comments],
            loginid  => $client->loginid,
            csrf     => BOM::Backoffice::Form::get_csrf_token(),
        });
}

Bar("$loginid STATUSES");
if (my $statuses = build_client_warning_message($loginid)) {
    print $statuses;
}

BOM::Backoffice::Request::template()->process(
    'backoffice/account/untrusted_form.html.tt',
    {
        edit_url     => request()->url_for('backoffice/untrusted_client_edit.cgi'),
        reasons      => get_untrusted_client_reason(),
        broker       => $broker,
        clientid     => $loginid,
        actions      => [sort { $a->{comments} cmp $b->{comments} } @{get_untrusted_types()}],
        actions_hash => get_untrusted_types_hashref(),
        p2p_approved => $p2p_approved,
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

# show restricted-access fields of regulated landing company clients (accessible for compliance staff only)
if (BOM::Backoffice::Auth0::has_authorisation(['Compliance']) and $client->landing_company->is_eu) {
    print('<br>');
    print 'Configure <a id="self-exclusion_restricted" href="'
        . request()->url_for(
        'backoffice/f_setting_selfexclusion_restricted.cgi',
        {
            broker  => $broker,
            loginid => $loginid
        }) . '"> restricted self-exlcusion </a> settings';
}

Bar("$loginid PAYMENT AGENT DETAILS");

# Show Payment-Agent details if this client is also a Payment Agent.
my $payment_agent = $client->payment_agent;
if ($payment_agent) {
    print '<div class="grd-margin-bottom"><table class="collapsed">';

    foreach my $column ($payment_agent->meta->columns) {
        my $value = $payment_agent->$column;
        #this line shall be removed in cleanup card when we will drop target_country column
        next if $column eq 'target_country';
        print "<tr><td>$column</td><td>=</td><td>" . encode_entities($value) . "</td></tr>";
    }
    my $pa_countries = $client->get_payment_agent->get_countries;
    print "<tr><td>Target Countries</td><td>=</td><td>" . encode_entities(join(',', @$pa_countries)) . "</td></tr>";

    print '</table></div>';
}

if ($client->landing_company->allows_payment_agents) {
    print '<div><a href="'
        . request()->url_for(
        'backoffice/f_setting_paymentagent.cgi',
        {
            broker   => $broker,
            loginid  => $loginid,
            whattodo => $payment_agent ? "show" : "create"
        }) . "\">$encoded_loginid payment agent details</a></div>";
} else {
    print '<div>Payment Agents are not available for this account.</div>';
}

my $statuses = join '/', map { uc $_ } @{$client->status->all};
my $name     = $client->first_name;
$name .= ' ' if $name;
$name .= $client->last_name;
my $client_info = sprintf "%s %s%s", $client->loginid, ($name || '?'), ($statuses ? " [$statuses]" : '');
Bar("CLIENT " . $client_info);

my ($link_acc_msg, $link_loginid);
if ($client->comment =~ /move UK clients to \w+ \(from (\w+)\)/) {
    $link_loginid = $1;
    $link_acc_msg = 'UK account, previously moved from';
} elsif ($client->comment =~ /move UK clients to \w+ \(to (\w+)\)/) {
    $link_loginid = $1;
    $link_acc_msg = 'UK account, has been moved to';
}

if ($link_acc_msg) {
    $link_loginid =~ /(\D+)\d+/;
    my $link_href = request()->url_for(
        'backoffice/f_clientloginid_edit.cgi',
        {
            broker  => $1,
            loginID => $link_loginid
        });
    print "<div class='grd-margin-bottom'>$link_acc_msg <a href='$link_href'>" . encode_entities($link_loginid) . "</a></div>";
}

print '<div>Corresponding accounts:</div><ul>';

# show all BOM loginids for user, include disabled acc
foreach my $lid ($user_clients->@*) {
    next if ($lid->loginid eq $client->loginid);

    # get BOM loginids for the user, and get instance of each loginid's currency
    my $client = BOM::User::Client->new({loginid => $lid->loginid});
    my $currency =
          $client->default_account
        ? $client->default_account->currency_code
        : 'No currency selected';

    my $formatted_balance;
    unless ($client->default_account) {
        $formatted_balance = '--- no currency selected';
    } else {
        my $balance = client_balance($client);
        $formatted_balance =
            $balance
            ? formatnumber('amount', $client->default_account->currency_code, $balance)
            : 'ZERO';
    }

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
        . ") </a><span style='margin-left:12px; color:#f44336'><strong>"
        . $formatted_balance
        . "</strong></span></li>";
}

# show MT5 a/c
foreach my $mt_ac ($mt_logins->@*) {
    print "<li>" . encode_entities($mt_ac);

    my ($group, $status) = get_mt5_group_and_status($mt_ac);

    if ($group) {
        print " (" . encode_entities($group) . ")" . " ( $status )";
    } else {
        print ' (<span title="Try refreshing in a minute or so">no group info yet</span>)';
    }
    print "</li>";
}

print "</ul>";

eval {
    my $mt5_log_size = BOM::Config::Redis::redis_mt5_user()->llen("MT5_USER_GROUP_PENDING");

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
print qq{<p>Click for <a href="$new_log_href">History of Changes (Audit Trail)</a> to $encoded_loginid</p>};

if ($payment_agent) {
    $log_args->{category} = 'payment_agent';
    $new_log_href = request()->url_for('backoffice/show_audit_trail.cgi', $log_args);
    print qq{<p>Click for <a href="$new_log_href">Payment Agent History</a> for $encoded_loginid</p>};
}

print qq[<form action="$self_post?loginID=$encoded_loginid" id="clientInfoForm" method="post">
    <input type="submit" value="Save Client Details">
    <input type="hidden" name="broker" value="$encoded_broker">
    <input type="hidden" name="p2p_approved" value="$p2p_approved">];

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
        \$(function() {
            \$('.datepick').datepicker( {
                onClose: function(date) {
                    \$(this).addClass('data-changed')
                },
                dateFormat: 'yy-mm-dd',
             });
        });
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

sub force_fa {
    my ($self_href, $client, $clerk) = @_;

    my $is_forced = $client->status->financial_assessment_required;

    code_exit_BO(
        qq[<p><b>Client is already forced to complete their financial assessment.</b></p>
        <p><a href="$self_href">&laquo;Return to Client Details</a></p>]
    ) if $is_forced;

    code_exit_BO(
        qq[<p><b>Client has already completed their financial assessment.</b></p>
        <p><a href="$self_href">&laquo;Return to Client Details</a></p>]
    ) if !is_fa_needs_completion($client);

    $client->status->setnx('financial_assessment_required', $clerk,   'Financial Assessment completion is forced from Backoffice.');
    $client->status->setnx('withdrawal_locked',             'system', 'FA needs to be completed');
}

sub is_fa_needs_completion {
    my $client = shift;

    # Note: we need to refactor some codes regarding https://trello.com/c/UbfQSLTO to handle below code duplication.
    my $sc                   = $client->landing_company->short;
    my $financial_assessment = BOM::User::FinancialAssessment::decode_fa($client->financial_assessment());

    my $is_FI = BOM::User::FinancialAssessment::is_section_complete($financial_assessment, 'financial_information');

    return !$is_FI if $sc ne 'maltainvest';

    my $is_TE = BOM::User::FinancialAssessment::is_section_complete($financial_assessment, 'trading_experience');

    return !($is_FI && $is_TE);
}

sub update_fa {
    my ($client, $section_name) = @_;
    my $config = BOM::Config::financial_assessment_fields();
    my $args   = +{
        map  { $_ => request()->param($_) }
        grep { request()->param($_) } keys $config->{$section_name}->%*
    };

    # track changed financial assessment items
    my $old_financial_assessment = BOM::User::FinancialAssessment::decode_fa($client->financial_assessment());
    my %changed_items;

    foreach my $key (keys %{$args}) {
        if (!exists($old_financial_assessment->{$key}) || $args->{$key} ne $old_financial_assessment->{$key}) {
            $changed_items{$key} = $args->{$key};
        }
    }

    BOM::Platform::Event::Emitter::emit(
        'set_financial_assessment',
        {
            loginid => $client->loginid,
            params  => \%changed_items,
        }) if (%changed_items);

    return BOM::User::FinancialAssessment::update_financial_assessment($client->user, $args);
}

my $built_fa =
    BOM::User::FinancialAssessment::build_financial_assessment(BOM::User::FinancialAssessment::decode_fa($client->financial_assessment()));
my $fa_score = $built_fa->{scores};

for my $section_name (qw(trading_experience financial_information)) {
    next unless ($built_fa->{$section_name});

    my $title = join ' ', map { ucfirst } split '_', $section_name;

    print "<a name='$section_name'></a>";
    Bar($title);

    print_fa_table($section_name, $self_href, $is_compliance, $built_fa->{$section_name}->%*);
    print "<strong style='color: #060;'>$title updated.</strong>"
        if $fa_updated{$section_name};

    print_fa_force_btn($section_name, $self_href) if ($section_name eq 'financial_information' && $is_compliance);
    print "<strong style='color: #060;'>Financial Assessment questionnaire triggered.</strong>"
        if ($section_name eq 'financial_information' && $fa_updated{force_financial_assessment});

    print "<p>$title score: <strong>" . $fa_score->{$section_name} . '</strong></p>';
    print '<p>CFD Score: <strong>' . $fa_score->{cfd_score} . '</strong></p>'
        if ($section_name eq 'trading_experience');
}

sub print_fa_table {
    my ($section_name, $self_href, $is_editable, %section) = @_;

    my @hdr    = ('Question', 'Answer', 'Score');
    my $config = BOM::Config::financial_assessment_fields();

    print "<form method='post' action='$self_href#$section_name'><input type='hidden' name='whattodo' value='$section_name'>"
        if $is_editable;
    print '<table border="1" class="sortable BlackCandy collapsed hover"><thead><tr>';
    print '<th scope="col">' . encode_entities($_) . '</th>' for @hdr;
    print '</thead><tbody>';
    for my $key (sort keys %section) {
        my $answer = $section{$key}->{answer};
        my @possible_answers =
            sort keys $config->{$section_name}->{$key}->{possible_answer}->%*;
        print '<tr><td>'
            . $section{$key}->{label}
            . '</td><td>'
            . (
            $is_editable
            ? dropdown($key, $answer, @possible_answers)
            : $answer // 'Client did not answer this question.'
            )
            . '</td><td>'
            . $section{$key}->{score}
            . '</td></tr>';
    }
    print '</tbody></table>';
    print '<input type="submit" value="Update"></form>' if $is_editable;

    return undef;
}

sub print_fa_force_btn {
    my ($section_name, $self_href) = @_;

    print "<form method='post' action='$self_href#$section_name'>";

    print '<input type="hidden" name="whattodo" value="force_financial_assessment">';

    print '<input type="submit" value="Click to force financial assessment" style="border: solid 2px red;margin-top: 12px;">';

    print '</form>';
}

sub dropdown {
    my ($name, $selected, @values) = @_;

    my $ddl = "<select name='$name'>";
    $ddl .= "<option value=''></option>" unless $selected;
    $ddl .= "<option value='$_'@{[$_ eq $selected ? ' selected=\"selected\"' : '']}>$_</option>" for @values;
    $ddl .= '</select>';

    return $ddl;
}

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

foreach my $l ($user_clients->@*) {
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
$_->[3] = obfuscate_token($_->[2]) for @$copiers, @$traders;

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
            self_post          => $self_post,
            broker             => $encoded_broker,
            loginid            => $encoded_loginid,
            countries          => request()->brand->countries_instance->countries,
            poi_doctypes       => join('|', @poi_doctypes),
            expirable_doctypes => join('|', @expirable_doctypes),
            no_date_doctypes   => join('|', @no_date_doctypes),
        });

    Bar('P2P Advertiser');

    print '<a href="'
        . request()->url_for(
        'backoffice/p2p_advertiser_manage.cgi',
        {
            broker  => $broker,
            loginID => $loginid
        })
        . '">'
        . $loginid
        . ' P2P Advertiser details</a>';

    Bar('Reversible balance limits');

    my $config = BOM::Config::Runtime->instance->app_config->payments->reversible_balance_limits;
    my %global = map { $_ => $config->$_ } keys $config->definition->{contains}->%*;

    my $client_limits = $client->db->dbic->run(
        ping => sub {
            $_->selectall_hashref(
                'SELECT ROUND(limit_as_decimal_percent*100) AS val, payment_gateway_code FROM betonmarkets.client_limit_by_cashier WHERE client_loginid = ?',
                'payment_gateway_code', undef, $loginid
            );
        });

    BOM::Backoffice::Request::template()->process(
        'backoffice/client_reversible_limits.tt',
        {
            global    => \%global,
            client    => $client_limits,
            self_post => $self_post,
            broker    => $encoded_broker,
            loginid   => $encoded_loginid,
        });
}

Bar($user->{email} . " Login history");
print '<div><br/>';
my $limit         = 200;
my $login_history = $user->login_history(
    order                    => 'desc',
    show_impersonate_records => 1,
    limit                    => $limit
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
        my ($trader_id, $copier_id) =
            $type eq 'copier'
            ? ($loginid, $client_id)
            : ($client_id, $loginid);
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
            $client->status->setnx('unwelcome', 'SYSTEM', 'Pending proof of age');
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
        return undef
            unless ($allowed_to_trade_mt5->('financial')
            || $allowed_to_trade_mt5->('financial_stp'));
    }

    # If the loop above passes, then it is valid to change
    return 1;
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
    my @dob_keys   = grep { /dob_/ } keys %$input;

    # splits the client's dob out into [0] - year, [1] - month, [2] - day
    my @dob_values = ($client->date_of_birth // '') =~ /([0-9]+)-([0-9]+)-([0-9]+)/;

    my %new_dob = map { $dob_fields[$_] => $dob_values[$_] } 0 .. $#dob_fields;

    $new_dob{$_} = $input->{$_} for @dob_keys;

    if (grep { !$_ } values %new_dob) {
        my $self_href = request()->url_for('backoffice/f_clientloginid_edit.cgi', {loginID => $client->loginid});
        print qq{<p style="color:red">Error: Date of birth cannot be empty.</p>};
        code_exit_BO(qq[<p><a href="$self_href">&laquo;Return to Client Details</a></p>]);
    }

    my $combined_new_dob = sprintf("%04d-%02d-%02d", $new_dob{'dob_year'}, $new_dob{'dob_month'}, $new_dob{'dob_day'});

    $input->{date_of_birth} = $combined_new_dob;

    return undef;
}

code_exit_BO();

=head2 update_needed

Given a key and a sibling client, check if that client should be updated, and update $clients_updated accordingly.

=cut

sub update_needed {
    my ($client, $client_checked, $key, $clients_updated) = @_;
    my $result = check_update_needed($client, $client_checked, $key);
    if ($result) {
        $clients_updated->{$client_checked->loginid} = $client_checked;
    }
    return $result;
}

1;
