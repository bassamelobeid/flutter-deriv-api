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
use List::Util    qw(none uniq);
use LandingCompany::Registry;
use Finance::MIFIR::CONCAT qw(mifir_concat);
use Format::Util::Numbers  qw(financialrounding);
use Scalar::Util           qw(looks_like_number);
use Log::Any               qw($log);
use f_brokerincludeall;

use BOM::Config;
use BOM::Config::Runtime;
use BOM::User::Client;
use BOM::Config::Redis;
use BOM::Config::Compliance;
use BOM::Backoffice::Request qw(request);
use BOM::User;
use BOM::User::Utility;
use BOM::User::FinancialAssessment;
use BOM::User::Password;
use BOM::Platform::Client::IDAuthentication;
use BOM::User::Utility;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Utility;
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
use BOM::User::SocialResponsibility;
use BOM::User::Phone;
use Log::Any        qw($log);
use JSON::MaybeUTF8 qw(encode_json_utf8 decode_json_utf8);
use constant ONFIDO_REQUEST_PER_USER_PREFIX => 'ONFIDO::REQUEST::PER::USER::';
use BOM::Backoffice::VirtualStatus;
use feature 'switch';

BOM::Backoffice::Sysinit::init();
PrintContentType();

use constant MANUAL_TIN_APPROVED_VALUES => (
    "Approved0000",  "001000000",   "00000010",       "CHE-000.000.000", 'APPR000000VED',    "00000000000000000000",
    "00000000",      "00000",       "100000",         "00000000A",       "0000000000001",    "10000000",
    "0000000A",      "000000A000A", "GHA-00000000-0", "APPRO0000A",      "APPROV00A00A000A", "000000000000000",
    "A000000000",    "A000000A",    "A00000000A",     "20000000000",     "000000000",        "000000000000",
    "0000000000000", "0000000000",  "000000",         "00000000"
);
# Once a day we have zombie apocalipsis at backoffice production
# https://trello.com/c/sNvAuYNn/76-backoffice-memory-leak
# We have 30 seconds time out at Cloudflare,
# here we want to try to set up alarm with the same time out.
alarm(30);
local $SIG{ALRM} = sub {
    $log->errorf('Timeout processing request f_clientloginid_edit.cgi');
    code_exit_BO(qq[ERROR: Timeout loading page, try again later]);
};
use constant {
    DOCUMENT_SIZE_LIMIT_IN_MB        => 20,
    ONFIDO_DOCUMENT_SIZE_LIMIT_IN_MB => 10,
    MB_IN_BYTES                      => 1024 * 1024,
};

# /etc/mime.types should exist but just in case...
my $mts;
if (open my $mime_defs, '<', '/etc/mime.types') {
    $mts = Media::Type::Simple->new($mime_defs);
    close $mime_defs;
} else {
    $log->warn("Can't open MIME types definition file: $!");
    $mts = Media::Type::Simple->new();
}
my $dbloc = BOM::Config::Runtime->instance->app_config->system->directory->db;

my %input   = %{request()->params};
my %details = get_client_details(\%input, 'backoffice/f_clientloginid_edit.cgi');

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
my $aff_mt_accounts = $details{affiliate_mt5_accounts};
my $dx_logins       = $details{dx_logins};
my $derivez_logins  = $details{derivez_logins};
my $ctrader_logins  = $details{ctrader_logins};
my $loginid_details = $details{loginid_details};

if (my $error_message = write_operation_error()) {
    print "<p class=\"notify notify--warning\">$error_message</p>";
    code_exit_BO(qq[<p><a href="$self_href" class="link">&laquo; Return to client details<a/></p>]);
}

my %doc_types_categories = $client->documents->categories->%*;
my @poi_doctypes         = $client->documents->poi_types->@*;
my @poa_doctypes         = $client->documents->poa_types->@*;
my @pow_doctypes         = $client->documents->pow_types->@*;
my @dateless_doctypes    = $client->documents->dateless_types->@*;
my @expirable_doctypes   = $client->documents->expirable_types->@*;
my %document_type_sides  = $client->documents->sided_types->%*;
my %document_sides       = $client->documents->sides->%*;
my @numberless_doctypes  = $client->documents->numberless->@*;
my @onfido_doctypes      = keys $client->documents->provider_types->{onfido}->%*;
my $is_readonly          = BOM::Backoffice::Auth::has_readonly_access();
my $button_type          = $is_readonly ? 'btn btn--disabled' : 'btn btn--primary';
code_exit_BO(_get_display_error_message("Access Denied: you do not have access to make this change "))
    if $is_readonly and request()->http_method eq 'POST';
# Enabling onfido resubmission
my $redis             = BOM::Config::Redis::redis_replicated_write();
my $poi_status_reason = $input{poi_reason} // $client->status->reason('allow_poi_resubmission') // 'unselected';
# Add a comment about kyc email checkbox
$poi_status_reason = join(' ', $poi_status_reason, $input{kyc_email_checkbox} ? 'kyc_email' : ()) unless $poi_status_reason =~ /\skyc_email$/;

# POA address mismatch

if ($broker ne 'MF' and defined $input{address_mismatch}) {
    if ($input{address_mismatch} && $input{expected_address}) {
        my $expected_address = $input{expected_address};

        # Remove non alphanumeric
        $expected_address =~ s/[^a-zA-Z0-9 ]//g;

        unless ($expected_address) {
            print "<p class=\"notify notify--warning\">You must specify the expected address.</p>";
            code_exit_BO(qq[<p><a href="$self_href" class="link">&laquo; Return to client details<a/></p>]);
        }

        $client->documents->poa_address_mismatch({
            expected_address => $expected_address,
            staff            => $clerk,
            reason           => 'Client POA address mismatch found in BO',
        });
    } else {
        $client->documents->poa_address_mismatch_clear;
    }
}

# POI resubmission logic
if ($input{allow_onfido_resubmission} or $input{poi_reason}) {
    #this also allows the client only 1 time to resubmit the documents
    if (   !$client->status->reason('allow_poi_resubmission')
        && BOM::User::Onfido::submissions_left($client) == 0
        && !$redis->get(ONFIDO_RESUBMISSION_COUNTER_KEY_PREFIX . $client->binary_user_id))
    {

        BOM::Config::Redis::redis_events()->incrby(ONFIDO_REQUEST_PER_USER_PREFIX . $client->binary_user_id, -1);
    }
    $client->propagate_status('allow_poi_resubmission', $clerk, $poi_status_reason);
} elsif (defined $input{allow_onfido_resubmission}) {    # resubmission is unchecked
    $client->propagate_clear_status('allow_poi_resubmission');
    if (BOM::User::Onfido::submissions_left($client) == 1) {

        BOM::Config::Redis::redis_events()->incrby(ONFIDO_REQUEST_PER_USER_PREFIX . $client->binary_user_id, 1);
    }
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

my $poinc_status_reason = $input{poinc_reason} // $client->status->reason('allow_poinc_resubmission') // 'unselected';

if ($input{allow_poinc_resubmission} or $input{poinc_reason}) {
    $client->propagate_status('allow_poinc_resubmission', $clerk, $poinc_status_reason);
} elsif (defined $input{allow_poinc_resubmission}) {
    $client->propagate_clear_status('allow_poinc_resubmission');
} elsif ($client->status->allow_poinc_resubmission) {
    $client->propagate_status('allow_poinc_resubmission', $clerk, $poinc_status_reason);
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
    unless (BOM::Config::Onfido::is_country_supported(uc($client->place_of_birth || $client->residence // ''))) {
        print "<p class=\"notify notify--warning\">Onfido is not supported on this country.</p>";
        code_exit_BO(qq[<p><a href="$self_href" class="link">&laquo; Return to client details<a/></p>]);
    }

    if (BOM::User::Onfido::pending_request($client->binary_user_id)) {
        print "<p class=\"notify notify--warning\">There is a pending Onfido request for this client.</p>";
        code_exit_BO(qq[<p><a href="$self_href" class="link">&laquo; Return to client details<a/></p>]);
    }

    my $applicant_data = BOM::User::Onfido::get_user_onfido_applicant($client->binary_user_id);
    my $applicant_id   = $applicant_data->{id};
    unless ($applicant_id) {
        print "<p class=\"notify notify--warning\">No corresponding onfido applicant id found for client $loginid.</p>";
        code_exit_BO(qq[<p><a href="$self_href" class="link">&laquo; Return to client details<a/></p>]);
    }

    my $document_to_check = BOM::User::Onfido::get_onfido_document($client->binary_user_id, $applicant_id);
    unless ($document_to_check) {
        print "<p class=\"notify notify--warning\">No corresponding document for the applicant id found for client $loginid.</p>";
        code_exit_BO(qq[<p><a href="$self_href" class="link">&laquo; Return to client details<a/></p>]);
    }

    if ($client->is_face_similarity_required) {
        my $selfie_to_check = BOM::User::Onfido::get_onfido_live_photo($client->binary_user_id, $applicant_id);
        unless ($selfie_to_check) {
            print "<p class=\"notify notify--warning\">No corresponding selfie for the applicant id found for client $loginid.</p>";
            code_exit_BO(qq[<p><a href="$self_href" class="link">&laquo; Return to client details<a/></p>]);
        }
    }

    BOM::User::Onfido::ready_for_authentication(
        $client,
        {
            staff_name => $clerk,    # this will hint bom-events to bypass document validations as we dont have that info from BO
        });

    print "<p class=\"notify\">Onfido trigger request sent.</p>";
    code_exit_BO(qq[<p><a href="$self_href">&laquo; Return to client details<a/></p>]);
}

my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->binary_user_id);

if (defined $input{idv_reset}) {
    $idv_model->reset_attempts();
    print "<p class=\"notify\">The IDV attempts have been succesfully reset.</p>";
    code_exit_BO(qq[<p><a href="$self_href">&laquo; Return to client details<a/></p>]);
}

if (defined $input{run_idv_check}) {
    my $standby_document = $idv_model->get_standby_document();

    unless ($standby_document) {
        print "<p class=\"notify notify--warning\">No standby document found for client $loginid.</p>";
        code_exit_BO(qq[<p><a href="$self_href" class="link">&laquo; Return to client details<a/></p>]);
    }

    unless ($idv_model->submissions_left) {
        print "<p class=\"notify notify--warning\">No IDV submissions left for client $loginid.</p>";
        code_exit_BO(qq[<p><a href="$self_href" class="link">&laquo; Return to client details<a/></p>]);
    }

    $idv_model->identity_verification_requested($client);

    print "<p class=\"notify\">Identity verification request sent.</p>";
    code_exit_BO(qq[<p><a href="$self_href">&laquo; Return to client details<a/></p>]);
}

my $is_compliance = BOM::Backoffice::Auth::has_authorisation(['Compliance']);

if (defined $input{request_risk_screen}) {
    code_exit_BO(qq[<p><a href="$self_href">&laquo; This feature is for real accounts only.<a/></p>])
        if $client->is_virtual;

    code_exit_BO(qq[<p><a href="$self_href">&laquo; This feature is available for compliance team only.<a/></p>])
        unless $is_compliance;

    code_exit_BO(qq[<p><a href="$self_href">&laquo; Screening is not possible without proof of identity.<a/></p>])
        unless $client->status->age_verification();

    $client->user->set_lexis_nexis(
        client_loginid => $client->loginid,
        alert_status   => 'requested',
        note           => $input{screening_reason_select} || undef,
        date_added     => Date::Utility->new->datetime
    );

    print "<p class=\"notify\">Screening requested. It will be enabled within 24 hours.</p>";
    code_exit_BO(qq[<p><a href="$self_href">&laquo; Return to client details<a/></p>]);
}

sub find_risk_screen {
    my (%args) = @_;

    my @search_fields = qw/binary_user_id client_entity_id status/;

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;
    my $rows = $dbic->run(
        fixup => sub {
            return $_->selectall_arrayref('select * from users.get_risk_screen(?,?,?)', {Slice => {}}, @args{@search_fields});
        });

    return @$rows;
}

if (defined $input{show_aml_screen_table}) {
    my ($risk_screen) = find_risk_screen(binary_user_id => $client->user->id);

    $risk_screen->{flags_str} = join(',', $risk_screen->{flags}->@*) if $risk_screen && $risk_screen->{flags};

    my $lexis_nexis = $client->user->lexis_nexis;
    BOM::Backoffice::Request::template()->process(
        'backoffice/client_edit_aml_screening_table.html.tt',
        {
            risk_screen    => $risk_screen,
            lexis_nexis    => $lexis_nexis,
            sanction_check => $client->sanctions_check
        },
    ) || die BOM::Backoffice::Request::template()->error(), "\n";

    code_exit_BO(qq[<p><a href="$self_href">&laquo; Return to client details<a/></p>]);
}

if ($input{document_list}) {
    my $new_doc_status;
    my $poa_updated;
    my $poi_updated;
    $new_doc_status = 'rejected'         if $input{reject_checked_documents};
    $new_doc_status = 'verified'         if $input{verify_checked_documents};
    $new_doc_status = 'delete'           if $input{delete_checked_documents};
    $new_doc_status = 'address mismatch' if $input{address_mismatch_checked_documents};
    code_exit_BO(qq[<p><a href="$self_href">&laquo; Document update status not specified<a/></p>]) unless $new_doc_status;
    code_exit_BO(_get_display_error_message("Access Denied: you do not have access to make this change ")) if $is_readonly;

    my $documents = $input{document_list};
    my @documents = ref $documents ? @$documents : ($documents);
    my $loginid   = $client->loginid;
    my $full_msg  = "";
    my $client;

    for my $document (@documents) {
        next unless $document;

        my ($doc_id, $doc_loginid, $file_name) = $document =~ m/([0-9]+)-([A-Z0-9]+)-(.+)/;

        if ((not defined $client) or ($client->loginid ne $doc_loginid)) {
            $client = BOM::User::Client::get_instance({loginid => $doc_loginid});
        }

        if (!$client) {
            $full_msg .= "<div class=\"notify notify--warning\"><b>ERROR:</b> with client login <b>$loginid</b></div>";
            next;
        }

        $client->set_db('write');
        my ($doc) = $client->find_client_authentication_document(query => [id => $doc_id]);    # Rose
        if (!$doc) {
            $full_msg .= "<div class=\"notify notify--warning\">ERROR: could not find $file_name record in db</div>";
            next;
        }

        my $is_poa = any { $_ eq $doc->document_type } $client->documents->poa_types->@*;
        $poi_updated ||= any { $_ eq $doc->document_type } $client->documents->poi_types->@*;
        $poa_updated ||= $is_poa;

        if ($new_doc_status eq 'delete') {
            if ($doc->delete) {
                $full_msg .= "<div class=\"notify\"><b>SUCCESS</b> - $file_name is <b>deleted</b>!</div>";
            } else {
                $full_msg .= "<div class=\"notify notify--warning\"><b>ERROR:</b> did not remove <b>$file_name</b> record from db</div>";
            }

            next;
        }

        my $issuance = $input{'issuance_' . $doc_id} // ($doc->lifetime_valid ? 'lifetime_valid' : 'issuance_date');
        my $field_error;

        # Update other fields as well
        foreach my $field ('issue_date', 'document_id', 'comments') {
            my $input_key = $field . '_' . $doc_id;

            if (defined $input{$input_key}) {
                my $to_update_value = $input{$input_key};

                if ($field eq 'issue_date') {
                    if ($issuance eq 'issuance_date') {
                        if ($to_update_value ne (eval { Date::Utility->new($to_update_value)->date_yyyymmdd; } // '')) {
                            $full_msg .=
                                "<div class=\"notify notify--warning\"><b>ERROR: $file_name has an invalid date format <b>$to_update_value</b>, please use yyyy-mm-dd</div>";
                            $field_error = 1;
                            next;
                        }

                        if (Date::Utility->new($to_update_value)->is_before(Date::Utility->new->minus_time_interval('1y'))) {
                            $full_msg .=
                                "<div class=\"notify notify--warning\"><b>ERROR: $file_name is too old, it must have been issued within the last 12 months.</div>";
                            $field_error = 1;
                            next;
                        }
                    } else {
                        $to_update_value = undef;
                    }
                }

                $doc->$field($to_update_value) unless $field_error;
            }
        }

        if ($is_poa && !$field_error) {
            $doc->lifetime_valid($issuance eq 'lifetime_valid' ? 1 : 0);
            $doc->save;
        }

        if ($new_doc_status eq 'address mismatch') {
            if ($broker ne 'MF') {
                if ($is_poa) {
                    $doc->address_mismatch(1);
                    $doc->save;

                    $full_msg .=
                        "<div class=\"notify\"><b>SUCCESS</b> - $file_name has been tagged as <b>$new_doc_status</b>. Once its resolved documents will be automatically verified!</div>";
                } else {
                    $full_msg .= "<div class=\"notify notify--warning\"><b>ERROR:<b>$new_doc_status</b> only applies for poa documents</div>";
                }

            }

            next;
        }

        my $verified_date = Date::Utility->new->date_yyyymmdd;
        $doc->verified_date($verified_date) if $new_doc_status eq 'verified' && !$field_error;

        $doc->status($new_doc_status) unless $field_error;

        $full_msg .= (
            $doc->save
            ? "<div class=\"notify\"><b>SUCCESS</b> - $file_name has been <b>$new_doc_status</b>!</div>"
            : "<div class=\"notify notify--warning\"><b>ERROR:</b> did not update <b>$file_name</b> record from db</div>"
        ) unless $field_error;
    }
    print $full_msg;
    %input = ();    # stay in the same page and avoid side effects

    if ($client->documents->is_poa_verified) {
        $client->propagate_status('address_verified', $clerk, 'At least 1 PoA document has been verified');
    } else {
        $client->propagate_clear_status('address_verified');
    }

    BOM::Platform::Event::Emitter::emit('poi_updated', {loginid => $client->loginid}) if $poi_updated;
    BOM::Platform::Event::Emitter::emit('poa_updated', {loginid => $client->loginid}) if $poa_updated;
    if ($client->landing_company->first_deposit_auth_check_required) {
        _update_mt5_status($client);
    }
}

# Deleting checked statuses
my $status_op_summary = BOM::Platform::Utility::status_op_processor($client, \%input);
print BOM::Backoffice::Utility::transform_summary_status_to_html($status_op_summary, $input{status_op}) if $status_op_summary;

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
                },
                origin => 'system',
            }};
        BOM::Platform::Event::Emitter::emit('profile_change', $event_args);
    }
}

if ($input{reject_proof_of_ownership}) {
    try {
        $client->proof_of_ownership->reject({id => $input{reject_proof_of_ownership}});
    } catch ($e) {
        print qq[<p class="notify notify--warning">Could not reject proof of ownership: $e.</p>];
        code_exit_BO(qq[<p><a class="link" href="$self_href">&laquo; Return to client details<a/></p>]);
    }
}

if ($input{verify_proof_of_ownership}) {
    try {
        $client->proof_of_ownership->verify({id => $input{verify_proof_of_ownership}});
    } catch ($e) {
        print qq[<p class="notify notify--warning">Could not verify proof of ownership: $e.</p>];
        code_exit_BO(qq[<p><a class="link" href="$self_href">&laquo; Return to client details<a/></p>]);
    }
}

if ($input{delete_proof_of_ownership}) {
    try {
        $client->proof_of_ownership->delete({id => $input{delete_proof_of_ownership}});
    } catch ($e) {
        print qq[<p class="notify notify--warning">Could not delete proof of ownership: $e.</p>];
        code_exit_BO(qq[<p><a class="link" href="$self_href">&laquo; Return to client details<a/></p>]);
    }
}

if ($input{resubmit_proof_of_ownership}) {
    try {
        $client->proof_of_ownership->resubmit({id => $input{resubmit_proof_of_ownership}});
    } catch ($e) {
        print qq[<p class="notify notify--warning">Could not delete proof of ownership: $e.</p>];
        code_exit_BO(qq[<p><a class="link" href="$self_href">&laquo; Return to client details<a/></p>]);
    }
}

if (BOM::Backoffice::Auth::has_authorisation(['AntiFraud', 'CS'])) {
    # access granted
    my $poo_requests = {};

    for my $key (keys %input) {
        my ($trace_id) = $key =~ /^poo\[(.*)\]$/;

        if ($trace_id) {
            my $payment_method = $input{$key};
            $poo_requests->{$trace_id} = $payment_method;
        }
    }

    if (scalar keys $poo_requests->%*) {
        for my $trace_id (keys $poo_requests->%*) {
            try {
                $client->set_db('write') unless $client->get_db() eq 'write';
                $client->proof_of_ownership->create({
                    payment_service_provider => $poo_requests->{$trace_id},
                    trace_id                 => $trace_id,
                    comment                  => ''
                });
            } catch ($e) {
                $e = 'Cannot create duplicates' if $e =~ /duplicate key value violates unique constraint/;
                print qq[<p class="notify notify--warning">Could not request POO: $e.</p>];
                code_exit_BO(qq[<p><a class="link" href="$self_href">&laquo; Return to client details<a/></p>]);
            }
        }
    }

    # Logic for updating poo comments

    my $poo_comments = [];

    for my $key (keys %input) {
        my ($poo_id) = $key =~ /^poo_comment_(.*)$/;

        if ($poo_id) {
            my $poo_comment = $input{$key};
            push @$poo_comments,
                {
                id      => $poo_id,
                comment => $poo_comment
                };
        }
    }

    # call user proof update comment
    if (scalar $poo_comments->@*) {
        try {
            $client->set_db('write') unless $client->get_db() eq 'write';
            $client->proof_of_ownership->update_comments({poo_comments => $poo_comments});
        } catch ($e) {
            $e = 'Cannot create duplicates' if $e =~ /duplicate key value violates unique constraint/;
            print qq[<p class="notify notify--warning">Could not request POO: $e.</p>];
            code_exit_BO(qq[<p><a class="link" href="$self_href">&laquo; Return to client details<a/></p>]);
        }
    }
}

# sync authentication status to Doughflow
if ($input{whattodo} eq 'sync_to_DF' && !$is_readonly) {
    my $error = sync_to_doughflow($client, $clerk);

    Bar('SYNC CLIENT AUTHENTICATION STATUS TO DOUGHFLOW');
    if ($error) {
        BOM::Backoffice::Request::template()->process(
            'backoffice/client_edit_msg.tt',
            {
                message  => $error,
                error    => 1,
                self_url => $self_href,
            },
        ) || die BOM::Backoffice::Request::template()->error(), "\n";
        code_exit_BO();
    } else {
        BOM::Backoffice::Request::template()->process(
            'backoffice/client_edit_msg.tt',
            {
                message  => "Successfully syncing client authentication status to Doughflow",
                self_url => $self_href,
            },
        ) || die BOM::Backoffice::Request::template()->error(), "\n";
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
    ) || die BOM::Backoffice::Request::template()->error(), "\n";
    code_exit_BO();
}

# sync authentication status to MT5
if ($input{whattodo} eq 'sync_to_MT5') {
    BOM::Platform::Event::Emitter::emit('sync_user_to_MT5', {loginid => $loginid});
    my $msg = Date::Utility->new->datetime . " sync client information to MT5 is requested by clerk=$clerk $ENV{REMOTE_ADDR}";
    BOM::User::AuditLog::log($msg, $loginid, $clerk);

    Bar('SYNC CLIENT INFORMATION TO MT5');
    BOM::Backoffice::Request::template()->process(
        'backoffice/client_edit_msg.tt',
        {
            message  => "Successfully requested syncing client information to MT5",
            self_url => $self_href,
        },
    ) || die BOM::Backoffice::Request::template()->error(), "\n";
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
        my $is_poa       = any { $_ eq $doctype } @poa_doctypes;
        my $is_expirable = any { $_ eq $doctype } @expirable_doctypes;
        my $dateless_doc = any { $_ eq $doctype } @dateless_doctypes;

        my $issuance        = $cgi->param('issuance_' . $i) // '';
        my $filetoupload    = $cgi->upload('FILE_' . $i);
        my $page_type       = $cgi->param('page_type_' . $i);
        my $issue_date      = $is_expirable  || $dateless_doc || $issuance eq 'lifetime_valid' ? undef : $cgi->param('issue_date_' . $i);
        my $expiration_date = !$is_expirable || $dateless_doc ? undef : $cgi->param('expiration_date_' . $i);
        my $document_id     = $input{'document_id_' . $i}     // '';
        my $comments        = $input{'comments_' . $i}        // '';
        my $expiration      = $cgi->param('expiration_' . $i) // '';
        my $lifetime_valid  = $is_poi ? $expiration eq 'lifetime_valid' : $issuance eq 'lifetime_valid';
        $expiration_date = undef unless $expiration eq 'expiration_date';
        next unless $filetoupload;

        if (   $expiration_date
            && $expiration_date ne (eval { Date::Utility->new($expiration_date)->date_yyyymmdd } // ''))
        {
            print qq[<p class="notify notify--warning">Expiration date "$expiration_date" is not a valid date.</p>];
            code_exit_BO(qq[<p><a class="link" href="$self_href">&laquo; Return to client details<a/></p>]);
        } elsif ($issue_date
            && $issue_date ne (eval { Date::Utility->new($issue_date)->date_yyyymmdd; } // ''))
        {
            print qq[<p class="notify notify--warning">Issue date "$issue_date" is not a valid date.</p>];
            code_exit_BO(qq[<p><a class="link"href="$self_href">&laquo; Return to client details<a/></p>]);
        } elsif ($issue_date
            && Date::Utility->new($issue_date)->is_before(Date::Utility->new->minus_time_interval('1y')))
        {
            print
                qq[<p class="notify notify--warning">ERROR: Issue date "$issue_date" is too old, it must have been issued within the last 12 months.</p>];
            code_exit_BO(qq[<p><a class="link"href="$self_href">&laquo; Return to client details<a/></p>]);
        }

        if ($is_poi and not $expiration_date and $expiration eq 'expiration_date') {
            print qq[<p class="notify notify--warning">Expiration date is missing for the POI document $doctype.</p>];
            code_exit_BO(qq[<p><a class="link" href="$self_href">&laquo; Return to client details<a/></p>]);
        }

        if ($is_poa and not $issue_date and $issuance eq 'issuance_date') {
            print qq[<p class="notify notify--warning">Issuance date is missing for the POA document $doctype.</p>];
            code_exit_BO(qq[<p><a class="link" href="$self_href">&laquo; Return to client details<a/></p>]);
        }

        if ($docnationality and $docnationality =~ /^[a-z]{2}$/i) {
            $client->citizen($docnationality);
        }

        unless ($client->get_db eq 'write') {
            $client->set_db('write');
        }

        if (not $client->save) {
            print "<p class=\"notify notify--warning\">Failed to save client citizenship.</p>";
            code_exit_BO(qq[<p><a class="link" href="$self_href">&laquo; Return to client details</a></p>]);
        }

        my $file_checksum         = Digest::MD5->new->addfile($filetoupload)->hexdigest;
        my $abs_path_to_temp_file = $cgi->tmpFileName($filetoupload);
        my $mime_type             = $cgi->uploadInfo($filetoupload)->{'Content-Type'};
        my ($file_ext)            = $cgi->param('FILE_' . $i) =~ /\.([^.]+)$/;
        my $file_size             = (-s $abs_path_to_temp_file) / MB_IN_BYTES;

        if (any { $doctype eq $_ } @onfido_doctypes && $file_size > ONFIDO_DOCUMENT_SIZE_LIMIT_IN_MB) {
            $result .=
                  qq{<p class="notify notify--warning">Error Uploading File $i: the upload limit is }
                . ONFIDO_DOCUMENT_SIZE_LIMIT_IN_MB
                . qq{ MB for document type $doctype</p>};
            next;
        } elsif ($file_size > DOCUMENT_SIZE_LIMIT_IN_MB) {
            $result .=
                  qq{<p class="notify notify--warning">Error Uploading File $i: the upload limit is }
                . DOCUMENT_SIZE_LIMIT_IN_MB
                . qq{ MB for document type $doctype</p>};
            next;
        }

        # try to get file extension from mime type, else get it from filename
        my $docformat = lc($mts->ext_from_type($mime_type) // $file_ext);

        my $upload_info;
        try {
            $upload_info = $client->db->dbic->run(
                ping => sub {
                    $_->selectrow_hashref(
                        'SELECT * FROM betonmarkets.start_document_upload(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)', undef,
                        $loginid,                                                                               $doctype,
                        $docformat,                                                                             $expiration_date || undef,
                        $document_id,                                                                           $file_checksum,
                        $comments,                                                                              $page_type || '',
                        $issue_date || undef, $lifetime_valid ? 1 : 0,
                        'bo', $docnationality
                    );
                });
            die 'Document already exists.' unless $upload_info;
        } catch ($e) {
            $result .= "<p class=\"notify notify--warning\">Error Uploading File $i: $e</p>";
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
                } catch ($e) {
                    $err = 'Document upload failed on finish';
                    $log->warn($err . $e);
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
            $result .= "<p class=\"notify\">Successfully uploaded $file_name</p>";
        } elsif ($f->is_failed) {
            my $failure = $f->failure;
            $result .= "<p class=\"notify notify--warning\">Error Uploading Document $file_name: $failure. </p>";
        }
    }
    print $result;
    if ($client->landing_company->first_deposit_auth_check_required) {
        _update_mt5_status($client);
    }
    code_exit_BO(qq[<p><a class="link" href="$self_href">&laquo; Return to client details</a></p>]);
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
            $result .= "<p class=\"notify\">Updated client limit for $cashier</p>\n";
        } catch ($e) {
            $result .= "<p class=\"notify notify--warning\">Error saving reversible limit: $e.</p>\n";
        }
    }

    if ($result) {
        print $result;
        code_exit_BO(qq[<p><a class="link" href="$self_href">&laquo; Return to client details</a></p>]);
    }
}

# Disabe 2FA if theres is a request for that.
if ($input{whattodo} eq 'disable_2fa' and $user->is_totp_enabled) {
    $user->update_totp_fields(
        is_totp_enabled => 0,
        secret_key      => ''
    );

    print "<p class=\"notify\">2FA Disabled</p>";
    code_exit_BO(qq[<p><a class="link" href="$self_href">&laquo; Return to client details</a></p>]);
}

# SAVE EDD STATUS
if ($input{whattodo} eq 'save_edd_status') {
    my $startdate = $input{edd_start_date};
    my $enddate   = $input{edd_last_review_date};

    # start_date is nullable
    if ($startdate) {
        try {
            $startdate = Date::Utility->new($startdate)->date;
        } catch ($e) {
            code_exit_BO("Cannot parse EDD start date: $startdate: $e");
        }
    } else {
        $startdate = undef;
    }

    # last_review_date is nullable
    if ($enddate) {
        # if $enddate has some value, validate the date
        try {
            $enddate = Date::Utility->new($enddate)->date;
        } catch ($e) {
            code_exit_BO("Cannot parse EDD last review date: $enddate: $e");
        }
    } else {
        $enddate = undef;
    }

    my $average_earnings = undef;
    if (length $input{edd_average_earnings_currency} and length $input{edd_average_earnings_amount}) {
        $average_earnings = {
            currency => $input{edd_average_earnings_currency},
            amount   => $input{edd_average_earnings_amount},
        };
    }

    try {
        my $edd_status = $input{edd_status};

        $user->update_edd_status(
            status           => $edd_status,
            start_date       => $startdate,
            last_review_date => $enddate,
            average_earnings => $average_earnings,
            comment          => $input{edd_comment},
            reason           => $input{edd_reason});

        my $unwelcome_reason             = "Pending EDD docs/info for withdrawal request";
        my $disabled_reason              = "Failed to submit EDD docs/info for withdrawal request";
        my $allow_document_upload_reason = "Pending EDD docs/info";

        my @clients_to_update = $client->is_virtual ? () : grep { not $_->is_virtual } $user_clients->@*;

        if ($input{edd_reason}) {
            $unwelcome_reason .= " - [Compliance] : ** $input{edd_reason} **";
            $disabled_reason  .= " - [Compliance] : ** $input{edd_reason} **";
        }
        foreach my $client_to_update (@clients_to_update) {
            # trigger unwlecome when EDD status = 'in_progress' or 'pending'
            # remove unwlecome when EDD status = 'passed', 'n/a', 'contacted'
            # trigger disable when EDD status = 'failed'
            if ($edd_status eq 'passed') {
                if ($client_to_update->status->reason('unwelcome') eq $unwelcome_reason) {
                    $client_to_update->status->clear_unwelcome();
                }
                if ($client_to_update->status->reason('disabled') eq $disabled_reason) {
                    $client_to_update->status->clear_disabled();
                }
                if ($client_to_update->status->reason('allow_document_upload') eq $allow_document_upload_reason) {
                    $client_to_update->status->clear_allow_document_upload();
                }
            } elsif ($edd_status eq 'contacted' or $edd_status eq 'n/a') {
                if ($client_to_update->status->reason('unwelcome') eq $unwelcome_reason) {
                    $client_to_update->status->clear_unwelcome();
                }
                if ($client_to_update->status->reason('disabled') eq $disabled_reason) {
                    $client_to_update->status->clear_disabled();
                }

            } elsif (any { $_ eq $edd_status } qw(in_progress pending)) {
                $client_to_update->status->setnx('unwelcome', BOM::Backoffice::Auth::get_staffname(), $unwelcome_reason);
                if ($client_to_update->status->reason('disabled') eq $disabled_reason) {
                    $client_to_update->status->clear_disabled();
                }
            } elsif (any { $_ eq $edd_status } qw(failed)) {
                $client_to_update->status->setnx('disabled', BOM::Backoffice::Auth::get_staffname(), $disabled_reason);
                if ($client_to_update->status->reason('unwelcome') eq $unwelcome_reason) {
                    $client_to_update->status->clear_unwelcome();
                }
            }
        }
    } catch ($e) {
        code_exit_BO("Cannot update EDD status: $e");
    }

}

if ($input{whattodo} eq 'copy_pa_details') {
    my $pa = $client->get_payment_agent;

    code_exit_BO("Payment agent not found") unless $pa;
    my @sibling_pas = $pa->sibling_payment_agents;
    code_exit_BO("There is no payment agent to copy details to.") unless scalar @sibling_pas > 1;

    for my $sibling (@sibling_pas) {
        next if $sibling->client_loginid eq $client->loginid;
        eval { $pa->copy_details_to($sibling) }
            ? print("<p class=\"success\">PA details copied to " . $sibling->client_loginid . "</p>")
            : print("<p class=\"error\">Failed to copy PA details to " . $sibling->client_loginid . "</p>");
    }
}

# AFFILIATE COC APPROVAL & RISK DISCLAIMER EMAIL
if ($is_compliance) {
    if ($input{risk_disclaimer_email_checkbox} eq 'on') {
        if ($client->user->affiliate) {
            my $lang = $input{risk_disclaimer_email_language} // 'EN';
            notify_resubmission_of_risk_disclaimer($loginid, $lang, $clerk);
            print "<p class=\"success\">Risk Disclaimer Resubmission email (" . $lang . ") is sent to Client " . $client->loginid . "</p>";
        } else {
            print "<p class=\"error\">Client " . $client->loginid . " is not an affiliate.</p>";
        }
    }

    if (defined $input{force_coc_acknowledgement}) {
        if ($client->user->affiliate) {
            $client->user->set_affiliate_coc_approval(0);
            print "<p class=\"success\">Client " . $client->loginid . " Affiliate's Code of Conduct approval banner triggered.</p>";
        } else {
            print "<p class=\"error\">Client " . $client->loginid . " is not an affiliate.</p>";
        }
    }
}

my $skip_loop_all_clients =
    (defined $input{force_coc_acknowledgement} || defined $input{risk_disclaimer_email_checkbox});

# SAVE DETAILS
# TODO:  Once we switch to userdb, we will not need to loop through all clients
if ($input{edit_client_loginid} =~ /^\D+\d+$/ and not $skip_loop_all_clients) {

    # Trimming immutable text fields to avoid whitespaces which causes problems while creating a real account
    # If there are white spaces added from BO, then while creating a real account, the request has trimmed values,
    # which is considered as non equal for immutable fields.
    my @text_immutable_fields = qw/first_name
        last_name
        secret_answer
        secret_question
        tax_identification_number
        city
        address_1
        address_2
        address_postcode
        phone
        /;

    map { $input{$_} = trim($input{$_}) if defined $input{$_} } @text_immutable_fields;

    my $poa_updated;
    my $poi_updated;
    my $error;
    # algorithm provide different encrypted string from the same text based on some randomness
    # so we update this encrypted field only on value change - we don't want our trigger log trash
    my $secret_answer = '';
    try {
        $secret_answer = BOM::User::Utility::decrypt_secret_answer($client->secret_answer) // '';
    } catch ($e) {
        print qq{<p class=\"notify notify--warning\">ERROR: Unable to extract secret answer. Client secret answer is outdated or invalid.</p>};
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
                print qq{<p class="notify notify--warning">ERROR: <b>$info->{name}</b> validation failed: $info->{message}</p>};
                $error = 1;
            }
        }
    }
    code_exit_BO(qq[<p><a class="link" href="$self_href">&laquo; Return to client details</a></p>]) if ($error);

    _assemble_dob_input({
        client => $client,
        input  => \%input,
    });
    # Active client specific update details:
    my $auth_method = 'dummy';
    if ($input{client_authentication}) {
        $auth_method = $input{client_authentication};
        $client->set_authentication_and_status($auth_method, $clerk);
        _update_mt5_status($client) if any { $auth_method eq $_ } qw/ID_DOCUMENT NEEDS_ACTION/;
    }
    if ($input{age_verification} and not $client->is_virtual) {
        my @allowed_lc_to_sync = @{$client->landing_company->allowed_landing_companies_for_age_verification_sync};

        # Apply age verification for one client per each landing company since we have a DB trigger that sync age verification between the same landing companies.
        my @clients_to_update =
            map { [$client->user->clients_for_landing_company($_)]->[0] // () } @allowed_lc_to_sync;
        push @clients_to_update, $client;

        # uk clients need to be age verified to trade synthetics in vr
        push @clients_to_update, BOM::User::Client->new({loginid => $client->user->bom_virtual_loginid}) if $client->residence eq 'gb';

        foreach my $client_to_update (@clients_to_update) {
            if ($input{'age_verification'} eq 'yes') {
                $client_to_update->status->clear_df_deposit_requires_poi;
                $client_to_update->status->setnx('age_verification', $clerk, 'Age verified client from Backoffice.');
            } else {
                $client_to_update->status->clear_age_verification;
            }
        }

        $client->update_status_after_auth_fa();

        _update_mt5_status($client) if $input{'age_verification'} eq 'yes';
    }

    if (exists $input{client_categorization}) {
        try {
            if ($input{client_categorization} eq 'counterparty') {
                set_client_status(
                    $client, ['eligible_counterparty'],
                    ['professional', 'professional_requested', 'professional_rejected'],
                    'Client Marked as eligible counterparty', $clerk
                );
            } else {
                my $client_categorization = $input{client_categorization} eq 'professional' ? 'professional' : 'retail';
                goto $client_categorization;

                retail:
                my $status_to_clear = $client->status->eligible_counterparty ? ['eligible_counterparty'] : ['professional'];
                my $status_to_set   = $client->status->eligible_counterparty ? []                        : ['professional_rejected'];
                set_client_status($client, $status_to_set, $status_to_clear, 'Revoke professional status', $clerk);

                professional:
                set_client_status(
                    $client, ['professional'],
                    ['eligible_counterparty', 'professional_requested', 'professional_rejected'],
                    'Client Marked as professional as requested', $clerk
                ) if $client_categorization eq 'professional';

            }

        } catch ($e) {
            # Print clients that were not updated
            print "<p class=\"notify notify--warning\">Failed to update professional status of client: $loginid $e</p>";
        }
    }

    # TODO: Remove this once the transition is done from redis to client object
    if (my $sr_risk_val = $input{client_social_responsibility_check}) {
        if ($client->landing_company->social_responsibility_check eq 'required') {

            my $key_name = $loginid . ':sr_risk_status';
            my $redis    = BOM::Config::Redis::redis_events_write();

            # There is no need to store clients with low risk in redis, as it is default
            # and also: if the status is changed from high, we don't need the expiry time
            # also when client is risk_status "low", we need to resend the emails for breached thresholds
            if ($sr_risk_val eq 'low') {
                $redis->del($key_name);
                $redis->del($loginid . ':sr_check:losses:email');
                $redis->del($loginid . ':sr_check:net_deposits:email');
            } else {
                $redis->set($key_name, $sr_risk_val);
            }

            _update_mt5_status($client);
        } elsif ($client->landing_company->social_responsibility_check eq 'manual') {
            BOM::User::SocialResponsibility->update_sr_risk_status($user->id, $sr_risk_val);
            _update_mt5_status($client);
        }

    }

    # client promo_code related fields
    if (exists $input{promo_code}) {
        if (BOM::Backoffice::Auth::has_authorisation(['Marketing'])) {

            if (my $promo_code = uc $input{promo_code}) {
                my $encoded_promo_code = encode_entities($promo_code);
                my %pcargs             = (
                    code   => $promo_code,
                    broker => $broker
                );

                # add or update client promo code
                try {
                    $client->promo_code($promo_code);
                } catch ($e) {
                    code_exit_BO(sprintf('<p class="error">ERROR: %s</p>', $_));
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
            code_exit_BO('<p class="error">ERROR: Not a valid account opening reason.</p>');
        }
    }

    # Prior to duplicate check and storing, strip off trailing and leading whitespace
    $error = $client->format_input_details(\%input);

    # Perform additional checks, but only for non-virtual accounts
    if (not $error and not $client->is_virtual) {
        $error = $client->validate_common_account_details({
            secret_answer   => $secret_answer,
            secret_question => $client->secret_question,
            %input,
        });
    }

    if ($error) {
        my $message   = $error->{error};
        my $err_field = $error->{details}->{field} // '';
        $err_field = " on $err_field" if $err_field;

        print "<p class='notify notify--warning'>ERROR: $message $err_field</p>";
        code_exit_BO("<p><a class='link' href='$self_href'>&laquo; Return to client details</a></p>");
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
            or die BOM::Backoffice::Request::template()->error(), "\n";

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
            print
                qq{<p class="notify notify--warning">Invalid residence change, due to different broker codes or different country restrictions.</p>};
            code_exit_BO(qq[<p><a class="link" href="$self_href">&laquo; Return to client details</a></p>]);
        }

        if ($new_residence eq 'gb' and $client->status->age_verification) {
            my $vr_client = BOM::User::Client->new({loginid => $client->user->bom_virtual_loginid});
            $vr_client->status->setnx('age_verification', $clerk, 'VR age verified due to residence change.');
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
                code_exit_BO("<p class=\"error\">ERROR ! $_ field appears incorrect or empty.</p></p>");
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
            address_postcode
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
            if (my ($document_field, $id) = $key =~ /^(expiration|expiration_date|issue_date|comments|document_id|issuance)_([0-9]+)$/) {
                $key            = 'expiration_date_' . $id if $document_field eq 'expiration';
                $document_field = 'expiration_date'        if $document_field eq 'expiration';
                $key            = 'issue_date_' . $id      if $document_field eq 'issuance';
                $document_field = 'issue_date'             if $document_field eq 'issuance';

                my $val = ($document_field =~ /^(expiration_date|issue_date)$/ && $input{$key} eq '') ? 'clear' : $input{$key};

                next CLIENT_KEY unless $val && update_needed($client, $cli, 'client_authentication_document', \%clients_updated);
                my ($doc) = grep { $_->id eq $id } $cli->client_authentication_document;    # Rose
                next CLIENT_KEY unless $doc;
                my $new_value;
                my $issuance = $input{'issuance_' . $id} // '';

                if ($document_field =~ /^(expiration_date|issue_date)$/) {
                    try {
                        $new_value = Date::Utility->new($val)->date_yyyymmdd if $val ne 'clear';

                        if ($document_field =~ /issue_date/ && $issuance eq 'issuance_date') {
                            if (Date::Utility->new($val)->is_before(Date::Utility->new->minus_time_interval('1y'))) {
                                print
                                    qq{<p class="notify notify--warning">ERROR: POA issue date is too old $val, it must have been issued within the last 12 months.</p>};
                                next CLIENT_KEY;
                            }
                        }
                    } catch ($e) {
                        my $err = (split "\n", $e)[0];    #handle Date::Utility's confess() call
                        print qq{<p class="notify notify--warning">ERROR: Could not parse $document_field for doc $id with $val: $err</p>};
                        next CLIENT_KEY;
                    }

                    my $expiration = $input{'expiration_' . $id};

                    unless ($expiration || $issuance) {
                        if ($doc->lifetime_valid) {
                            $expiration = 'lifetime_valid';
                            $issuance   = 'lifetime_valid';
                        } elsif ($doc->expiration_date) {
                            $expiration = 'expiration_date';
                            $issuance   = 'not_applicable';
                        } elsif ($doc->issue_date) {
                            $expiration = 'not_applicable';
                            $issuance   = 'issuance_date';
                        } else {
                            $issuance   = 'not_applicable';
                            $expiration = 'not_applicable';
                        }
                    }

                    my $is_poi         = any { $_ eq $doc->document_type } @poi_doctypes;
                    my $lifetime_valid = $is_poi ? $expiration eq 'lifetime_valid' : $issuance eq 'lifetime_valid';
                    $doc->lifetime_valid($lifetime_valid);
                    $poa_updated ||= any { $_ eq $doc->document_type } $client->documents->poa_types->@*;

                    if ($expiration ne 'expiration_date') {
                        $doc->expiration_date(undef);
                        next CLIENT_KEY if $document_field eq 'expiration_date';
                    }

                    if ($issuance ne 'issuance_date') {
                        $doc->issue_date(undef);
                        next CLIENT_KEY if $document_field eq 'issue_date';
                    }

                } else {
                    my $maxLength =
                          ($document_field eq 'document_id') ? 30
                        : ($document_field eq 'comments')    ? 255
                        :                                      0;
                    if (length($val) > $maxLength) {
                        print qq{<p class="notify notify--warning">ERROR: $document_field is too long. </p>};
                        next CLIENT_KEY;
                    }
                    $new_value = $val;
                }
                next CLIENT_KEY if $new_value && $new_value eq $doc->$document_field();
                try {
                    $poi_updated ||= any { $_ eq $doc->document_type } $client->documents->poi_types->@*;
                    $poa_updated ||= any { $_ eq $doc->document_type } $client->documents->poa_types->@*;
                    $doc->$document_field($new_value);
                } catch ($e) {
                    print qq{<p class="notify notify--warning">ERROR: Could not set $document_field for doc $id with $val: $e</p>};
                }
                next CLIENT_KEY;
            }

            next CLIENT_KEY
                unless update_needed($client, $cli, $key, \%clients_updated);
            if ($key eq 'secret_answer') {
                $cli->secret_answer(BOM::User::Utility::encrypt_secret_answer($input{$key}))
                    if ($input{$key} ne $secret_answer);

            } elsif ($key eq 'client_aml_risk_classification' && BOM::Backoffice::Auth::has_authorisation(['Compliance'])) {
                $cli->aml_risk_classification($input{$key});
                _update_mt5_status($client);
                BOM::Platform::Event::Emitter::emit('aml_high_risk_updated', {loginid => $client->loginid});
            } elsif ($key eq 'mifir_id'
                and $cli->mifir_id eq ''
                and $broker eq 'MF')
            {
                code_exit_BO("<p class=\"error\">ERROR : Could not update client details for client $encoded_loginid: MIFIR_ID line too long</p>")
                    if (length($input{$key}) > 35);
                $cli->mifir_id($input{$key});
            } elsif ($key eq 'tax_residence') {
                code_exit_BO("<p class=\"error\">Tax residence cannot be set empty if value already exists</p>")
                    if ($cli->tax_residence and not $tax_residence);
                $cli->tax_residence($tax_residence);
            } elsif ($key eq 'tax_identification_number') {
                code_exit_BO("<p class=\"error\">Tax residence cannot be set empty if value already exists</p>")
                    if ($cli->tax_identification_number
                    and not $input{tax_identification_number}
                    and not $input{tin_not_available});
                $cli->tax_identification_number($input{tax_identification_number});
            } elsif ($key eq 'tin_not_available') {
                if ($input{tin_not_available}) {
                    my $country     = request()->brand->countries_instance();
                    my $residence   = $cli->tax_residence || $cli->residence;
                    my $tin_formats = $country->get_tin_format($residence);
                    if ($tin_formats) {
                        for my $tin_format (@$tin_formats) {
                            my $valid_tin = first { $_ =~ m/$tin_format/ } MANUAL_TIN_APPROVED_VALUES;
                            if ($valid_tin) {
                                $cli->tax_identification_number($valid_tin);
                                last;
                            }
                        }
                    } else {
                        $cli->tax_identification_number(shift MANUAL_TIN_APPROVED_VALUES);
                    }
                }
            }
        }
        _update_mt5_status($cli);
    }

    # Check if expected address has been updated
    if ($input{'address_1'} || $input{'address_2'} || $input{'expected_address'}) {
        if ($client->documents->is_poa_address_fixed()) {
            $client->documents->poa_address_fix({staff => $clerk});
        } elsif ($client->fully_authenticated) {
            $client->documents->poa_address_mismatch_clear;
        }
    }

    # Save details for all clients
    foreach my $cli (values %clients_updated) {
        my $sync_error;

        if (not $cli->save) {
            code_exit_BO("<p class=\"error\">ERROR : Could not update client details for client $encoded_loginid</p>");

        } elsif (!$client->is_virtual
            && ($auth_method =~ /^(?:ID_NOTARIZED|ID_DOCUMENT$)/))
        {
            # sync to doughflow once we authenticate real client
            # need to do after client save so that all information is upto date

            $sync_error = sync_to_doughflow($cli, $clerk);
        }

        print "<p class=\"success\">Client " . $cli->loginid . " saved</p>";
        print "<p class=\"error\">$sync_error</p>" if $sync_error;

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

    if ($updated_fields{first_name} || $updated_fields{last_name}) {
        BOM::Platform::Event::Emitter::emit('poi_check_rules', {loginid => $client->loginid});
    }

    # Sync onfido with latest updates
    unless ($client->is_virtual) {
        BOM::Platform::Event::Emitter::emit('sync_onfido_details', {loginid => $client->loginid});
    }

    BOM::Platform::Event::Emitter::emit('poi_updated', {loginid => $client->loginid}) if $poi_updated;
    BOM::Platform::Event::Emitter::emit('poa_updated', {loginid => $client->loginid}) if $poa_updated;

    BOM::Platform::Event::Emitter::emit('verify_address', {loginid => $client->loginid})
        if (any { exists $input{$_} } qw(address_1 address_2 city state address_postcode));
}

=head2 Trading Experience & Financial Information

The purpose of this section is to display the client's
financial assessment information and scores in tables.

Also, with a B<Compliance> access, it will render editable dropdowns
instead of labels which provide them the ability to update the
client's financial assessment information.

=cut

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

client_search_and_navigation($client, $self_post);

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

unless (BOM::Backoffice::Auth::has_authority(['AccountsLimited', 'AccountsAdmin'])) {
    Bar("IMPERSONATE CLIENT");
    BOM::Backoffice::Request::template()->process(
        'backoffice/client_impersonate_form.html.tt',
        {
            impersonate_url => $impersonate_url,
            encoded_loginid => $encoded_loginid,
            encoded_broker  => $encoded_broker,
        });

    # Display only the latest 2 comments here for faster review by CS
    my $comments_count  = 2;
    my @client_comments = grep { defined } $client->get_all_comments()->@[0 .. $comments_count - 1];
    if (@client_comments) {
        my $comments_url = request()->url_for('backoffice/f_client_comments.cgi', {loginid => $client->loginid});
        print qq~
            <hr><h3>Latest Comment(s)</h3><p>Displaying up to <b>$comments_count</b> most recent comments:</p>~;
        BOM::Backoffice::Request::template()->process(
            'backoffice/client_comments_table.html.tt',
            {
                comments  => [@client_comments],
                loginid   => $client->loginid,
                csrf      => BOM::Backoffice::Form::get_csrf_token(),
                is_hidden => BOM::Backoffice::Auth::has_authorisation(['CS']),
            });
        print qq~<br><a class="link" href="$comments_url">Add a new comment / View full list</a>~;
    }
}

Bar("$loginid STATUSES", {nav_link => "STATUSES"});

p2p_advertiser_approval_check($client, request()->params);

# for hidden form fields
my $p2p_advertiser = $client->_p2p_advertiser_cached;
my $p2p_approved   = $p2p_advertiser ? $p2p_advertiser->{is_approved} : '';

my @statuses;
###############################################
## UNTRUSTED SECTION
###############################################
my %client_statuses =
    map { $_ => $client->status->$_ } @{$client->status->all};
for my $type (get_untrusted_types()->@*) {
    my $code             = $type->{code};
    my $siblings_summary = siblings_status_summary($client, $code) =~ s/(<span>|<\/span>)//gr;
    if (my $status = $client->status->$code) {
        delete $client_statuses{$type->{code}};
        push(
            @statuses,
            {
                clerk              => $status->{staff_name},
                reason             => get_detailed_status_reason($status->{reason}),
                warning            => 'var(--color-red)',
                code               => $code,
                section            => $type->{comments},
                siblings_summary   => $siblings_summary,
                last_modified_date => $status->{last_modified_date} // ''
            });
    }
}

# Combine the computed list of virtual statuses
%client_statuses = (%client_statuses, BOM::Backoffice::VirtualStatus::get($client));

BOM::Backoffice::Request::template()->process(
    'backoffice/account/untrusted_form.html.tt',
    {
        edit_url                 => request()->url_for('backoffice/untrusted_client_edit.cgi'),
        reasons                  => get_untrusted_client_reason(),
        untrusted_statuses       => [@statuses],
        broker                   => $broker,
        clientid                 => $loginid,
        actions                  => [sort { $a->{comments} cmp $b->{comments} } @{get_untrusted_types()}],
        actions_hash             => get_untrusted_types_hashref(),
        p2p_approved             => $p2p_approved,
        client_statuses_readonly => \%client_statuses,
    }) || die BOM::Backoffice::Request::template()->error(), "\n";

if (BOM::Backoffice::Auth::has_authority(['AccountsLimited', 'AccountsAdmin'])) {
    code_exit_BO();
}

# Show Self-Exclusion link
if (!$is_readonly) {
    Bar("$loginid SELF-EXCLUSION SETTINGS", {nav_link => "SELF-EXCLUSION SETTINGS"});
    print "<p><a id='self-exclusion' class=\"btn btn--primary\" href=\""
        . request()->url_for(
        'backoffice/f_setting_selfexclusion.cgi',
        {
            broker  => $broker,
            loginid => $loginid
        }) . "\">Configure self-exclusion settings</a> <strong>for $encoded_loginid</strong></p>";

# show restricted-access fields of regulated landing company clients (accessible for compliance staff only)
    if (BOM::Backoffice::Auth::has_authorisation(['Compliance']) and $client->landing_company->is_eu) {
        print '<a id="self-exclusion_restricted" class="btn btn--primary" href="'
            . request()->url_for(
            'backoffice/f_setting_selfexclusion_restricted.cgi',
            {
                broker  => $broker,
                loginid => $loginid
            }) . '">Configure restricted self-exlcusion settings</a>';
    }
}
Bar("$loginid PAYMENT AGENT DETAILS", {nav_link => "PAYMENT AGENT DETAILS"});

# Show Payment-Agent details if this client is also a Payment Agent.
my $payment_agent = $client->get_payment_agent;
if ($payment_agent) {
    print '<div class="row"><table class="border small">';

    foreach my $field (
        qw/payment_agent_name risk_level urls email phone_numbers information supported_payment_methods
        commission_deposit commission_withdrawal
        min_withdrawal max_withdrawal affiliate_id code_of_conduct_approval
        code_of_conduct_approval_date status is_listed currency_code/
        )
    {

        my $value     = $payment_agent->$field // '';
        my $main_attr = $payment_agent->details_main_field->{$field};
        $value = join ', ', (map { $_->{$main_attr} } @$value) if ref $value;

        my $label = BOM::Backoffice::Utility::payment_agent_column_labels()->{$field};
        print "<tr><td>$label</td><td>" . encode_entities($value) . "</td></tr>";
    }
    my $pa           = $client->get_payment_agent;
    my $pa_countries = $pa->get_countries;
    print "<tr><td>Target countries</td><td>" . encode_entities(join(',', @$pa_countries)) . "</td></tr>";

    print "<tr><td>Tier</td><td>" . encode_entities($pa->tier_details->{name}) . "</td></tr>";
    print "<tr><td>Tier comments</td><td>" . encode_entities($pa->services_allowed_comments) . "</td></tr>";

    print '</table></div>';
}

if ($client->landing_company->allows_payment_agents) {
    print '<div><a class="'
        . $button_type
        . '" href="'
        . request()->url_for(
        'backoffice/f_setting_paymentagent.cgi',
        {
            broker   => $broker,
            loginid  => $loginid,
            whattodo => $payment_agent ? "show" : "create"
        }) . "\">Payment agent details</a> <strong>for $encoded_loginid</strong></div>";
} else {
    print '<div>Payment Agents are not available for this account.</div>';
}

my @sibling_pas = $payment_agent ? $payment_agent->sibling_payment_agents : ();
if (scalar @sibling_pas > 1) {
    print qq[<br><form action="$self_post?loginID=$encoded_loginid" id="copy_pa_form" method="post">
    <input type="hidden" name="whattodo" value="copy_pa_details"/>
    <input type="hidden" name="broker" value="$encoded_broker"/>
    <input type="hidden" name="loginID" value="$encoded_loginid">
    <input type="submit" class="btn btn--secondary" value="Copy payment agent details to sibling accounts"/>
    </form>];
}

my $statuses = join '/', map { uc $_ } @{$client->status->all};
my $name     = $client->first_name;
$name .= ' ' if $name;
$name .= $client->last_name;
my $client_info = sprintf "%s %s%s", $client->loginid, ($name || '?'), ($statuses ? " [$statuses]" : '');
Bar("CLIENT " . $client_info, {nav_link => "Client details"});

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

    print "<li><strong><a href='$link_href'"
        . ($client->status->disabled ? ' class="link link--disabled"' : ' class="link"') . ">"
        . encode_entities($lid->loginid) . " ("
        . $currency
        . ") </a></strong>&nbsp;<span"
        . ($client->status->disabled ? ' class="text-muted"' : ' class="error"') . ">"
        . $formatted_balance
        . "</span></li>";
}

# show MT5 a/c

# inverse jurisdiction ratings; for example high => [id, ru] is converted to {id => high, ru => high}
my $mt5_jurisdiction_mt5         = BOM::Config::Compliance->get_jurisdiction_risk_rating('mt5');
my $aml_jurisdiction_risk        = BOM::Config::Compliance->get_jurisdiction_risk_rating('aml');
my $mt5_jurisdiction             = {%$mt5_jurisdiction_mt5, %$aml_jurisdiction_risk};
my $jurisdiction_ratings         = $aml_jurisdiction_risk->{$client->landing_company->short};
my $client_aml_jurisdiction_risk = 'low';
for my $rating (keys %$jurisdiction_ratings) {
    if (grep { $_ eq $client->residence } $jurisdiction_ratings->{$rating}->@*) {
        $client_aml_jurisdiction_risk = $rating;
    }
}

delete $mt5_jurisdiction->{revision};
for my $landing_company (keys %$mt5_jurisdiction) {
    for my $risk_level (BOM::Config::Compliance::RISK_LEVELS) {
        $mt5_jurisdiction->{$landing_company}->{country_risk}->{$_} = $risk_level for $mt5_jurisdiction->{$landing_company}->{$risk_level}->@*;
    }
}

foreach my $mt_ac ($mt_logins->@*) {
    print "<li>" . encode_entities($mt_ac);

    my ($group, $status) = get_mt5_group_and_status($mt_ac);

    if ($group) {
        my $landing_company = BOM::User::Utility::parse_mt5_group($group)->{landing_company_short};

        my $jurisdiction_risk;
        $jurisdiction_risk = $mt5_jurisdiction->{$landing_company}->{country_risk}->{$client->residence} if $mt5_jurisdiction->{$landing_company};
        $jurisdiction_risk //= 'low';

        print " (" . encode_entities($group) . "), jur. risk= $jurisdiction_risk" . " ( $status )";
    } else {
        print ' (<span title="Try refreshing in a minute or so">no group info yet</span>)';
    }

    if (defined $aff_mt_accounts->{$mt_ac} and $aff_mt_accounts->{$mt_ac}{mt5_account_type} eq 'main') {
        print sprintf(
            " (Aff. %s main acc. on %s)",
            $aff_mt_accounts->{$mt_ac}{mt5_myaffiliate_id},
            $aff_mt_accounts->{$mt_ac}{mt5_server_key} // $aff_mt_accounts->{$mt_ac}{mt5_server_id});
    }
    if ($loginid_details->{$mt_ac}->{status} =~ /migrated/) {
        print "  MIGRATED  ";
    }
    print "</li>";
}

# show MT5 affiliate technical accounts
foreach my $mt_ac (keys %$aff_mt_accounts) {
    next if $aff_mt_accounts->{$mt_ac}{mt5_account_type} eq 'main';

    print sprintf(
        "<li style='color: #555'>%s (Aff. %s %s acc. on %s)</li>",
        encode_entities($mt_ac),
        $aff_mt_accounts->{$mt_ac}{mt5_myaffiliate_id},
        $aff_mt_accounts->{$mt_ac}{mt5_account_type},
        $aff_mt_accounts->{$mt_ac}{mt5_server_key} // $aff_mt_accounts->{$mt_ac}{mt5_server_id});
}

# Show DevExperts accounts.
foreach my $dx_ac ($dx_logins->@*) {
    print "<li>";
    print encode_entities($dx_ac);

    if (my $details = $loginid_details->{$dx_ac}) {
        my $extra = join '\\', $details->{currency}, grep { $_ } $details->{account_type}, $details->{attributes}->{market_type},
            "dxlogin=" . $details->{attributes}->{login};
        my $account_status = $details->{status};
        print " (" . $account_status . ")"         if $account_status;
        print " (" . encode_entities($extra) . ")" if $extra;
    }

    print "</li>";
}

# Show Derivez accounts.
foreach my $derivez_login ($derivez_logins->@*) {
    print "<li>";
    print encode_entities($derivez_login);
    my ($group, $status) = get_mt5_group_and_status($derivez_login);

    if ($group) {
        my $landing_company = BOM::User::Utility::parse_mt5_group($group)->{landing_company_short};

        my $jurisdiction_risk;
        $jurisdiction_risk = $mt5_jurisdiction->{$landing_company}->{country_risk}->{$client->residence} if $mt5_jurisdiction->{$landing_company};
        $jurisdiction_risk //= 'low';

        print " (" . encode_entities($group) . "), jur. risk= $jurisdiction_risk" . " ( $status )";
    } else {
        print ' (<span title="Try refreshing in a minute or so">no group info yet</span>)';
    }

    print "</li>";
}

# Show cTrader accounts.
foreach my $ct_ac ($ctrader_logins->@*) {
    print "<li>";
    print encode_entities($ct_ac);

    if (my $details = $loginid_details->{$ct_ac}) {
        my $extra = join ' \\ ', $details->{currency}, grep { $_ } $details->{account_type}, $details->{attributes}->{market_type},
            "ctlogin=" . $details->{attributes}->{login}, "groups=" . $details->{attributes}->{group};
        my $account_status = $details->{status};
        print " (" . $account_status . ")"         if $account_status;
        print " (" . encode_entities($extra) . ")" if $extra;
    }

    print "</li>";
}

print "</ul>";

try {
    my $mt5_log_size = BOM::Config::Redis::redis_mt5_user()->llen("MT5_USER_GROUP_PENDING");

    print "<p class='error'>Note: MT5 groups might take time to appear, since there are "
        . encode_entities($mt5_log_size)
        . " item(s) being processed</p>"
        if $mt5_log_size > 500;

} catch ($e) {
    print encode_entities($e);
};

my $log_args = {
    broker   => $broker,
    category => 'client_details',
    loginid  => $loginid
};

my $new_log_href = request()->url_for('backoffice/show_audit_trail.cgi', $log_args);
print qq{<a href="$new_log_href" class="btn btn--primary">View history of changes to $encoded_loginid</a>};

if (%$aff_mt_accounts) {
    my $update_affiliate_id_href = request()->url_for('backoffice/update_affiliate_id.cgi', $log_args);
    print qq{<a href="$update_affiliate_id_href" class="btn btn--primary">Edit Affiliate ID for $encoded_loginid</a>};
} else {
    print qq{<span class="btn btn--disabled">No affiliates info to edit for $encoded_loginid</span>};
}

if ($payment_agent) {
    $log_args->{category} = 'payment_agent';
    $new_log_href = request()->url_for('backoffice/show_audit_trail.cgi', $log_args);
    print qq{<a href="$new_log_href" class="btn btn--primary">View payment agent history for $encoded_loginid</a>};
}
print qq[<hr><form action="$self_post?loginID=$encoded_loginid" id="clientInfoForm" method="post">
    <input type="submit" class="$button_type" value="Save client details">
    <input type="hidden" name="broker" value="$encoded_broker">
    <input type="hidden" name="p2p_approved" value="$p2p_approved">];

# Get latest client object to make sure it contains updated client info (after editing client details form)
$client = BOM::User::Client->new({loginid => $loginid});
print_client_details($client, $client_aml_jurisdiction_risk, $is_readonly);

my $INPUT_SELECTOR = 'input:not([type="hidden"]):not([type="submit"]):not([type="reset"]):not([type="button"])';

print qq[
    <hr>
    <input type=submit class="$button_type" value="Save client details"></form>
    <style>
        .data-changed {
            background: var(--color-pink);
            color: var(--grey-500);
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

sub force_fa {
    my ($self_href, $client, $clerk) = @_;

    my $is_forced = $client->status->financial_assessment_required;

    code_exit_BO(
        qq[<p><b>Client is already forced to complete their financial assessment.</b></p>
        <p><a class="link" href="$self_href">&laquo; Return to client details</a></p>]
    ) if $is_forced;

    code_exit_BO(
        qq[<p><b>Client has already completed their financial assessment.</b></p>
        <p><a class="link" href="$self_href">&laquo; Return to client details</a></p>]
    ) if !is_fa_needs_completion($client);

    $client->status->setnx('financial_assessment_required', $clerk,   'Financial Assessment completion is forced from Backoffice.');
    $client->status->setnx('withdrawal_locked',             'system', 'FA needs to be completed');
}

sub is_fa_needs_completion {
    my $client = shift;

    # Note: we need to refactor some codes regarding https://trello.com/c/UbfQSLTO to handle below code duplication.
    my $lc                   = $client->landing_company->short;
    my $financial_assessment = BOM::User::FinancialAssessment::decode_fa($client->financial_assessment());

    my $is_FI = BOM::User::FinancialAssessment::is_section_complete($financial_assessment, 'financial_information');

    return !$is_FI if $lc ne 'maltainvest';

    my $is_TE = BOM::User::FinancialAssessment::is_section_complete($financial_assessment, 'trading_experience', $lc);

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

my $built_fa = BOM::User::FinancialAssessment::build_financial_assessment(BOM::User::FinancialAssessment::decode_fa($client->financial_assessment()));
my $fa_score = $built_fa->{scores};

my $user_edd_status = $user->get_edd_status();
my @sections        = qw(trading_experience financial_information);

push(@sections, 'trading_experience_regulated') if $client->landing_company->short eq 'maltainvest';

for my $section_name (@sections) {
    next unless ($built_fa->{$section_name});

    my $is_financial_information = $section_name eq 'financial_information';
    my $show_edd_form            = $is_financial_information && !$client->is_virtual && $user_edd_status;

    my $title         = join ' ', map { ucfirst } split '_', $section_name;
    my $content_class = $show_edd_form ? 'grid2col border' : 'grid2col';

    $content_class = '' if $section_name eq 'trading_experience_regulated';
    Bar($title, {content_class => $content_class});

    print "<div class='card__content'>";
    print_fa_table($user, $client, $section_name, $self_href, $is_compliance, $built_fa->{$section_name}->%*);
    print "<p class='success'>$title updated</p>"
        if $fa_updated{$section_name};

    print_fa_force_btn($section_name, $self_href) if ($is_financial_information && $is_compliance);
    print "<p class='error'>Financial Assessment questionnaire triggered.</p>"
        if ($is_financial_information && $fa_updated{force_financial_assessment});

    print "<hr><div class='row'><span class='right'>$title score:</span>&nbsp;<strong>" . $fa_score->{$section_name} . '</strong></div>';
    print '<div><span class="right">CFD Score:</span>&nbsp;<strong>' . $fa_score->{cfd_score} . '</strong></div>'
        if ($section_name eq 'trading_experience');
    print '<div><span class="right">CFD Score:</span>&nbsp;<strong>' . $fa_score->{cfd_score} . '</strong></div>'
        if ($section_name eq 'trading_experience_regulated');
    print '</div>';

    print_edd_status_form($user_edd_status, $client, $section_name, $self_href, $is_compliance) if ($show_edd_form);
}

sub print_fa_table {
    my ($user, $client, $section_name, $self_href, $is_editable, %section) = @_;

    my @hdr    = ('Question', 'Answer', 'Score');
    my $config = BOM::Config::financial_assessment_fields();

    $is_editable = 0 if $section_name eq 'trading_experience' && $client->landing_company->short eq 'maltainvest';
    print "<form method='post' action='$self_href#$section_name'><input type='hidden' name='whattodo' value='$section_name'>"
        if $is_editable;
    print '<table class="sortable alternate hover meduim"><thead><tr>';
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
    print '</tbody></table><br>';

    print '<input type="submit" class="btn btn--primary" value="Update"></form>' if $is_editable;

    return undef;
}

sub print_fa_force_btn {
    my ($section_name, $self_href) = @_;

    print "<br><form method='post' action='$self_href#$section_name'>";

    print '<input type="hidden" name="whattodo" value="force_financial_assessment">';

    print '<input type="submit" class="btn btn--primary" value="Click to force financial assessment">';

    print '</form>';
}

sub print_edd_status_form {
    my ($selected, $client, $section_name, $self_href, $is_editable) = @_;

    my $currency = $client->currency;

    my $status           = $selected->{status}           // '';
    my $start_date       = $selected->{start_date}       // '';
    my $last_review_date = $selected->{last_review_date} // '';
    my $average_earnings = $selected->{average_earnings} ? decode_json_utf8($selected->{average_earnings}) : {};
    my $comment          = $selected->{comment} // '';
    my $reason           = $selected->{reason}  // '';

    $start_date       = Date::Utility->new($start_date)->date       if $start_date;
    $last_review_date = Date::Utility->new($last_review_date)->date if $last_review_date;

    my $reasons_options = [{
            value => 'card_deposit_monitoring',
            name  => 'Card deposit monitoring'
        },
        {
            value => 'social_responsibility',
            name  => 'Social Responsibility'
        },
        {
            value => 'high_deposit',
            name  => 'High Deposit'
        },
        {
            value => 'fraud',
            name  => 'Fraud'
        },
        {
            value => 'hish_risk_regulated',
            name  => 'High risk client (regulated)'
        },
        {
            value => 'crypto_monitoring',
            name  => 'Crypto monitoring'
        },
        {
            value => 'others',
            name  => 'Others'
        },
    ];

    my $status_options = [{
            value => 'n/a',
            name  => 'Not applicable'
        },
        {
            value => 'contacted',
            name  => 'Contacted'
        },
        {
            value => 'passed',
            name  => 'Passed'
        },
        {
            value => 'failed',
            name  => 'Failed'
        },
        {
            value => 'pending',
            name  => 'Pending'
        },
        {
            value => 'in_progress',
            name  => 'In progress'
        },
    ];

    my $dropdown = "<select name='edd_status' required>";
    $dropdown .= "<option value=''></option>" unless $status;
    $dropdown .= "<option value='$_->{value}'@{[$_->{value} eq $status ? ' selected=\"selected\"' : '']}>$_->{name}</option>" for @$status_options;
    $dropdown .= "</select>";

    my $reason_dropdown = "<select name='edd_reason' required>";
    $reason_dropdown .= "<option value=''></option>" unless $reason;
    $reason_dropdown .= "<option value='$_->{value}'@{[$_->{value} eq $reason ? ' selected=\"selected\"' : '']}>$_->{name}</option>"
        for @$reasons_options;
    $reason_dropdown .= "</select>";

    my @currencies        = LandingCompany::Registry::all_currencies();
    my $currency_dropdown = dropdown('edd_average_earnings_currency', $average_earnings->{currency}, @currencies);

    my $is_disabled = $is_editable ? '' : 'disabled';

    print "<div class='card__content'><form method='post' action='$self_href#$section_name'><fieldset $is_disabled style='border: none;'>";

    print qq{
            <div class="row">
            <div class="col">
            <h3>EDD status</h3>
            </div>
            <div class="col" style="margin-left:2.5em;">
            <strong class='error'>Reasons: </strong>
                $reason_dropdown 
            </div>
            </div>
            <input type='hidden' name='whattodo' value='save_edd_status' />
            <div class="row">
                <label>Status:</label>
                $dropdown  
                <label>Start date:</label><input size="10" type="text" class="datepick" name="edd_start_date" value="$start_date" />
                <label>Last review date:</label><input size="10" type="text" class="datepick" name="edd_last_review_date" value="$last_review_date" />
            </div>
            <div class="row">
                <label>Actual average earnings yearly:</label>
                $currency_dropdown
                <input type="number" name="edd_average_earnings_amount" value="$average_earnings->{amount}" />
            </div>
            <label>Notes: </label><br>
            <div class="row">
                <textarea rows="8" cols="80" name="edd_comment" maxlength="1000" minlength="1" placeholder="Enter new comment here">$comment</textarea>
            </div>
        };

    print '<input type="submit" class="btn btn--primary" value="Update" />' if $is_editable;

    print "</fieldset></form></div>";
}

sub dropdown {
    my ($name, $selected, @values) = @_;

    my $ddl = "<select name='$name'>";
    $ddl .= "<option value=''></option>" unless $selected;
    $ddl .= "<option value='$_'@{[$_ eq $selected ? ' selected=\"selected\"' : '']}>$_</option>" for @values;
    $ddl .= '</select>';

    return $ddl;
}

if (not $client->is_virtual and !$is_readonly) {
    Bar("Sync Client Authentication Status to Doughflow", {nav_link => "Sync to Doughflow"});
    print qq{
        <p>Click to sync client authentication status to Doughflow: </p>
        <form action="$self_post" method="get">
            <input type="hidden" name="whattodo" value="sync_to_DF">
            <input type="hidden" name="broker" value="$encoded_broker">
            <input type="hidden" name="loginID" value="$encoded_loginid">
            <input type="submit" class="btn btn--primary" value="Sync now !!">
        </form>
    };
    Bar("Sync Client Information to MT5", {nav_link => "Sync to MT5"});
    print qq{
        <p>Click to sync client information to MT5: </p>
        <form action="$self_post" method="get">
            <input type="hidden" name="whattodo" value="sync_to_MT5">
            <input type="hidden" name="loginID" value="$encoded_loginid">
            <input type="submit" class="btn btn--primary" value="Sync to MT5">
        </form>
    };
}

Bar("Two-Factor Authentication", {nav_link => "2FA"});
print 'Enabled : <b>' . ($user->is_totp_enabled ? 'Yes' : 'No') . '</b>';
print qq{
    <br/><br/>
    <form action="$self_post" method="get">
        <input type="hidden" name="whattodo" value="disable_2fa">
        <input type="hidden" name="broker" value="$encoded_broker">
        <input type="hidden" name="loginID" value="$encoded_loginid">
        <input type="submit" class="btn btn--primary" value="Disable 2FA"/>
        <span class="error">This will disable the 2FA feature. Only user can enable then.</span>
    </form>
} if $user->is_totp_enabled;

if (!$is_readonly) {
    Bar("$loginid Copiers/Traders", {nav_link => "Copiers/Traders"});
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
        }) || die BOM::Backoffice::Request::template()->error(), "\n";

    Bar(
        "$loginid Tokens",
        {
            collapsed => 1,
            nav_link  => "Tokens"
        });
    my $token_db = BOM::Database::Model::AccessToken->new();
    my (@all_tokens, @deleted_tokens);

    my $copiers_map = {};
    foreach my $c ($copiers->@*) {
        if ($copiers_map->{$c->[2]}) {
            push @{$copiers_map->{$c->[2]}}, $c->[0];
        } else {
            $copiers_map->{$c->[2]} = [$c->[0]];
        }
    }

    foreach my $l ($user_clients->@*) {
        my $tokens = $token_db->get_all_tokens_by_loginid($l->loginid);
        foreach my $token (@{$tokens}) {
            $token->{loginid} = $l->loginid;
            # we will be passing the copiers list to the template which will
            # be used to display the copiers list in the token table using the tag <token.copiers>
            $token->{copiers} = $copiers_map->{$token->{token}};
            $token->{token}   = obfuscate_token($token->{token});
            push @all_tokens, $token;
        }
        my $deleted_tokens = $token_db->token_deletion_history($l->loginid);
        foreach my $token (@{$deleted_tokens}) {
            $token->{loginid} = $l->loginid;
            push @deleted_tokens, $token;
        }
    }

    @all_tokens     = rev_sort_by { $_->{creation_time} } @all_tokens;
    @deleted_tokens = rev_sort_by { $_->{deleted} } @deleted_tokens;

    BOM::Backoffice::Request::template()->process(
        'backoffice/access_tokens.html.tt',
        {
            tokens  => \@all_tokens,
            deleted => \@deleted_tokens
        }) || die BOM::Backoffice::Request::template()->error(), "\n";
}
if (!$is_readonly) {
    Bar('Send Client Statement', {nav_link => "Send statement"});
    BOM::Backoffice::Request::template()->process(
        'backoffice/send_client_statement.tt',
        {
            today     => Date::Utility->new()->date_yyyymmdd(),
            broker    => $input{broker},
            client_id => $input{loginID},
            action    => request()->url_for('backoffice/f_send_statement.cgi')
        },
    );
}

Bar("Email Consent");
print 'Email consent for marketing: ' . ($user->{email_consent} ? '<b>Yes</b>' : '<b>No</b>');

if (not $client->is_virtual) {
    # This will feed the doctype dropdowns
    # The idea is to show nested <optgroup> (categories) filled with the corresponding <option> (doctypes)
    my $doctypes = [];

    for my $category (values %doc_types_categories) {
        my $doctype = {
            priority             => $category->{priority},
            description          => $category->{description},
            document_id_required => $category->{document_id_required},
            side_required        => $category->{side_required},
            types                => [
                sort     { $a->{priority} <=> $b->{priority} }
                    grep { not $_->{deprecated} }
                    map  { +{$category->{types}->{$_}->%*, type => $_} }
                    keys $category->{types}->%*
            ],
        };

        push $doctypes->@*, $doctype;
    }

    #upload new ID doc
    if (!$is_readonly) {
        Bar("Upload new ID document");
        BOM::Backoffice::Request::template()->process(
            'backoffice/client_edit_upload_doc.html.tt',
            {
                self_post                  => $self_post,
                broker                     => $encoded_broker,
                loginid                    => $encoded_loginid,
                countries                  => request()->brand->countries_instance->countries,
                poi_doctypes               => join('|', @poi_doctypes),
                poa_doctypes               => join('|', @poa_doctypes),
                expirable_doctypes         => join('|', @expirable_doctypes),
                dateless_doctypes          => join('|', @dateless_doctypes),
                doctypes                   => [sort { $a->{priority} <=> $b->{priority} } $doctypes->@*],
                docsides                   => encode_json_utf8(\%document_type_sides),
                sides                      => encode_json_utf8(\%document_sides),
                numberless_doctypes        => join('|', @numberless_doctypes),
                onfido_doctypes            => encode_json_utf8(\@onfido_doctypes),
                document_size_limit        => DOCUMENT_SIZE_LIMIT_IN_MB,
                onfido_document_size_limit => ONFIDO_DOCUMENT_SIZE_LIMIT_IN_MB,
            });
    }
    Bar('P2P Advertiser');

    print '<a class="btn btn--primary" href="'
        . request()->url_for(
        'backoffice/p2p_advertiser_manage.cgi',
        {
            broker  => $broker,
            loginID => $loginid
        })
        . '">'
        . $loginid
        . ' P2P advertiser details</a>';

    if (!$is_readonly) {
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
}

Bar($user->{email} . " Login history", {nav_link => "Login History"});
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
        print qq{<p class="notify notify--warning">Error: Date of birth cannot be empty.</p>};
        code_exit_BO(qq[<p><a href="$self_href">&laquo;Return to client details</a></p>]);
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

sub _update_mt5_status {
    my $client = shift;

    BOM::Platform::Event::Emitter::emit(
        'sync_mt5_accounts_status',
        {
            binary_user_id => $client->binary_user_id,
            client_loginid => $client->loginid
        });
}

sub set_client_status {
    my ($client, $set, $clear, $reason, $clerk) = @_;
    $client->status->multi_set_clear({
        set        => $set,
        clear      => $clear,
        staff_name => $clerk,
        reason     => $reason,
    });
}

1;
