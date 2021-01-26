package BOM::Event::Actions::Client;

use strict;
use warnings;

=head1 NAME

BOM::Event::Actions::Client

=head1 DESCRIPTION

Provides handlers for client-related events.

=cut

no indirect;

use Brands;
use DataDog::DogStatsd::Helper;
use Date::Utility;
use Digest::MD5;
use Encode qw(decode_utf8 encode_utf8);
use ExchangeRates::CurrencyConverter qw(convert_currency);
use File::Temp;
use Format::Util::Numbers qw(financialrounding formatnumber);
use Future::AsyncAwait;
use Future::Utils qw(fmap0);
use IO::Async::Loop;
use JSON::MaybeUTF8 qw(decode_json_utf8 encode_json_utf8);
use List::Util qw(any all first uniq);
use Locale::Codes::Country qw(country_code2code);
use Log::Any qw($log);
use POSIX qw(strftime);
use Syntax::Keyword::Try;
use Template::AutoFilter;
use Time::HiRes;

use BOM::Config;
use BOM::Config::Onfido;
use BOM::Config::Redis;
use BOM::Config::Runtime;
use BOM::Database::ClientDB;
use BOM::Database::UserDB;
use BOM::Event::Services;
use BOM::Event::Services::Track;
use BOM::Event::Utility qw(exception_logged);
use BOM::Platform::Client::IDAuthentication;
use BOM::Platform::Context qw(localize request);
use BOM::Platform::Email qw(send_email);
use BOM::Platform::Event::Emitter;
use BOM::Platform::Redis;
use BOM::Platform::S3Client;
use BOM::User;
use BOM::User::Client;
use BOM::User::Client::PaymentTransaction;
use BOM::User::Onfido;
use BOM::User::Record::Payment;

# this one shoud come after BOM::Platform::Email
use Email::Stuffer;

# For smartystreets datadog stats_timing
$Future::TIMES = 1;

# Number of seconds to allow for just the verification step.
use constant VERIFICATION_TIMEOUT => 60;

# Number of seconds to allow for the full document upload.
# We expect our documents to be small (<10MB) and all API calls
# to complete within a few seconds.
use constant UPLOAD_TIMEOUT => 60;

# Redis key namespace to store onfido applicant id
use constant ONFIDO_REQUEST_PER_USER_PREFIX  => 'ONFIDO::DAILY::REQUEST::PER::USER::';
use constant ONFIDO_REQUEST_PER_USER_LIMIT   => $ENV{ONFIDO_REQUEST_PER_USER_LIMIT} // 3;
use constant ONFIDO_REQUEST_PER_USER_TIMEOUT => $ENV{ONFIDO_REQUEST_PER_USER_TIMEOUT} // 24 * 60 * 60;
use constant ONFIDO_PENDING_REQUEST_PREFIX   => 'ONFIDO::PENDING::REQUEST::';
use constant ONFIDO_PENDING_REQUEST_TIMEOUT  => 20 * 60;

# Redis key namespace to store onfido results and link
use constant ONFIDO_REQUESTS_LIMIT => $ENV{ONFIDO_REQUESTS_LIMIT} // 1000;
use constant ONFIDO_LIMIT_TIMEOUT  => $ENV{ONFIDO_LIMIT_TIMEOUT}  // 24 * 60 * 60;
use constant ONFIDO_AUTHENTICATION_CHECK_MASTER_KEY => 'ONFIDO_AUTHENTICATION_REQUEST_CHECK';
use constant ONFIDO_REQUEST_COUNT_KEY               => 'ONFIDO_REQUEST_COUNT';
use constant ONFIDO_CHECK_EXCEEDED_KEY              => 'ONFIDO_CHECK_EXCEEDED';
use constant ONFIDO_APPLICANT_CONTEXT_HOLDER_KEY    => 'ONFIDO::APPLICANT_CONTEXT::ID::';
use constant ONFIDO_REPORT_KEY_PREFIX               => 'ONFIDO::REPORT::ID::';
use constant ONFIDO_DOCUMENT_ID_PREFIX              => 'ONFIDO::DOCUMENT::ID::';
use constant ONFIDO_IS_A_RESUBMISSION_KEY_PREFIX    => 'ONFIDO::IS_A_RESUBMISSION::ID::';

use constant ONFIDO_SUPPORTED_COUNTRIES_KEY                    => 'ONFIDO_SUPPORTED_COUNTRIES';
use constant ONFIDO_SUPPORTED_COUNTRIES_TIMEOUT                => $ENV{ONFIDO_SUPPORTED_COUNTRIES_TIMEOUT} // 7 * 86400;                     # 1 week
use constant ONFIDO_UNSUPPORTED_COUNTRY_EMAIL_PER_USER_PREFIX  => 'ONFIDO::UNSUPPORTED::COUNTRY::EMAIL::PER::USER::';
use constant ONFIDO_UNSUPPORTED_COUNTRY_EMAIL_PER_USER_TIMEOUT => $ENV{ONFIDO_UNSUPPORTED_COUNTRY_EMAIL_PER_USER_TIMEOUT} // 24 * 60 * 60;
use constant ONFIDO_AGE_EMAIL_PER_USER_TIMEOUT                 => $ENV{ONFIDO_AGE_EMAIL_PER_USER_TIMEOUT} // 24 * 60 * 60;
use constant ONFIDO_AGE_BELOW_EIGHTEEN_EMAIL_PER_USER_PREFIX   => 'ONFIDO::AGE::BELOW::EIGHTEEN::EMAIL::PER::USER::';
use constant ONFIDO_ADDRESS_REQUIRED_FIELDS                    => qw(address_postcode residence);
use constant ONFIDO_UPLOAD_TIMEOUT_SECONDS                     => 30;
use constant SR_CHECK_TIMEOUT                                  => 5;

# Redis TTLs
use constant TTL_ONFIDO_APPLICANT_CONTEXT_HOLDER => 240 * 60 * 60;    # 10 days in seconds

# Redis keys to stop sending new emails in a specific time
use constant ONFIDO_POI_EMAIL_NOTIFICATION_SENT_PREFIX => 'ONFIDO::POI::EMAIL::NOTIFICATION::SENT::';

# Redis key for resubmission counter
use constant ONFIDO_RESUBMISSION_COUNTER_KEY_PREFIX => 'ONFIDO::RESUBMISSION_COUNTER::ID::';
use constant ONFIDO_RESUBMISSION_COUNTER_TTL        => 2592000;                                # 30 days (in seconds)

# List of document types that we use as proof of address
use constant POA_DOCUMENTS_TYPE => qw(
    proofaddress payslip bankstatement cardstatement utility_bill
);

# List of document types that we use as proof of identity
use constant POI_DOCUMENTS_TYPE => qw(
    proofid driverslicense passport selfie_with_id
);

# Templates prefix path
use constant TEMPLATE_PREFIX_PATH => "/home/git/regentmarkets/bom-events/share/templates/email/";

# Conversion from our database to the Onfido available fields
my %ONFIDO_DOCUMENT_TYPE_MAPPING = (
    passport                                     => 'passport',
    certified_passport                           => 'passport',
    selfie_with_id                               => 'live_photo',
    driving_licence                              => 'driving_licence',
    driverslicense                               => 'driving_licence',
    cardstatement                                => 'bank_statement',
    bankstatement                                => 'bank_statement',
    national_identity_card                       => 'national_identity_card',
    proofid                                      => 'national_identity_card',
    vf_face_id                                   => 'live_photo',
    vf_poa                                       => 'unknown',
    vf_id                                        => 'unknown',
    address                                      => 'unknown',
    proofaddress                                 => 'unknown',
    certified_address                            => 'unknown',
    docverification                              => 'unknown',
    certified_bank_details                       => 'unknown',
    professional_uk_high_net_worth               => 'unknown',
    amlglobalcheck                               => 'unknown',
    employment_contract                          => 'unknown',
    power_of_attorney                            => 'unknown',
    notarised                                    => 'unknown',
    frontofcard                                  => 'unknown',
    professional_uk_self_certified_sophisticated => 'unknown',
    experianproveid                              => 'unknown',
    backofcard                                   => 'unknown',
    tax_receipt                                  => 'unknown',
    payslip                                      => 'unknown',
    alldocs                                      => 'unknown',
    professional_eu_qualified_investor           => 'unknown',
    misc                                         => 'unknown',
    code_of_conduct                              => 'unknown',
    utility_bill                                 => 'unknown',
    other                                        => 'unknown',
);

# Mapping to convert our database entries to the 'side' parameter in the
# Onfido API
my %ONFIDO_DOCUMENT_SIDE_MAPPING = (
    front => 'front',
    back  => 'back',
    photo => 'photo',
);

# When submitting checks, Onfido expects an identity document,
# so we prioritise the IDs that have a better chance of a good
# match. This does not cover all the types, but anything without
# a photo is unlikely to work well anyway.
my %ONFIDO_DOCUMENT_TYPE_PRIORITY = (
    uk_biometric_residence_permit => 5,
    passport                      => 4,
    passport_card                 => 4,
    national_identity_card        => 3,
    driving_licence               => 2,
    voter_id                      => 1,
    tax_id                        => 1,
    unknown                       => 0,
);

my %allowed_synchronizable_documents_type = map { $_ => 1 } (POA_DOCUMENTS_TYPE, POI_DOCUMENTS_TYPE);

# Mapping to convert our database entries for 'net_income'
# in json field of financial_assessment to values which will be
# easier to make the sr checks
my %NET_INCOME = (
    'Over $500,000'       => '500000',
    '$100,001 - $500,000' => '100000',
    '$50,001 - $100,000'  => '50000',
    '$25,000 - $50,000'   => '25000',
    'Less than $25,000'   => '24999',
);

my $loop = IO::Async::Loop->new;
$loop->add(my $services = BOM::Event::Services->new);

{
    # Provides an instance for communicating with the Onfido web API.
    # Since we're adding this to our event loop, it's a singleton - we
    # don't want to leak memory by creating new ones for every event.
    sub _onfido {
        return $services->onfido();
    }

    sub _smartystreets {
        return $services->smartystreets();
    }

    sub _http {
        return $services->http();
    }

    sub _redis_mt5user_read {
        return $services->redis_mt5user();
    }

    sub _redis_events_read {
        return $services->redis_events_read();
    }

    sub _redis_events_write {
        return $services->redis_events_write();
    }

    sub _redis_replicated_write {
        return $services->redis_replicated_write();
    }

    sub _redis_replicated_read {
        return $services->redis_replicated_read();
    }
}

=head2 document_upload

    Called when we have a new document provided by the client .

    These are typically received through one of two possible avenues :

=over 4

=item * backoffice manual upload

=item * client sends the document through the websockets binary upload

=back

Our handling in this event goes as far as making sure the content
is available to Onfido: we don't do the verification step here, but
we do B<trigger a verification event> if we think we have enough
information to process this client.

=cut

async sub document_upload {
    my ($args) = @_;

    BOM::Config::Runtime->instance->app_config->check_for_update();
    return if (BOM::Config::Runtime->instance->app_config->system->suspend->onfido);
    try {
        my $loginid = $args->{loginid}
            or die 'No client login ID supplied?';
        my $file_id = $args->{file_id}
            or die 'No file ID supplied?';

        my $client = BOM::User::Client->new({loginid => $loginid})
            or die 'Could not instantiate client for login ID ' . $loginid;

        my $uploaded_manually_by_staff = $args->{uploaded_manually_by_staff} // 0;

        $log->debugf('Applying Onfido verification process for client %s', $loginid);
        my $file_data = $args->{content};

        # We need information from the database to confirm file name and date
        my $document_entry = _get_document_details(
            loginid => $loginid,
            file_id => $file_id
        );

        unless ($document_entry) {
            $log->errorf('Could not get document %s from database for client %s', $file_id, $loginid);
            return;
        }

        $client->propagate_clear_status('allow_poi_resubmission')
            if any { $_ eq $document_entry->{document_type} } +{BOM::User::Client::DOCUMENT_TYPE_CATEGORIES()}->{POI}{doc_types_appreciated}->@*;
        $client->propagate_clear_status('allow_poa_resubmission')
            if any { $_ eq $document_entry->{document_type} } +{BOM::User::Client::DOCUMENT_TYPE_CATEGORIES()}->{POA}{doc_types}->@*;

        await BOM::Event::Services::Track::document_upload({
                loginid    => $loginid,
                properties => {
                    uploaded_manually_by_staff => $uploaded_manually_by_staff,
                    %$document_entry
                }});
        # don't sync documents to onfido if its not in allowed types
        unless ($allowed_synchronizable_documents_type{$document_entry->{document_type}}) {
            $log->debugf('Can not sync documents to Onfido as it is not in allowed types for client %s', $loginid);
            return;
        }
        die 'Expired document ' . $document_entry->{expiration_date}
            if $document_entry->{expiration_date} and Date::Utility->new($document_entry->{expiration_date})->is_before(Date::Utility->today);

        await _send_email_notification_for_poa(
            document_entry => $document_entry,
            client         => $client
        ) unless $uploaded_manually_by_staff;

        my $loop   = IO::Async::Loop->new;
        my $onfido = _onfido();

        # We have an overall timeout for this entire operation - it won't
        # limit any SQL queries, but all network operations should be covered.
        await Future->wait_any(
            $loop->timeout_future(after => UPLOAD_TIMEOUT)->on_fail(sub { $log->errorf('Time out waiting for Onfido upload.') }),

            _upload_documents(
                onfido                     => $onfido,
                client                     => $client,
                document_entry             => $document_entry,
                file_data                  => $file_data,
                uploaded_manually_by_staff => $uploaded_manually_by_staff,
            )

        );
    } catch {
        my $e = $@;
        $log->errorf('Failed to process Onfido application for %s : %s', $args->{loginid}, $e);
        exception_logged();
        DataDog::DogStatsd::Helper::stats_inc("event.document_upload.failure",);
    }

    return;
}

=head2 ready_for_authentication

This event is triggered once we think we have enough information to do
a verification step for a client.

We expect documents to be fully uploaded and available, plus any data that
needs to be in external systems should also be in place.

For Onfido, this means the applicant and documents are created, and
everything should be ready to do the verification step.

=cut

async sub ready_for_authentication {
    my ($args) = @_;

    try {
        my $loginid = $args->{loginid}
            or die 'No client login ID supplied?';
        my $applicant_id = $args->{applicant_id}
            or die 'No Onfido applicant ID supplied?';

        my ($broker) = $loginid =~ /^([A-Z]+)\d+$/
            or die 'could not extract broker code from login ID';

        my $loop   = IO::Async::Loop->new;
        my $onfido = _onfido();

        $log->debugf('Processing ready_for_authentication event for %s (applicant ID %s)', $loginid, $applicant_id);

        my $client = BOM::User::Client->new({loginid => $loginid})
            or die 'Could not instantiate client for login ID ' . $loginid;

        # We want to increment the resubmission counter when the resubmission flag is active.

        my $resubmission_flag = $client->status->allow_poi_resubmission;
        $client->propagate_clear_status('allow_poi_resubmission');

        my $residence = uc(country_code2code($client->residence, 'alpha-2', 'alpha-3'));

        my ($request_count, $user_request_count);
        my $redis_events_write = _redis_events_write();
        # INCR Onfido check request count in Redis
        await $redis_events_write->connect;

        ($request_count, $user_request_count) = await Future->needs_all(
            $redis_events_write->hget(ONFIDO_AUTHENTICATION_CHECK_MASTER_KEY, ONFIDO_REQUEST_COUNT_KEY),
            $redis_events_write->get(ONFIDO_REQUEST_PER_USER_PREFIX . $client->binary_user_id),
        );

        $request_count      //= 0;
        $user_request_count //= 0;

        if (!$args->{is_pending} && $user_request_count >= ONFIDO_REQUEST_PER_USER_LIMIT) {
            $log->debugf('No check performed as client %s exceeded daily limit of %d requests.', $loginid, ONFIDO_REQUEST_PER_USER_LIMIT);
            my $time_to_live = await $redis_events_write->ttl(ONFIDO_REQUEST_PER_USER_PREFIX . $client->binary_user_id);

            await $redis_events_write->expire(ONFIDO_REQUEST_PER_USER_PREFIX . $client->binary_user_id, ONFIDO_REQUEST_PER_USER_TIMEOUT)
                if ($time_to_live < 0);

            die "Onfido authentication requests limit ${\ONFIDO_REQUEST_PER_USER_LIMIT} is hit by $loginid (to be expired in $time_to_live seconds).";

        }

        if ($request_count >= ONFIDO_REQUESTS_LIMIT) {
            # NOTE: We do not send email again if we already send before
            my $redis_data = encode_json_utf8({
                creation_epoch => Date::Utility->new()->epoch,
                has_email_sent => 1
            });

            my $send_email_flag = await $redis_events_write->hsetnx(ONFIDO_AUTHENTICATION_CHECK_MASTER_KEY, ONFIDO_CHECK_EXCEEDED_KEY, $redis_data);

            if ($send_email_flag) {
                _send_email_onfido_check_exceeded_cs($request_count);
            }

            die 'We exceeded our Onfido authentication check request per day';
        }

        my $redis_replicated_write = _redis_replicated_write();
        await $redis_replicated_write->connect;
        await $redis_replicated_write->del(ONFIDO_IS_A_RESUBMISSION_KEY_PREFIX . $client->binary_user_id);

        if ($resubmission_flag) {
            # Ensure the resubmission kicks in only if the user has at least one check
            # otherwise this would be the first check and call it resubmission may be pointless

            if (BOM::User::Onfido::get_latest_onfido_check($client->binary_user_id)) {
                # The following redis keys block email sending on client verification failure. We might clear them for resubmission
                my @delete_on_resubmission = (
                    ONFIDO_AGE_BELOW_EIGHTEEN_EMAIL_PER_USER_PREFIX . $client->binary_user_id,
                    ONFIDO_POI_EMAIL_NOTIFICATION_SENT_PREFIX . $client->binary_user_id,
                );

                await $redis_events_write->connect;
                foreach my $email_blocker (@delete_on_resubmission) {
                    await $redis_events_write->del($email_blocker);
                }
                # Deal with resubmission counter and context
                await $redis_replicated_write->incr(ONFIDO_RESUBMISSION_COUNTER_KEY_PREFIX . $client->binary_user_id);
                await $redis_replicated_write->set(ONFIDO_IS_A_RESUBMISSION_KEY_PREFIX . $client->binary_user_id, 1);
                await $redis_replicated_write->expire(ONFIDO_RESUBMISSION_COUNTER_KEY_PREFIX . $client->binary_user_id,
                    ONFIDO_RESUBMISSION_COUNTER_TTL);
            }
        }

        await _save_request_context($applicant_id);

        await Future->wait_any(
            $loop->timeout_future(after => VERIFICATION_TIMEOUT)->on_fail(sub { $log->errorf('Time out waiting for Onfido verfication.') }),

            _check_applicant($args, $onfido, $applicant_id, $broker, $loginid, $residence, $redis_events_write, $client));
    } catch {
        my $e = $@;
        $log->errorf('Failed to process Onfido verification for %s: %s', $args->{loginid}, $e);
        exception_logged();
    }

    return;
}

async sub client_verification {
    my ($args) = @_;
    my $brand = request->brand;

    $log->debugf('Client verification with %s', $args);

    try {
        my $url = $args->{check_url};
        $log->debugf('Had client verification result %s with check URL %s', $args->{status}, $args->{check_url});

        my ($applicant_id, $check_id) = $url =~ m{/applicants/([^/]+)/checks/([^/]+)} or die 'no check ID found';

        my $check = await _onfido()->check_get(
            check_id     => $check_id,
            applicant_id => $applicant_id,
        );

        await _restore_request($applicant_id, $check->tags);

        try {
            my $result = $check->result;
            # Map to something that can be standardised across other systems
            my $check_status = {
                clear        => 'pass',
                rejected     => 'fail',
                suspected    => 'fail',
                consider     => 'maybe',
                caution      => 'maybe',
                unidentified => 'maybe',
            }->{$result // 'unknown'} // 'unknown';

            # All our checks are tagged by login ID, we don't currently retain
            # any local mapping aside from this.
            my @tags = $check->tags->@*;

            my ($loginid) = grep { /^[A-Z]+[0-9]+$/ } @tags
                or die "No login ID found in tags: @tags";

            my $client = BOM::User::Client->new({loginid => $loginid})
                or die 'Could not instantiate client for login ID ' . $loginid;
            $log->debugf('Onfido check result for %s (applicant %s): %s (%s)', $loginid, $applicant_id, $result, $check_status);

            # check if the applicant already exist for this check. If not, store the applicant record in db
            # this is to cater the case where CS/Compliance perform manual check in Onfido dashboard
            my $new_applicant_flag = await check_or_store_onfido_applicant($loginid, $applicant_id);

            $new_applicant_flag ? BOM::User::Onfido::store_onfido_check($applicant_id, $check) : BOM::User::Onfido::update_onfido_check($check);

            my @all_report = await $check->reports->as_list;
            for my $each_report (@all_report) {
                BOM::User::Onfido::store_onfido_report($check, $each_report);
            }
            await _store_applicant_documents($applicant_id, $client, \@all_report);

            my $redis_events_write = _redis_events_write();

            my $pending_key = ONFIDO_PENDING_REQUEST_PREFIX . $client->binary_user_id;

            my $args = await $redis_events_write->get($pending_key);

            if (($check_status ne 'pass') and $args) {
                $log->debugf('Onfido check failed. Resending the last pending request: %s', $args);
                BOM::Platform::Event::Emitter::emit(ready_for_authentication => decode_json_utf8($args));
            }

            await $redis_events_write->del($pending_key);
            await _clear_cached_context($applicant_id);

            $log->debugf('Onfido pending key cleared');

            # Consume resubmission context
            my $redis_replicated_write = _redis_replicated_write();
            await $redis_replicated_write->connect;
            await $redis_replicated_write->del(ONFIDO_IS_A_RESUBMISSION_KEY_PREFIX . $client->binary_user_id);

            # Skip facial similarity:
            # For current selfie we ask them to submit with ID document
            # that leads to sub optimal facial images and hence, it leads
            # to lot of negatives for Onfido checks
            # TODO: remove this check when we have fully integrated Onfido
            try {
                my @reports = await $check->reports->filter(name => 'document')->as_list;

                # Extract all clear documents to check consistency between DOBs
                if (my @valid_doc = grep { (defined $_->{properties}->{date_of_birth} and $_->result eq 'clear') } @reports) {
                    my %dob = map { ($_->{properties}{date_of_birth} // '') => 1 } @valid_doc;
                    my ($first_dob) = keys %dob;
                    # All documents should have the same date of birth
                    # Override date_of_birth if there is mismatch between Onfido report and client submited data
                    if ($client->date_of_birth ne $first_dob) {
                        try {
                            my $user = $client->user;

                            foreach my $lid ($user->bom_real_loginids) {
                                my $current_client = BOM::User::Client->new({loginid => $lid});
                                $current_client->date_of_birth($first_dob);
                                $current_client->save;
                            }
                        } catch {
                            my $e = $@;
                            $log->debugf('Error updating client date of birth: %s', $e);
                            exception_logged();
                        }

                        # Update applicant data
                        BOM::Platform::Event::Emitter::emit('sync_onfido_details', {loginid => $client->loginid});
                        $log->debugf("Updating client's date of birth due to mismatch between Onfido's response and submitted information");
                    }
                    # Age verified if report is clear and age is above minimum allowed age, otherwise send an email to notify cs
                    # Get the minimum age from the client's residence
                    my $min_age = $brand->countries_instance->minimum_age_for_country($client->residence);

                    if (Date::Utility->new($first_dob)->is_before(Date::Utility->new->_minus_years($min_age))) {
                        _set_age_verification($client);
                    } else {
                        my $siblings = $client->real_account_siblings_information(include_disabled => 0);

                        # check if there is balance
                        my $have_balance = (any { $siblings->{$_}->{balance} > 0 } keys %{$siblings}) ? 1 : 0;

                        my $email_details = {
                            client         => $client,
                            short_reason   => 'under_18',
                            failure_reason => "because Onfido reported the date of birth as $first_dob which is below age 18.",
                            redis_key      => ONFIDO_AGE_BELOW_EIGHTEEN_EMAIL_PER_USER_PREFIX . $client->binary_user_id,
                            is_disabled    => 0,
                            account_info   => $siblings,
                        };

                        unless ($have_balance) {
                            # if all of the account doesn't have any balance, disable them
                            for my $each_siblings (keys %{$siblings}) {
                                my $current_client = BOM::User::Client->new({loginid => $each_siblings});
                                $current_client->status->setnx('disabled', 'system', 'Onfido - client is underage');
                            }

                            # need to send email to client
                            _send_email_underage_disable_account($client);

                            $email_details->{is_disabled} = 1;
                        }

                    }
                }

                # Update expiration_date and document_id of each document in DB
                # Using corresponding values in Onfido response
                @reports = grep { $_->result eq 'clear' } @reports;
                foreach my $report (@reports) {
                    next if ($report->{properties}->{document_type} eq 'live_photo');

                    # It seems that expiration date and document number of all documents in $report->{documents} list are similar
                    my ($expiration_date, $doc_numbers) = @{$report->{properties}}{qw(date_of_expiry document_numbers)};

                    foreach my $onfido_doc ($report->{documents}->@*) {
                        my $onfido_doc_id = $onfido_doc->{id};

                        await $redis_events_write->connect;
                        my $db_doc_id = await $redis_events_write->get(ONFIDO_DOCUMENT_ID_PREFIX . $onfido_doc_id);

                        if ($db_doc_id) {
                            await $redis_events_write->del(ONFIDO_DOCUMENT_ID_PREFIX . $onfido_doc_id);
                            # There is a possibility that corresponding DB document of onfido document has been deleted (e.g. by BO user)
                            my ($db_doc) = $client->find_client_authentication_document(query => [id => $db_doc_id]);
                            if ($db_doc) {
                                $db_doc->expiration_date($expiration_date);
                                $db_doc->document_id($doc_numbers->[0]->{value});
                                if ($db_doc->save) {
                                    $log->debugf('Expiration_date and document_id of document %s for client %s have been updated',
                                        $db_doc->id, $loginid);
                                }
                            }
                        }
                    }
                }
                return;
            } catch {
                my $e = $@;
                $log->errorf('An error occurred while retrieving reports for client %s check %s: %s', $loginid, $check->id, $e);
                die $e;
            }
        } catch {
            my $e = $@;
            $log->errorf('Failed to do verification callback - %s', $e);
            die $e;
        }
    } catch {
        my $e = $@;
        $log->errorf('Exception while handling client verification result: %s', $e);
        exception_logged();
    }

    return;
}

=head2 _store_applicant_documents

Gets the client's documents from Onfido and store in DB

It takes the following params:

=over 4

=item * C<applicant_id> the Onfido Applicant's ID (string)

=item * C<client> a L<BOM::User::Client> instance

=item * C<check_reports> an arrayref of the current Onfido check reports (usually one for document and other for selfie checkup)

=back

Returns undef.

=cut

async sub _store_applicant_documents {
    my ($applicant_id, $client, $check_reports) = @_;
    my $onfido               = _onfido();
    my $existing_onfido_docs = BOM::User::Onfido::get_onfido_document($client->binary_user_id);
    my @documents;

    # Build hash index for onfido document id to report.
    my %report_for_doc_id;
    for my $report (@{$check_reports}) {
        next unless $report->name eq 'document';
        push @documents, map { $_->{id} } @{$report->documents};
        $report_for_doc_id{$_->{id}} = $report for @{$report->documents};
    }

    foreach my $document_id (@documents) {
        # Fetch each document individually by applicant/id
        my $doc = await $onfido->get_document_details(
            applicant_id => $applicant_id,
            document_id  => $document_id
        );

        my $type = $doc->type;
        my $side = $doc->side;
        $side = $side && $ONFIDO_DOCUMENT_SIDE_MAPPING{$side} // 'front';
        $type = 'live_photo' if $side eq 'photo';

        # Skip if document exist in our DB
        next if $existing_onfido_docs && $existing_onfido_docs->{$doc->id};

        $log->debugf('Insert document data for user %s and document id %s', $client->binary_user_id, $doc->id);

        BOM::User::Onfido::store_onfido_document($doc, $applicant_id, $client->place_of_birth, $type, $side);

        my ($expiration_date, $document_numbers) = @{$report_for_doc_id{$doc->id}{properties}}{qw(date_of_expiry document_numbers)};
        my $doc_number = $document_numbers ? $document_numbers->[0]->{value} : undef;

        BOM::Platform::Event::Emitter::emit(
            onfido_doc_ready_for_upload => {
                type           => 'document',
                document_id    => $doc->id,
                client_loginid => $client->loginid,
                applicant_id   => $applicant_id,
                file_type      => $doc->file_type,
                document_info  => {
                    type            => $type,
                    side            => $side,
                    expiration_date => $expiration_date,
                    number          => $doc_number,
                },
            });
    }

    # Unfortunately, the Onfido API doesn't narrow down the live photos list to the given report/check
    # We should capitulate and process the last one. Since selfies are the last step in the Frontend flow,
    # this may not be that bad, feels inconvenient though.

    my @live_photos = await $onfido->photo_list(applicant_id => $applicant_id)->as_list;

    return undef unless scalar @live_photos;

    my $photo                  = shift @live_photos;
    my $existing_onfido_photos = BOM::User::Onfido::get_onfido_live_photo($client->binary_user_id);

    # Skip if document exist in our DB
    return undef if $existing_onfido_photos && $existing_onfido_photos->{$photo->id};

    $log->debugf('Insert live photo data for user %s and document id %s', $client->binary_user_id, $photo->id);

    BOM::User::Onfido::store_onfido_live_photo($photo, $applicant_id);

    BOM::Platform::Event::Emitter::emit(
        onfido_doc_ready_for_upload => {
            type           => 'photo',
            document_id    => $photo->id,
            client_loginid => $client->loginid,
            applicant_id   => $applicant_id,
            file_type      => $photo->file_type,
        });

    return undef;
}

=head2 onfido_doc_ready_for_upload

Gets the client's documents from Onfido and upload to S3

=cut

async sub onfido_doc_ready_for_upload {
    my $data = shift;
    my ($type, $doc_id, $client_loginid, $applicant_id, $file_type, $document_info) =
        @{$data}{qw/type document_id client_loginid applicant_id file_type document_info/};

    my $client    = BOM::User::Client->new({loginid => $client_loginid});
    my $s3_client = BOM::Platform::S3Client->new(BOM::Config::s3()->{document_auth});
    my $onfido    = _onfido();
    my $doc_type  = $document_info->{type};
    my $page_type = $document_info->{side} // '';

    my $image_blob;
    if ($type eq 'document') {
        $image_blob = await $onfido->download_document(
            applicant_id => $applicant_id,
            document_id  => $doc_id
        );
    } elsif ($type eq 'photo') {
        $doc_type   = 'photo';
        $image_blob = await $onfido->download_photo(
            applicant_id  => $applicant_id,
            live_photo_id => $doc_id
        );
    } else {
        die "Unsupported document type";
    }

    my $expiration_date = $document_info->{expiration_date};
    die "Invalid expiration date" if ($expiration_date
        && $expiration_date ne (eval { Date::Utility->new($expiration_date)->date_yyyymmdd } // ''));

    $file_type = lc $file_type;
    ## Convert to a better extension in case it comes back as image/*
    ## Media::Type::Simple is buggy, else we might have considered it here
    if ($file_type =~ m{/jpe?g}i) {
        $file_type = 'jpg';
    } elsif ($file_type =~ m{/png}i) {
        $file_type = 'png';
    } elsif ($file_type !~ /^[a-z]{3,4}$/) {
        ## If we are sent anything else not a three-or-four-letter code, throw a warning
        $log->warnf('Unexpected file type "%s"', $file_type);
    }

    my $fh           = File::Temp->new(DIR => '/var/lib/binary');
    my $tmp_filename = $fh->filename;
    print $fh $image_blob;
    seek $fh, 0, 0;
    my $file_checksum = Digest::MD5->new->addfile($fh)->hexdigest;
    close $fh;
    my $upload_info;
    my $s3_uploaded;
    my $file_id;
    my $new_file_name;

    my $redis_events_write = _redis_events_write();
    await $redis_events_write->connect;

    # If the following key exists, the document is already being uploaded,
    # so we can safely drop this event.
    my $lock_key     = join q{-} => ('ONFIDO_UPLOAD_BAG', $client_loginid, $file_checksum, $doc_type);
    my $acquire_lock = BOM::Platform::Redis::acquire_lock($lock_key, ONFIDO_UPLOAD_TIMEOUT_SECONDS);
    # A test is expecting this log warning though.
    $log->warn("Document already exists") unless $acquire_lock;
    return unless $acquire_lock;

    try {
        $upload_info = $client->db->dbic->run(
            ping => sub {
                $_->selectrow_hashref(
                    'SELECT * FROM betonmarkets.start_document_upload(?, ?, ?, ?, ?, ?, ?, ?)',
                    undef, $client_loginid, $doc_type, $file_type,
                    $expiration_date || undef,
                    $document_info->{number} || '',
                    $file_checksum, '', $page_type,
                );
            });

        if ($upload_info) {
            ($file_id, $new_file_name) = @{$upload_info}{qw/file_id file_name/};

            # This redis key allow further date/numbers update
            await $redis_events_write->setex(ONFIDO_DOCUMENT_ID_PREFIX . $doc_id, ONFIDO_PENDING_REQUEST_TIMEOUT, $file_id);

            $log->debugf("Starting to upload file_id: $file_id to S3 ");
            $s3_uploaded = await $s3_client->upload($new_file_name, $tmp_filename, $file_checksum);

        } else {
            $log->warn("Document already exists");
        }

        if ($s3_uploaded) {
            $log->debugf("Successfully uploaded file_id: $file_id to S3 ");
            my $finish_upload_result = $client->db->dbic->run(
                ping => sub {
                    $_->selectrow_array('SELECT * FROM betonmarkets.finish_document_upload(?)', undef, $file_id);
                });

            die "Db returned unexpected file_id on finish. Expected $file_id but got $finish_upload_result. Please check the record"
                unless $finish_upload_result == $file_id;

            my $document_info = _get_document_details(
                loginid => $client->loginid,
                file_id => $file_id
            );

            if ($document_info) {
                await BOM::Event::Services::Track::document_upload({
                    loginid    => $client->loginid,
                    properties => $document_info
                });
            } else {
                $log->errorf('Could not get document %s from database for client %s', $file_id, $client->loginid);
            }
        }
    } catch ($error) {
        $log->errorf("Error in creating record in db and uploading Onfido document to S3 for %s : %s", $client->loginid, $error);
        exception_logged();
    }

    BOM::Platform::Redis::release_lock($lock_key);

    return;
}

=head2 sync_onfido_details

Sync the client details from our system with Onfido

=cut

async sub sync_onfido_details {
    my $data = shift;

    BOM::Config::Runtime->instance->app_config->check_for_update();
    return if (BOM::Config::Runtime->instance->app_config->system->suspend->onfido);

    try {

        my $loginid = $data->{loginid} or die 'No loginid supplied';
        my $client  = BOM::User::Client->new({loginid => $loginid});

        my $applicant_data = BOM::User::Onfido::get_user_onfido_applicant($client->binary_user_id);
        my $applicant_id   = $applicant_data->{id};

        # Only for users that are registered in onfido
        return unless $applicant_id;

        # Instantiate client and onfido object
        my $client_details_onfido = _client_onfido_details($client);

        $client_details_onfido->{applicant_id} = $applicant_id;

        my $response = await _onfido()->applicant_update(%$client_details_onfido);

        return $response;

    } catch {
        my $e = $@;
        $log->errorf('Failed to update details in Onfido for %s : %s', $data->{loginid}, $e);
        exception_logged();
    }

    return;
}

=head2 verify_address

This event is triggered once client or someone from backoffice
have updated client address.

It first clear existing address_verified status and then
request again for new address.

=cut

async sub verify_address {
    my ($args) = @_;

    my $loginid = $args->{loginid}
        or die 'No client login ID supplied?';

    my $client = BOM::User::Client->new({loginid => $loginid})
        or die 'Could not instantiate client for login ID ' . $loginid;

    DataDog::DogStatsd::Helper::stats_inc('event.address_verification.request');

    # verify address only if client has made any deposits
    # or client is fully authenticated
    my $has_deposits           = $client->has_deposits({exclude => ['free_gift']});
    my $is_fully_authenticated = $client->fully_authenticated();
    my @dd_tags                = ();
    do {
        try {
            DataDog::DogStatsd::Helper::stats_inc('event.address_verification.triggered', {tags => \@dd_tags});
            return await _address_verification(client => $client);
        } catch {
            my $e = $@;
            DataDog::DogStatsd::Helper::stats_inc('event.address_verification.exception', {tags => \@dd_tags});
            $log->errorf('Failed to verify applicants address for %s : %s', $loginid, $e);
            exception_logged();
        }
    } if (($has_deposits and push(@dd_tags, 'verify_address:deposits'))
        or ($is_fully_authenticated and push(@dd_tags, 'verify_address:authenticated')));

    return;
}

async sub _address_verification {
    my (%args) = @_;

    my $client = $args{client};

    $log->debugf('Verifying address');

    my $freeform = join(' ',
        grep { length } $client->address_line_1,
        $client->address_line_2, $client->address_city, $client->address_state, $client->address_postcode);

    my %details = (
        freeform => $freeform,
        country  => uc(country_code2code($client->residence, 'alpha-2', 'alpha-3')),
        # Need to pass this if you want to do verification
        geocode => 'true',
    );
    $log->debugf('Address details %s', \%details);

    my $redis_events_read = _redis_events_read();
    await $redis_events_read->connect;

    my $check_already_performed = await $redis_events_read->hget('ADDRESS_VERIFICATION_RESULT' . $client->binary_user_id,
        encode_utf8(join(' ', ($freeform, ($client->residence // '')))));

    if ($check_already_performed) {
        DataDog::DogStatsd::Helper::stats_inc('event.address_verification.already_exists');
        $log->debugf('Returning as address verification already performed for same details.');
        return;
    }

    DataDog::DogStatsd::Helper::stats_inc('smartystreet.verification.trigger');
    # Next step is an address check. Let's make sure that whatever they
    # are sending is valid at least to locality level.
    my $future_verify_ss = _smartystreets()->verify(%details);

    $future_verify_ss->on_fail(
        sub {
            DataDog::DogStatsd::Helper::stats_inc('smartystreet.lookup.failure');
            # clear current status on failure, if any
            $client->status->clear_address_verified();
            $log->errorf('Address lookup failed for %s - %s', $client->loginid, $_[0]);
            return;
        }
    )->on_done(
        sub {
            DataDog::DogStatsd::Helper::stats_inc('smartystreet.lookup.success');
        });

    my $addr = await $future_verify_ss;

    my $status = $addr->status;
    $log->debugf('Smartystreets verification status: %s', $status);
    $log->debugf('Address info back from SmartyStreets is %s', {%$addr});

    if (not $addr->accuracy_at_least('locality')) {
        DataDog::DogStatsd::Helper::stats_inc('smartystreet.verification.failure', {tags => ['verify_address:' . $status]});
        $log->debugf('Inaccurate address - only verified to %s precision', $addr->address_precision);
    } else {
        DataDog::DogStatsd::Helper::stats_inc('smartystreet.verification.success', {tags => ['verify_address:' . $status]});
        $log->debugf('Address verified with accuracy of locality level by smartystreet.');

        _set_address_verified($client);
    }

    my $redis_events_write = _redis_events_write();
    await $redis_events_write->connect;
    await $redis_events_write->hset('ADDRESS_VERIFICATION_RESULT' . $client->binary_user_id,
        encode_utf8(join(' ', ($freeform, ($client->residence // '')))), $status);
    DataDog::DogStatsd::Helper::stats_inc('event.address_verification.recorded.redis');

    return;
}

async sub _get_onfido_applicant {
    my (%args) = @_;

    my $client                     = $args{client};
    my $onfido                     = $args{onfido};
    my $uploaded_manually_by_staff = $args{uploaded_manually_by_staff};
    my $country                    = $client->place_of_birth // $client->residence;
    try {
        my $is_supported_country = BOM::Config::Onfido::is_country_supported($country);

        unless ($is_supported_country) {
            DataDog::DogStatsd::Helper::stats_inc('onfido.unsupported_country', {tags => [$country]});
            await _send_email_onfido_unsupported_country_cs($client) unless $uploaded_manually_by_staff;
            $log->debugf('Document not uploaded to Onfido as client is from list of countries not supported by Onfido');
            return undef;
        }
        # accessing applicant_data from onfido_applicant table
        my $applicant_data = BOM::User::Onfido::get_user_onfido_applicant($client->binary_user_id);
        my $applicant_id   = $applicant_data->{id};

        if ($applicant_id) {
            $log->debugf('Applicant id already exists, returning that instead of creating new one');
            return await $onfido->applicant_get(applicant_id => $applicant_id);
        }

        my $start     = Time::HiRes::time();
        my $applicant = await $onfido->applicant_create(%{_client_onfido_details($client)});
        my $elapsed   = Time::HiRes::time() - $start;
        # saving data into onfido_applicant table
        BOM::User::Onfido::store_onfido_applicant($applicant, $client->binary_user_id);

        $applicant
            ? DataDog::DogStatsd::Helper::stats_timing("event.document_upload.onfido.applicant_create.done.elapsed",   $elapsed)
            : DataDog::DogStatsd::Helper::stats_timing("event.document_upload.onfido.applicant_create.failed.elapsed", $elapsed);

        return $applicant;
    } catch {
        my $e = $@;
        $log->warn($e);
        exception_logged();
    }

    return undef;
}

sub _get_document_details {
    my (%args) = @_;

    my $loginid = $args{loginid};
    my $file_id = $args{file_id};

    return do {
        my $dbic = BOM::Database::ClientDB->new({
                client_loginid => $loginid,
                operation      => 'replica',
            }
            )->db->dbic
            or die "failed to get database connection for login ID " . $loginid;

        my $doc;
        try {
            $doc = $dbic->run(
                fixup => sub {
                    $_->selectrow_hashref(<<'SQL', undef, $loginid, $file_id);
SELECT id,
   file_name,
   expiration_date,
   comments,
   document_id,
   upload_date,
   document_type
FROM betonmarkets.client_authentication_document
WHERE client_loginid = ?
AND status != 'uploading'
AND id = ?
SQL
                });
        } catch {
            exception_logged();
            die "An error occurred while getting document details ($file_id) from database for login ID $loginid.";
        }
        $doc;
    };
}

=head2 _set_address_verified 

This method sets the specified client as B<address_verified> by SmartyStreets.

It takes the following arguments:

=over 4

=item * C<client> an instance of L<BOM::User::Client>

=back

Returns undef.

=cut

sub _set_address_verified {
    my $client      = shift;
    my $status_code = 'address_verified';
    my $reason      = 'SmartyStreets - address verified';
    my $staff       = 'system';

    $log->debugf('Updating status on %s to %s (%s)', $client->loginid, $status_code, $reason);

    BOM::Platform::Event::Emitter::emit('p2p_advertiser_updated', {client_loginid => $client->loginid});

    $client->status->setnx($status_code, $staff, $reason);

    return undef;
}

=head2 _set_age_verification 

This method sets the specified client as B<age_verification> by Onfido.

It also propagates the status across siblings.

It takes the following arguments:

=over 4

=item * C<client> an instance of L<BOM::User::Client>

=back

Returns undef.

=cut

sub _set_age_verification {
    my $client      = shift;
    my $status_code = 'age_verification';
    my $reason      = 'Onfido - age verified';
    my $staff       = 'system';

    my $setter = sub {
        my $c = shift;
        $c->status->upsert($status_code, $staff, $reason) if $client->status->is_experian_validated;
        $c->status->setnx($status_code, $staff, $reason) unless $client->status->is_experian_validated;
    };

    $log->debugf('Updating status on %s to %s (%s)', $client->loginid, $status_code, $reason);

    # to push FE notification when advertiser becomes approved via db trigger
    BOM::Platform::Event::Emitter::emit('p2p_advertiser_updated', {client_loginid => $client->loginid});

    _email_client_age_verified($client);

    $setter->($client);
    # gb residents cant use demo account while not age verified.
    # should remove unwelcome status once respective MX or MF marked
    # as age verified.
    if ($client->residence eq 'gb') {
        my $vr_acc = BOM::User::Client->new({loginid => $client->user->bom_virtual_loginid});
        if ($vr_acc->status->unwelcome and $vr_acc->status->unwelcome->{reason} eq 'Pending proof of age') {
            $vr_acc->status->clear_unwelcome;
            $setter->($vr_acc);
        }
    }

    # We should sync age verification between allowed landing companies.
    my @allowed_lc_to_sync = @{$client->landing_company->allowed_landing_companies_for_age_verification_sync};
    # Apply age verification for one client per each landing company since we have a DB trigger that sync age verification between the same landing companies.
    my @clients_to_update =
        map { [$client->user->clients_for_landing_company($_)]->[0] // () } @allowed_lc_to_sync;
    $setter->($_) foreach (@clients_to_update);

    $client->update_status_after_auth_fa($reason);

    return undef;
}

=head2 account_closure

Called when a client closes their accounts, sends an email to CS and tracks the event.

=cut

sub account_closure {
    my $data = shift;

    _send_email_account_closure_client($data->{loginid});

    return BOM::Event::Services::Track::account_closure($data);
}

=head2 _email_client_age_verified

Emails client when they have been successfully age verified.
Raunak 19/06/2019 Please note that we decided to do it as frontend notification but since that is not yet drafted and designed so we will implement email notification

=over 4

=item * L<BOM::User::Client>  Client Object of user who has been age verified.

=back

Returns undef

=cut

sub _email_client_age_verified {
    my ($client) = @_;
    my $brand = request->brand;

    return unless $client->landing_company()->{actions}->{account_verified}->{email_client};

    return if $client->status->age_verification;

    my $from_email   = $brand->emails('no-reply');
    my $website_name = $brand->website_name;

    my $data_tt = {
        client       => $client,
        l            => \&localize,
        website_name => $website_name,
        contact_url  => $brand->contact_url,
    };
    my $email_subject = localize("Your identity is verified");
    my $tt            = Template->new(ABSOLUTE => 1);

    try {
        $tt->process(TEMPLATE_PREFIX_PATH . 'age_verified.html.tt', $data_tt, \my $html);
        die "Template error: @{[$tt->error]}" if $tt->error;
        send_email({
                from          => $from_email,
                to            => $client->email,
                subject       => $email_subject,
                message       => [$html],
                template_args => {
                    name  => $client->first_name,
                    title => localize("Your identity is verified"),
                },
                use_email_template    => 1,
                email_content_is_html => 1,
                skip_text2html        => 1,
            });
    } catch {
        $log->warn($@);
        exception_logged();
    }
    return undef;
}

=head2 _email_client_account_verification

Emails client when they have been successfully verified by Back Office
Raunak 19/06/2019 Please note that we decided to do it as frontend notification but since that is not yet drafted and designed so we will implement email notification

=over 4

=item * C<<{loginid=>'clients loginid'}>>  hashref with a loginid key of the user who has had their account verified.

=back

Returns undef

=cut

sub email_client_account_verification {
    my ($args) = @_;
    my $brand = request->brand;

    my $client = BOM::User::Client->new($args);

    my $from_email   = $brand->emails('no-reply');
    my $website_name = $brand->website_name;
    #TODO: set brand logo address and url

    my $data_tt = {
        client       => $client,
        l            => \&localize,
        website_name => $website_name,
        contact_url  => $brand->contact_url,
    };

    my $email_subject = localize("Your address and identity have been verified successfully");
    my $tt            = Template->new(ABSOLUTE => 1);

    try {
        $tt->process(TEMPLATE_PREFIX_PATH . 'account_verification.html.tt', $data_tt, \my $html);
        die "Template error: @{[$tt->error]}" if $tt->error;
        send_email({
                from          => $from_email,
                to            => $client->email,
                subject       => $email_subject,
                message       => [$html],
                template_args => {
                    name          => $client->first_name,
                    title         => localize("Your address and identity are verified"),
                    title_padding => 90,
                },
                use_email_template    => 1,
                email_content_is_html => 1,
                skip_text2html        => 1,
            });
    } catch {
        $log->warn($@);
        exception_logged();
    }
    return undef;
}

sub _send_email_account_closure_client {
    my ($loginid) = @_;
    my $brand = request->brand;

    my $client = BOM::User::Client->new({loginid => $loginid});

    send_email({
            from          => $brand->emails('support'),
            to            => $client->email,
            subject       => localize("We're sorry you're leaving"),
            template_name => 'account_closure',
            template_args => {
                name       => $client->first_name,
                brand_name => ucfirst $brand->name,
            },
            use_email_template    => 1,
            email_content_is_html => 1,
            use_event             => 1,
        });

    return undef;
}

sub _send_email_underage_disable_account {
    my ($client) = @_;

    my $website_name  = ucfirst BOM::Config::domain()->{default_domain};
    my $email_subject = localize("Your account has been closed");

    send_email({
            to            => $client->email,
            subject       => $email_subject,
            template_name => 'close_account_underage',
            template_args => {
                website_name => $website_name,
                name         => $client->first_name,
                title        => localize("We've closed your account"),
            },
            use_email_template    => 1,
            email_content_is_html => 1,
            use_event             => 1,
        });

    return undef;
}

async sub _send_CS_email_POA_uploaded {
    my ($client) = @_;
    my $brand = request->brand;

    # don't send POA notification if client is not age verified
    # POA don't make any sense if client is not age verified
    return undef unless $client->status->age_verification;

    # Checking if we already sent a notification for POA
    # redis replicated is used as this key is used in BO too
    my $redis_replicated_write = _redis_replicated_write();
    await $redis_replicated_write->connect;

    return undef unless await $redis_replicated_write->hsetnx('EMAIL_NOTIFICATION_POA', $client->binary_user_id, 1);

    unless ($client->landing_company->is_eu) {

        my $redis_events_read = _redis_events_read();
        await $redis_events_read->connect;

        # We should not send any POA notification if we already sent POI notification.
        return if await $redis_events_read->get(ONFIDO_POI_EMAIL_NOTIFICATION_SENT_PREFIX . $client->binary_user_id);
    }

    my $from_email = $brand->emails('no-reply');
    my $to_email   = $brand->emails('authentications');

    Email::Stuffer->from($from_email)->to($to_email)->subject('New uploaded POA document for: ' . $client->loginid)
        ->text_body('New proof of address document was uploaded for ' . $client->loginid)->send();

    return undef;
}

=head2 _send_email_notification_for_poa

Send email to CS when client submits a proof of address
document.

- send only if client is not fully authenticated
- send only if client has mt5 financial account

need to extend later for all landing companies

=cut

async sub _send_email_notification_for_poa {
    my (%args) = @_;

    my $document_entry = $args{document_entry};
    my $client         = $args{client};

    # no need to notify if document is not POA
    return undef unless (any { $_ eq $document_entry->{document_type} } POA_DOCUMENTS_TYPE);

    # don't send email if client is already authenticated
    return undef if $client->fully_authenticated();

    # send email for all landing company
    if ($client->landing_company->short) {
        await _send_CS_email_POA_uploaded($client);
        return undef;
    }

    my @mt_loginid_keys = map { "MT5_USER_GROUP::$_" } $client->user->get_mt5_loginids;

    return undef unless scalar(@mt_loginid_keys);

    my $redis_mt5_user = _redis_mt5user_read();
    await $redis_mt5_user->connect;
    my $mt5_groups = await $redis_mt5_user->mget(@mt_loginid_keys);

    # loop through all mt5 loginids check
    # non demo mt5 group has financial_stp|financial then
    # its considered as financial
    if (any { defined && /^(?!demo).*(_financial|_financial_stp)/ } @$mt5_groups) {
        await _send_CS_email_POA_uploaded($client);
    }
    return undef;
}

sub _send_email_onfido_check_exceeded_cs {
    my $request_count = shift;
    my $brand         = request->brand;

    my $system_email         = $brand->emails('system');
    my @email_recipient_list = ($brand->emails('support'), $brand->emails('compliance_alert'));
    my $website_name         = $brand->website_name;
    my $email_subject        = 'Onfido request count limit exceeded';
    my $email_template       = "\
        <p><b>IMPORTANT: We exceeded our Onfido authentication check request per day..</b></p>
        <p>We have sent about $request_count requests which exceeds (" . ONFIDO_REQUESTS_LIMIT . "\)
        our own request limit per day with Onfido server.</p>
        Team $website_name
        ";

    my $email_status =
        Email::Stuffer->from($system_email)->to(@email_recipient_list)->subject($email_subject)->html_body($email_template)->send();
    unless ($email_status) {
        $log->warn('failed to send Onfido check exceeded email.');
        return 0;
    }

    return 1;
}

=head2 _send_email_onfido_unsupported_country_cs

Send email to CS when Onfido does not support the client's country.

=cut

async sub _send_email_onfido_unsupported_country_cs {
    my ($client) = @_;
    my $brand = request->brand;

    # Prevent sending multiple emails for the same user
    my $redis_key         = ONFIDO_UNSUPPORTED_COUNTRY_EMAIL_PER_USER_PREFIX . $client->binary_user_id;
    my $redis_events_read = _redis_events_read();
    await $redis_events_read->connect;
    return undef if await $redis_events_read->exists($redis_key);

    my $email_subject  = "Automated age verification failed for " . $client->loginid;
    my $email_template = "\
        <p>Client residence is not supported by Onfido. Please verify age of client manually.</p>
        <p>
            <b>loginid:</b> " . $client->loginid . "\
            <b>place of birth:</b> " . $client->place_of_birth . "\
            <b>residence:</b> " . $client->residence . "\
        </p>
        Team " . $brand->website_name . "\
        ";

    my $from_email = $brand->emails('no-reply');
    my $to_email   = $brand->emails('authentications');
    my $email_status =
        Email::Stuffer->from($from_email)->to($to_email)->subject($email_subject)->html_body($email_template)->send();

    if ($email_status) {
        my $redis_events_write = _redis_events_write();
        await $redis_events_write->connect;
        await $redis_events_write->setex($redis_key, ONFIDO_UNSUPPORTED_COUNTRY_EMAIL_PER_USER_TIMEOUT, 1);
    } else {
        $log->warn('failed to send Onfido unsupported country email.');
        return 0;
    }

    return 1;
}

=head2 social_responsibility_check

This check is to verify whether clients are at-risk in trading, and this check is done on an on-going basis.
The checks to be done are in the social_responsibility_check.yml file in bom-config.
If a client has breached certain thresholds, then their social responsibility (SR) status will
be set at high-risk value "high" and an email will be sent to the SR team for further action.
After the email has been sent, the monitoring starts again.

The updated SR status is set to expire within 30 days (this is assuming that the client has not breached
any thresholds again) and will be placed back to their default status of low; if the SR team were to
re-adjust the status from BO, then the expiry time is no longer required. However, if the client has
breached thresholds again within the 30 day period, then:

- No email notification will be sent to the SR team, as they are already monitoring the client in their vCards for
3o-day period

- The next deposit/trade from the client will trigger the notification, since the thresholds have already
been breached.

This SR check is required as per the following document: https://www.gamblingcommission.gov.uk/PDF/Customer-interaction-%E2%80%93-guidance-for-remote-gambling-operators.pdf
(Read pages 2,4,6)

NOTE: This is for MX-MLT clients only (Last updated: 1st May, 2019)

=cut

sub social_responsibility_check {
    my $data  = shift;
    my $brand = request->brand;

    my $loginid = $data->{loginid} or die "Missing loginid";

    my $client = BOM::User::Client->new({loginid => $loginid}) or die "Invalid loginid: $loginid";

    my $redis = BOM::Config::Redis::redis_events();

    my $lock_key     = join q{-} => ('SOCIAL_RESPONSIBILITY_CHECK', $loginid,);
    my $acquire_lock = BOM::Platform::Redis::acquire_lock($lock_key, SR_CHECK_TIMEOUT);
    $log->warn("Social responsibility check already running for client: $loginid") unless $acquire_lock;
    return unless $acquire_lock;

    my $event_name = $loginid . ':sr_check:';

    my $client_sr_values = {};

    foreach my $sr_key (qw/losses net_deposits/) {
        $client_sr_values->{$sr_key} = $redis->get($event_name . $sr_key) // 0;
    }

    #get the net income of the client
    my $fa_net_income = $client->get_financial_assessment('net_income');

    # if the query returns undef value it means the client
    # hasn't filled the FA.
    my $client_net_income = $fa_net_income ? $NET_INCOME{$fa_net_income} : "No FA filled";

    my $threshold_list = first { $_->{net_income} eq $client_net_income } BOM::Config::social_responsibility_thresholds()->{limits}->@*;

    unless ($threshold_list) {
        $log->errorf('Net Annual Income of client %s does not much any of the values', $client->loginid);
        BOM::Platform::Redis::release_lock($lock_key);
        return undef;
    }

    my @breached_info;

    foreach my $attribute (keys %$client_sr_values) {

        my $client_attribute_val = $client_sr_values->{$attribute};
        my $threshold_val        = $threshold_list->{$attribute};

        if ($client_attribute_val >= $threshold_val) {

            $client_attribute_val = formatnumber('amount', $client->currency, $client_attribute_val);
            $threshold_val        = formatnumber('amount', $client->currency, $threshold_val);

            push @breached_info,
                {
                attribute     => $attribute,
                client_val    => $client_attribute_val,
                threshold_val => $threshold_val,
                net_income    => $fa_net_income // "No FA filled",
                };

            my $system_email  = $brand->emails('system');
            my $sr_email      = $brand->emails('social_responsibility');
            my $email_subject = 'Social Responsibility Check required - ' . $loginid;

            # Client cannot trade or deposit without a financial assessment check
            # Hence, they will be put under unwelcome
            $client->status->setnx('unwelcome', 'system', 'Social responsibility thresholds breached - Pending financial assessment')
                unless ($client_net_income ne "No FA filled" or $client->status->unwelcome);
            $client->status->setnx('financial_assessment_required', 'system', 'Social responsibility thresholds breached')
                unless ($client_net_income ne "No FA filled");

            my $tt = Template::AutoFilter->new({
                ABSOLUTE => 1,
                ENCODING => 'utf8'
            });

            my $data = {
                loginid       => $loginid,
                breached_info => \@breached_info
            };

            # Remove keys from redis
            $redis->del($event_name . $_) for keys %$client_sr_values;

            # Set the client's SR risk status as at-risk and keep it like that for 30 days
            # TODO: Remove this when we move from redis to database
            my $sr_status_key = $loginid . ':sr_risk_status';
            $redis->set(
                $sr_status_key => 'high',
                EX             => 86400 * 30
            );

            try {
                $tt->process(TEMPLATE_PREFIX_PATH . 'social_responsibiliy.html.tt', $data, \my $html);
                die "Template error: @{[$tt->error]}" if $tt->error;

                die "failed to send social responsibility email ($loginid)"
                    unless Email::Stuffer->from($system_email)->to($sr_email)->subject($email_subject)->html_body($html)->send();
                BOM::Platform::Redis::release_lock($lock_key);
                return undef;
            } catch {
                $log->warn($@);
                exception_logged();
                BOM::Platform::Redis::release_lock($lock_key);
                return undef;
            }
        }
    }
    BOM::Platform::Redis::release_lock($lock_key);
    return undef;
}

=head2 _client_onfido_details

Generate the list of client personal details needed for Onfido API

=cut

sub _client_onfido_details {
    my $client = shift;

    my $details = {
        (map { $_ => $client->$_ } qw(first_name last_name email)),
        dob => $client->date_of_birth,
    };

    # Add address info if the required fields not empty
    $details->{addresses} = [{
            building_number => $client->address_line_1,
            street          => $client->address_line_2 // $client->address_line_1,
            town            => $client->address_city,
            state           => $client->address_state,
            postcode        => $client->address_postcode,
            country         => uc(country_code2code($client->residence, 'alpha-2', 'alpha-3')),
        }]
        if all { length $client->$_ } ONFIDO_ADDRESS_REQUIRED_FIELDS;

    return $details;
}

async sub _get_applicant_and_file {
    my (%args) = @_;

    # Start with an applicant and the file data (which might come from S3
    # or be provided locally)
    my ($applicant, $file_data) = await Future->needs_all(
        _get_onfido_applicant(%args{onfido}, %args{client}, %args{uploaded_manually_by_staff}),
        _get_document_s3(%args{file_data}, %args{document_entry}),
    );

    return ($applicant, $file_data);
}

async sub _get_document_s3 {
    my (%args) = @_;

    my ($document_entry, $file_data) = @args{qw(document_entry file_data)};

    if (defined $file_data) {
        $log->debugf('Using file data directly from event');
        return $file_data;
    }

    my $s3_client = BOM::Platform::S3Client->new(BOM::Config::s3()->{document_auth});
    my $url       = $s3_client->get_s3_url($document_entry->{file_name});

    my $file = await _http()->GET($url, connection => 'close');

    return $file->decoded_content;
}

async sub _upload_documents {
    my (%args) = @_;

    my $onfido         = $args{onfido};
    my $client         = $args{client};
    my $document_entry = $args{document_entry};
    my $file_data      = $args{file_data};

    try {
        my $applicant;
        ($applicant, $file_data) = await _get_applicant_and_file(
            onfido                     => $onfido,
            client                     => $client,
            document_entry             => $document_entry,
            file_data                  => $file_data,
            uploaded_manually_by_staff => $args{uploaded_manually_by_staff},
        );

        my $loginid = $client->loginid;

        die('No applicant created for ' . $loginid . ' with place of birth ' . $client->place_of_birth . ' and residence ' . $client->residence)
            unless $applicant;

        $log->debugf('Applicant created: %s, uploading %d bytes for document', $applicant->id, length($file_data));

        # NOTE that this is very dependent on our current filename format
        my (undef, $type, $side) = split /\./, $document_entry->{file_name};

        $type = $ONFIDO_DOCUMENT_TYPE_MAPPING{$type} // 'unknown';
        $side =~ s{^\d+_?}{};
        $side = $ONFIDO_DOCUMENT_SIDE_MAPPING{$side} // 'front';
        $type = 'live_photo' if $side eq 'photo';

        my $future_upload_item;

        if ($type eq 'live_photo') {
            $future_upload_item = $onfido->live_photo_upload(
                applicant_id => $applicant->id,
                data         => $file_data,
                filename     => $document_entry->{file_name},
            );
        } else {
            # We already checked country when _get_applicant_and_file
            my $country = country_code2code($client->place_of_birth || $client->residence, 'alpha-2', 'alpha-3') // '';
            $future_upload_item = $onfido->document_upload(
                applicant_id    => $applicant->id,
                data            => $file_data,
                filename        => $document_entry->{file_name},
                issuing_country => uc($country),
                side            => $side,
                type            => $type,
            );
        }

        $future_upload_item->on_fail(
            sub {
                my ($err, $category, @details) = @_;
                $log->errorf('An error occurred while uploading document to Onfido for %s : %s', $client->loginid, $err)
                    unless ($category // '') eq 'http';

                # details is in res, req form
                my ($res) = @details;
                local $log->context->{place_of_birth} = $client->place_of_birth // 'unknown';
                $log->errorf('An error occurred while uploading document to Onfido for %s : %s with response %s ',
                    $client->loginid, $err, ($res ? $res->content : ''));

            });

        my $doc = await $future_upload_item;

        my $redis_events_write = _redis_events_write();

        if ($type eq 'live_photo') {
            BOM::User::Onfido::store_onfido_live_photo($doc, $applicant->id);
        } else {
            BOM::User::Onfido::store_onfido_document($doc, $applicant->id, $client->place_of_birth, $type, $side);

            await $redis_events_write->connect;
            # Set expiry time for document id key in case of no onfido response due to
            # `applicant_check` is not being called in `ready_for_authentication`
            await $redis_events_write->setex(ONFIDO_DOCUMENT_ID_PREFIX . $doc->id, ONFIDO_PENDING_REQUEST_TIMEOUT, $document_entry->{id});
        }

        $log->debugf('Document %s created for applicant %s', $doc->id, $applicant->id,);

        return 1;

    } catch {
        my $e = $@;
        $log->errorf('An error occurred while uploading document to Onfido for %s : %s', $client->loginid, $e);
        exception_logged();
    }
}

async sub _check_applicant {
    my ($args, $onfido, $applicant_id, $broker, $loginid, $residence, $redis_events_write, $client) = @_;

    try {
        my $error_type;

        my $future_applicant_check = $onfido->applicant_check(

            applicant_id => $applicant_id,
            # We don't want Onfido to start emailing people
            suppress_form_emails => 1,
            # Used for reporting and filtering in the web interface
            tags => ['automated', $broker, $loginid, $residence, 'brand:' . request->brand->name],
            # Note that there are additional report types which are not currently useful:
            # - proof_of_address - only works for UK documents
            # - street_level - involves posting a letter and requesting the user enter
            # a verification code on the Onfido site
            # plus others that would require the feature to be enabled on the account:
            # - identity
            # - watchlist
            # that onfido will use to compare photo uploaded
            # Document ID is not needed as Onfido will check for the most recently uploaded docs
            # https://documentation.onfido.com/v2/#request-body-parameters-report
            reports => [{
                    name => 'document',
                },
                {
                    name    => 'facial_similarity',
                    variant => 'standard',
                },
            ],
            # async flag if true will queue checks for processing and
            # return a response immediately
            async => 1,
            # The type is always "express" since we are sending data via API.
            # https://documentation.onfido.com/#check-types
            type => 'express',
        )->on_fail(
            sub {
                my (undef, undef, $response) = @_;

                $error_type = ($response and $response->content) ? decode_json_utf8($response->content)->{error}->{type} : '';

                if ($error_type eq 'incomplete_checks') {
                    $log->debugf('There is an existing request running for login_id: %s. The currenct request is pending until it finishes.',
                        $loginid);
                    $args->{is_pending} = 1;
                } else {
                    $log->errorf('An error occurred while processing Onfido verification for %s : %s', $loginid, join(' ', @_));
                }
            }
        )->on_done(
            sub {
                my ($check) = @_;

                BOM::User::Onfido::store_onfido_check($applicant_id, $check);
            });

        await $future_applicant_check;

        if (defined $error_type and $error_type eq 'incomplete_checks') {
            await $redis_events_write->setex(
                ONFIDO_PENDING_REQUEST_PREFIX . $client->binary_user_id,
                ONFIDO_PENDING_REQUEST_TIMEOUT,
                encode_json_utf8($args));
        }

    } catch {
        my $e = $@;
        $log->errorf('An error occurred while processing Onfido verification for %s : %s', $client->loginid, $e);
        exception_logged();
    }

    await Future->needs_all(_update_onfido_check_count($redis_events_write),
        _update_onfido_user_check_count($client, $loginid, $redis_events_write),);
}

async sub _update_onfido_check_count {
    my ($redis_events_write) = @_;

    my $record_count = await $redis_events_write->hincrby(ONFIDO_AUTHENTICATION_CHECK_MASTER_KEY, ONFIDO_REQUEST_COUNT_KEY, 1);

    if ($record_count == 1) {
        try {
            my $redis_response = await $redis_events_write->expire(ONFIDO_AUTHENTICATION_CHECK_MASTER_KEY, ONFIDO_LIMIT_TIMEOUT);
            return $redis_response;
        } catch {
            my $e = $@;
            $log->debugf("Failed in adding expire to ONFIDO_AUTHENTICATION_CHECK_MASTER_KEY: %s", $e);
            exception_logged();
        }
    }

    return 1;
}

async sub _update_onfido_user_check_count {
    my ($client, $loginid, $redis_events_write) = @_;
    my $user_count = await $redis_events_write->incr(ONFIDO_REQUEST_PER_USER_PREFIX . $client->binary_user_id);
    $log->debugf("Onfido check request triggered for %s with current request count=%d on %s",
        $loginid, $user_count, Date::Utility->new->datetime_ddmmmyy_hhmmss);

    if ($user_count == 1) {
        try {
            my $redis_response =
                await $redis_events_write->expire(ONFIDO_REQUEST_PER_USER_PREFIX . $client->binary_user_id, ONFIDO_REQUEST_PER_USER_TIMEOUT);
            return $redis_response;
        } catch {
            my $e = $@;
            $log->debugf("Failed in adding expire to ONFIDO_REQUEST_PER_USER_PREFIX: %s", $e);
            exception_logged();
        }
    }

    return 1;
}

=head2 qualifying_payment_check


This check is to verify whether clients have exceeded the qualifying transaction threshold
between an operator (us) and a customer (client). 'Qualifying transaction' refers to the deposits/withdrawals
made by a client over a certain period of time, in either a single transaction or a series of
linked transactions.

If the amount breached the thresholds, an email is sent out to the compliance team, and
the monitoring starts again. If a certain period of time has passed and no thresholds
have been breached, the monitoring will start from scratch again.

As at 14th August, 2019:
- The threshold value is at EUR3000, or its equivalent in USD/GBP
- Only applies for MX clients
- Applied for a period of 30 days

Regulation for qualifying transaction is specified in page 9, and the actions to be taken
are in page 16, in the following link: http://www.tynwald.org.im/business/opqp/sittings/20182021/2019-SD-0219.pdf

=cut

sub qualifying_payment_check {
    my $data  = shift;
    my $brand = request->brand;

    my $loginid = $data->{loginid};

    my $redis = BOM::Config::Redis::redis_events();

    # Event is taking place, so no need to keep in redis
    $redis->del($loginid . '_qualifying_payment_check');

    my $client = BOM::User::Client->new({loginid => $loginid});

    my $payment_check_limits = BOM::Config::payment_limits()->{qualifying_payment_check_limits}->{$client->landing_company->short};

    my $limit_val       = $payment_check_limits->{limit_for_days};
    my $limit_cur       = $payment_check_limits->{currency};
    my $client_currency = $client->currency;

    my $threshold_val = financialrounding('amount', $client_currency, convert_currency($limit_val, $limit_cur, $client_currency));

    my @breached_info;

    foreach my $action_key (qw/deposit withdrawal/) {
        my $key = $loginid . '_' . $action_key . '_qualifying_payment_check';

        my $value = financialrounding('amount', $client_currency, $redis->get($key) // 0);

        if ($value >= $threshold_val) {
            push @breached_info,
                {
                attribute     => $action_key,
                client_val    => $value,
                threshold_val => $threshold_val
                };

            $redis->del($key);
        }
    }

    if (@breached_info) {

        my $account     = $client->default_account;
        my $status      = $client->status;
        my $auth_status = $client->authentication_status;

        my ($total_deposits, $total_withdrawals) = $client->db->dbic->run(
            fixup => sub {
                my $statement = $_->prepare("SELECT * FROM betonmarkets.get_total_deposits_and_withdrawals(?)");
                $statement->execute($account->id);
                return @{$statement->fetchrow_arrayref};
            });

        my $client_info_required = {
            statuses               => join(',', @{$status->all}),
            age_verified           => $status->age_verification ? 'Yes' : 'No',
            authentication_status  => $auth_status eq 'no' ? 'Not authenticated' : $auth_status,
            account_opening_reason => $client->account_opening_reason,
            currency               => $client_currency,
            balance                => $account->balance,
            total_deposits         => $total_deposits,
            total_withdrawals      => $total_withdrawals
        };

        my $system_email     = $brand->emails('system');
        my $compliance_email = $brand->emails('compliance');
        my $email_subject    = "MX - Qualifying Payment 3K Check (Loginid: $loginid)";

        my $tt = Template::AutoFilter->new({
            ABSOLUTE => 1,
            ENCODING => 'utf8'
        });

        my $data = {
            loginid       => $loginid,
            breached_info => \@breached_info,
            client_info   => $client_info_required
        };

        try {
            $tt->process(TEMPLATE_PREFIX_PATH . 'qualifying_payment_check.html.tt', $data, \my $html);
            die "Template error: @{[$tt->error]}" if $tt->error;

            die "failed to send qualifying_payment_check email ($loginid)"
                unless Email::Stuffer->from($system_email)->to($compliance_email)->subject($email_subject)->html_body($html)->send();

            return undef;
        } catch {
            $log->warn($@);
            exception_logged();
            return undef;
        }

    }

    return undef;
}

=head2 payment_deposit

Event to handle deposit payment type.

=cut

async sub payment_deposit {
    my ($args) = @_;

    my $loginid = $args->{loginid}
        or die 'No client login ID supplied?';

    my $client = BOM::User::Client->new({loginid => $loginid})
        or die 'Could not instantiate client for login ID ' . $loginid;

    my $is_first_deposit  = $args->{is_first_deposit};
    my $payment_processor = $args->{payment_processor} // '';
    my $transaction_id    = $args->{transaction_id} // '';

    if ($is_first_deposit) {
        try {
            await _address_verification(client => $client);
        } catch {
            my $e = $@;
            $log->errorf('Failed to verify applicants address: %s', $e);
            exception_logged();
        }

        BOM::Platform::Client::IDAuthentication->new(client => $client)->run_authentication;
    }

    if (uc($payment_processor) =~ m/QIWI/) {
        _set_all_sibling_status({
            loginid => $loginid,
            status  => 'transfers_blocked',
            message => "Internal account transfers are blocked because of QIWI deposit into $loginid"
        });
    }

    my $card_processors = BOM::Config::Runtime->instance->app_config->payments->credit_card_processors;

    if (!$client->landing_company->is_eu && any { lc($_) eq lc($payment_processor) } @$card_processors) {
        $client->status->setnx('personal_details_locked', 'system', "A card deposit is made via $payment_processor with ref. id: $transaction_id");
        $client->save;
    }

    return BOM::Event::Services::Track::payment_deposit($args);
}

=head2 payment_withdrawal

Event to handle withdrawal payment type.

=cut

sub payment_withdrawal {
    my @args = @_;

    return BOM::Event::Services::Track::payment_withdrawal(@args);
}

=head2 payment_withdrawal_reversal

Event to handle withdrawal_reversal payment type.

=cut

sub payment_withdrawal_reversal {
    my @args = @_;

    return BOM::Event::Services::Track::payment_withdrawal_reversal(@args);
}

=head2 withdrawal_limit_reached

Sets 'needs_action' to a client

=cut

sub withdrawal_limit_reached {
    my ($args) = @_;

    my $client = BOM::User::Client->new({
            loginid => $args->{loginid},
        }) or die 'Could not instantiate client for login ID ' . $args->{loginid};

    return if $client->fully_authenticated();

    # check if POA is pending:
    my $documents = $client->documents_uploaded();
    return if $documents->{proof_of_address}->{is_pending};

    # set client as needs_action if only the status is not set yet
    unless (($client->authentication_status // '') eq 'needs_action') {
        $client->set_authentication('ID_DOCUMENT', {status => 'needs_action'});
        $client->save();
    }

    # allow client to upload documents
    $client->status->setnx('allow_document_upload', 'system', 'WITHDRAWAL_LIMIT_REACHED');

    return;
}

=head2 check_or_store_onfido_applicant

Check if applicant exists in database. Store applicant info if client loginid is valid.
This is due to manual checks at Onfido site by CS/Compliance. Such act will create a new applicant id.
We store the applicant as we want to link any check related to the client.

=cut

async sub check_or_store_onfido_applicant {
    my ($loginid, $applicant_id) = @_;
    #die if client not exists
    my $client = BOM::User::Client->new({loginid => $loginid}) or die "$loginid does not exists.";

    # gets all the applicant record for the user
    my $user_applicant = BOM::User::Onfido::get_all_user_onfido_applicant($client->binary_user_id);

    # returns 0 if the applicant record exists
    return 0 if $user_applicant->{$applicant_id};

    # fetch and store the new applicantid for the user
    my $onfido    = _onfido();
    my $applicant = await $onfido->applicant_get(applicant_id => $applicant_id);

    BOM::User::Onfido::store_onfido_applicant($applicant, $client->binary_user_id);

    return 1;

}

=head2 client_promo_codes_upload

Bulk assigns client promo codes uploaded in backoffice.

=cut

sub client_promo_codes_upload {
    my ($args) = @_;

    my ($email, $file, $data) = @$args{qw/email file data/};
    my $success = 0;
    my @errors  = ();

    for my $row (@$data) {
        try {
            my ($loginid, $code) = @$row;
            my $client;
            try {
                $client = BOM::User::Client->new({loginid => $loginid});
            } catch {
                die "client not found\n";
            }
            die "client not found\n" unless $client;
            die "client is virtual\n"                                                                    if $client->is_virtual;
            die "client already has a promo code (" . $client->client_promo_code->promotion_code . ")\n" if $client->client_promo_code;
            $client->promo_code($code);
            $client->save;
            $success++;
        } catch {
            push @errors, 'Error on line: ' . (join ', ', @$row) . ' - error: ' . $@;
        }
    }

    send_email({
        from    => '<no-reply@binary.com>',
        to      => $email,
        subject => "Bulk promo code assignment completed for file $file",
        message => ["Rows: " . scalar @$data, "Promo codes assigned: $success", "Errors: " . scalar @errors, @errors],
    });

    return 1;
}

=head2 signup

It is triggered for each B<signup> event emitted.
It can be called with the following parameters:

=over

=item * C<loginid> - required. Login Id of the user.

=item * C<properties> - Free-form dictionary of event properties, with B<loginid> and B<currency> automatically added.

=back

=cut

sub signup {
    my @args = @_;

    my ($data) = @args;

    my ($emit, $error);
    try {
        $emit = BOM::Platform::Event::Emitter::emit(
            'new_crypto_address',
            {
                loginid => $data->{loginid},
            });
    } catch {
        $error = $@;
    }

    $log->warnf('Failed to emit event - new_crypto_address - for loginid: %s, after creating a new account with error: %s', $data->{loginid}, $error)
        unless $emit;

    return BOM::Event::Services::Track::signup(@args);
}

=head2 transfer_between_accounts

It is triggered for each B<transfer_between_accounts> event emitted.
It is called with the following parameters:

=over

=item * C<loginid> - required. Login Id of the user.

=item * C<properties> - Free-form dictionary of event properties.

=back

=cut

sub transfer_between_accounts {
    my @args = @_;

    return BOM::Event::Services::Track::transfer_between_accounts(@args);
}

=head2 api_token_created

It is triggered for each B<api_token_create> event emitted.

=cut

sub api_token_created {
    my @args = @_;

    return BOM::Event::Services::Track::api_token_created(@args);
}

=head2 api_token_delete

It is triggered for each B<api_token_delete> event emitted.

=cut

sub api_token_deleted {
    my @args = @_;

    return BOM::Event::Services::Track::api_token_deleted(@args);
}

=head2 set_financial_assessment

It is triggered for each B<set_financial_assessment> event emitted.

=cut

sub set_financial_assessment {
    my @args = @_;

    return BOM::Event::Services::Track::set_financial_assessment(@args);
}

=head2 _set_all_sibling_status

Set and copy status to all siblings

=cut

sub _set_all_sibling_status {
    my ($args) = @_;

    my $loginid = $args->{loginid} or die 'No client login ID supplied';
    my $status  = $args->{status}  or die 'No status supplied';

    my $client       = BOM::User::Client->new({loginid => $loginid});
    my @all_loginids = $client->user->bom_real_loginids;

    for my $each_loginid (@all_loginids) {
        my $c = BOM::User::Client->new({loginid => $each_loginid});

        try {
            $c->status->setnx($status, 'system', $args->{message});
        } catch {
            my $e = $@;
            $log->errorf('Failed to set %s as %s : %s', $each_loginid, $status, $e);
            exception_logged();
        }
    }

    return;
}

=head2 handle_crypto_withdrawal

Handles all cryptocurrency withdrawal issue.

=cut

sub handle_crypto_withdrawal {
    my ($args) = @_;

    my $loginid = $args->{loginid} or die 'No client login ID supplied';

    if ($args->{error} && $args->{error} eq 'no_crypto_deposit') {
        _set_all_sibling_status({
            loginid => $loginid,
            status  => 'withdrawal_locked',
            message => 'Perform crypto withdrawal without crypto deposit [User not authenticated]'
        });
    }

    return;
}

=head2 aml_client_status_update

Send email to compliance-alerts@binary.com if some clients that are set withdrawal_locked

=cut

sub aml_client_status_update {
    my $data  = shift;
    my $brand = request->brand;

    my $template_args   = $data->{template_args};
    my $system_email    = $brand->emails('no-reply');
    my $to              = $brand->emails('compliance_alert');
    my $landing_company = $template_args->{landing_company} // '';
    my $email_subject   = "High risk status reached - pending KYC-FA - withdrawal locked accounts (" . $landing_company . ")";

    my $tt = Template::AutoFilter->new({
        ABSOLUTE => 1,
        ENCODING => 'utf8'
    });
    try {
        $tt->process(TEMPLATE_PREFIX_PATH . 'clients_update_status.html.tt', $template_args, \my $html);
        die "Template error: @{[$tt->error]}" if $tt->error;

        unless (Email::Stuffer->from($system_email)->to($to)->subject($email_subject)->html_body($html)->send()) {
            $log->errorf($template_args);
            die "failed to send aml_risk_clients_update_status email.";
        }

        return undef;
    } catch {
        $log->errorf("Failed to send AML Risk withdrawal_locked email to compliance %s on %s", $template_args, $@);
        exception_logged();
        return undef;
    }
}

=head2 _save_request_context

Store current request context.

=over

=item * C<applicant_id> - required. used as access key

=back

=cut

sub _save_request_context {
    my $applicant_id = shift;

    my $request     = request();
    my $context_req = {
        brand_name => $request->brand->name,
        language   => $request->language,
        app_id     => $request->app_id,
    };

    _redis_replicated_write()
        ->setex(ONFIDO_APPLICANT_CONTEXT_HOLDER_KEY . $applicant_id, TTL_ONFIDO_APPLICANT_CONTEXT_HOLDER, encode_json_utf8($context_req));
}

=head2 _restore_request

Restore request by stored context.

=over

=item * C<applicant_id> - required. used as access key

=item * C<tags> - required. used to restore brand

=back

=cut

async sub _restore_request {
    my ($applicant_id, $tags) = shift;

    my $context_req = await _redis_replicated_read()->get(ONFIDO_APPLICANT_CONTEXT_HOLDER_KEY . $applicant_id);

    my $brand = first { $_ =~ qr/^brand:/ } @$tags;
    $brand =~ s/brand:// if $brand;

    if ($context_req) {
        try {
            my $context  = decode_json_utf8 $context_req;
            my %req_args = map { $_ => $context->{$_} } grep { $context->{$_} } qw(brand_name language app_id);
            my $new_req  = BOM::Platform::Context::Request->new(%req_args, $brand ? (brand_name => $brand) : ());
            request($new_req);
        } catch {
            my $e = $@;
            $log->debugf("Failed in restoring cached context ONFIDO_APPLICANT_CONTEXT_HOLDER_KEY::%s: %s", $applicant_id, $e);
            exception_logged();
        }
    } elsif ($brand) {
        my $new_req = BOM::Platform::Context::Request->new(brand_name => $brand);
        request($new_req);
    }
}

=head2 _clear_cached_context

Clear stored context

=over

=item * C<applicant_id> - required. used as access key

=back

=cut

sub _clear_cached_context {
    my $applicant_id = shift;
    _redis_replicated_write()->del(ONFIDO_APPLICANT_CONTEXT_HOLDER_KEY . $applicant_id);
}

=head2 shared_payment_method_found

Triggered when clients with shared payment method are found.
Both clients should be flagged with cashier_locked and shared_payment_method.
Both clients must be emailed due to this situation.
Both clients must pass POI (handled at bom-user) and POO (handled manually by cs).

It takes the following arguments:

=over 4

=item * C<client_loginid> the client sharing a payment method

=item * C<shared_loginid> the 'other' client sharing the payment method

=item * C<staff> (optional) the staff name to call status setter

=back

Returns, undef.

=cut

async sub shared_payment_method_found {
    my ($args) = @_;
    my $client_loginid = $args->{client_loginid} or die 'No client login ID specified';
    my $shared_loginid = $args->{shared_loginid} or die 'No shared client login ID specified';

    my $client = BOM::User::Client->new({loginid => $client_loginid})
        or die 'Could not instantiate client for login ID ' . $client_loginid;

    my $shared = BOM::User::Client->new({loginid => $shared_loginid})
        or die 'Could not instantiate shared client for login ID ' . $shared_loginid;

    # Lock the cashier and set shared PM to both clients
    $args->{staff} //= 'system';
    $client->status->setnx('cashier_locked', $args->{staff}, 'Shared payment method found');
    $client->status->upsert('shared_payment_method', $args->{staff}, _shared_payment_reason($client, $shared_loginid));
    # This may be dropped when POI/POA refactoring is done
    $client->status->setnx('allow_document_upload', $args->{staff}, 'Shared payment method found') unless $client->status->age_verification;

    $shared->status->setnx('cashier_locked', $args->{staff}, 'Shared payment method found');
    $shared->status->upsert('shared_payment_method', $args->{staff}, _shared_payment_reason($shared, $client_loginid));
    # This may be dropped when POI/POA refactoring is done
    $shared->status->setnx('allow_document_upload', $args->{staff}, 'Shared payment method found') unless $shared->status->age_verification;

    # Send email to both clients
    _send_shared_payment_method_email($client);
    _send_shared_payment_method_email($shared);

    return;
}

=head2 _shared_payment_reason

Builds the shared payment reason.

It should append any new loginid into the current reason if not repeated.

Should not touch the current reason, just append new loginids.

If the client don't have the status then prepend the `Shared with:` message for convenience.

It takes the following arguments:

=over 4

=item * C<client> the client sharing a payment method

=item * C<shared_loginid> the new addition to the client shared loginid list

=back

Returns,
    a string with the new reason built for this client.

=cut

sub _shared_payment_reason {
    my $client         = shift;
    my $shared_loginid = shift;
    my $current        = $client->status->reason('shared_payment_method') // 'Shared with:';

    my $loginids_extractor = sub {
        my $string            = shift;
        my @all_brokers_codes = LandingCompany::Registry::all_broker_codes();
        # This will build a regex like CH[0-9]+|MLT[0-9]+|MX[0-9]+|CR[0-9]+|DC[0-9]+|MF[0-9]+
        # it excludes virtual broker codes
        my $regex_str = join '|', map { $_ . '[0-9]+' } grep { $_ !~ /VR/ } @all_brokers_codes;
        my @loginids  = $string =~ /(\b$regex_str\b)/g;
        return @loginids;
    };

    my @loginids = $loginids_extractor->($current);
    return $current if any { $_ eq $shared_loginid } @loginids;
    return join(' ', $current, $shared_loginid);
}

=head2 _send_shared_payment_method_email

Notifies the client via email regarding the shared payment methods situation it's involved.

It takes the following arguments:

=over 4

=item * C<client> the client sharing a payment method

=back

Returns, undef.

=cut

sub _send_shared_payment_method_email {
    my $client            = shift;
    my $client_first_name = $client->first_name;
    my $client_last_name  = $client->last_name;
    my $lang              = lc(request()->language // 'en');
    my $email             = $client->email;

    # Each client may come from a different brand
    # this switches the template accordingly
    my $brand = Brands->new_from_app_id($client->source);
    request(BOM::Platform::Context::Request->new(brand_name => $brand->name));

    send_email({
            from          => $brand->emails('authentications'),
            to            => $email,
            subject       => localize('Shared Payment Method account [_1]', $client->loginid),
            template_name => 'shared_payment_method',
            template_args => {
                client_first_name => $client_first_name,
                client_last_name  => $client_last_name,
                name              => $client_first_name,
                title             => localize('Shared payment method'),
                lang              => $lang,
                ask_poi           => !$client->status->age_verification,
            },
            use_email_template => 1,
        });

    return;
}

=head2 dispute_notification

Handle any dispute notification. Currently sending an e-mail to Payments 

=over 4

=item * C<args> - A hashref with the information received from dispute provider. 

=back

=head4 The hashref contains the following field

=over 4

=item * C<provider> -  A string with the provider name. Currently only B<acquired>. 

=item * C<data> -  A hashref to the payload as sent by the provider.

=back

returns, undef.

=cut

sub dispute_notification {
    my $args = shift;
    my ($provider, $data) = @{$args}{qw/provider data/};

    if ($provider eq 'acquired') {
        _handle_acquired($data);
    } else {
        $log->warnf("Received dispute_notification from an unknown provider '%s'", $provider);
    }

    return undef;
}

=head2 _handle_acquired 

Handle data send by Acquired.com. Events and payloads are described in https://developer.acquired.com/integrations/webhooks#events

B<Important> We are only supporting the B<fraud_new> and B<dispute_new>.

=over 4

=item * C<args> - A hashref data received from acquired.

=back

=head3 Data received from acquired

=over 4

=item * C<id> - A string with the unique reference for the webhook.

=item * C<timestamp> - A string with the timestamp of webhook.

=item * C<company_id> - A string with the integer identifier issued to merchants. (This is our company id)

=item * C<hash> - A string with the verification hash.

=item * C<event> - A string with the event for which the webhook is being triggered. Currently we only support B<fraud_new> and B<dispute_new>.

=item * C<list> - An arrayref of hashrefs described below. 

=back

=head4 Every hashref in lists:

=over 4

=item * C<mid> - A string with the integer merchant ID the transaction was processed through.

=item * C<transaction_id> - A string with the integer unique ID generated to identify the transaction. 

=item * C<merchant_order_id> - A string with unique value we'll use to identify each transaction, repeated from the request.

=item * C<parent_id> - A string with the transaction_id generated by Acquired  and returned in the original request.

=item * C<arn> - A string value set by the acquirer to track the transaction (optional) 

=item * C<rrn> - A string value set by the acquirer to tract the trasnaction (optional)

=item * C<fraud> - A hashref with the fraud information (only if C<event> is B<fraud_new>)

=item * C<dispute> - A hashref with the dispute information (only if C<event> is B<dispute_new>)

=back

=head4 Every fraud hashref have the following attributes

=over 4

=item * C<fraud_id> - A string with the unique ID generated to identify the dispute.

=item * C<date> -  A string with the date and time of dispute submission.

=item * C<amount> -  A string with the transaction amount.

=item * C<currency> -  A string with the trasaction currency, following ISO 4217 (3 digit code).

=item * C<auto_refund> - True/False value stating whether or not the transactionhas been auto refunded.

=back 

=head4 Every dispute hashref have the following attributes

=over 4

=item * C<dispute_id> - A string with the unique ID generated to identify the dispute.

=item * C<reason_code> - A string with the dispute category and/or condition.

=item * C<description> - A string with the description of dispute category and/or condition.

=item * C<date> -  A string with the date and time of dispute submission.

=item * C<amount> -  A string with the transaction amount.

=item * C<currency> -  A string with the trasaction currency, following ISO 4217 (3 digit code).

=back

=over 4

=item * C<history> - A hashref with the historical reference of this dispute.

=back

=head4 Every history hashref have the following attributes

=over 4

=item * C<retrieval_id> - A string with the unique ID Acquired generated to identifiy the retrieval of the dispute (optional)

=item * C<fraud_id> - A string with the unique ID Acquired generated to identify the fraud (optional)

=item * C<dispute_id> - A string with the value set by the acquirer to track the dipsute (optional)

=back

Returns, undef.

=cut 

sub _handle_acquired {
    my $data  = shift;
    my $event = $data->{event};
    die "Event not supported '$event'" unless $event eq 'fraud_new' || $event eq 'dispute_new';

    my ($timestamp, $company_id, $list) = @{$data}{qw/timestamp company_id list/};
    $timestamp =~ s/(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})/$1-$2-$3 $4:$5:$6/;

    my $payload = {
        timestamp  => $timestamp,
        company_id => $company_id,
        event      => $event,
        list       => $list,
    };

    my $subject;
    my $template_path;
    if ($event eq 'fraud_new') {
        $subject       = 'New Fraud';
        $template_path = TEMPLATE_PREFIX_PATH . 'new_fraud.html.tt';
    } else {
        $subject       = 'New Dispute';
        $template_path = TEMPLATE_PREFIX_PATH . 'new_dispute.html.tt';
    }

    my $tt = Template->new(ABSOLUTE => 1);
    try {
        $tt->process($template_path, $payload, \my $html);
        die "Template error: @{[$tt->error]}" if $tt->error;
        send_email({
            from                  => 'no-reply@deriv.com',
            to                    => 'x-cs@deriv.com,x-payops@deriv.com',
            subject               => $subject,
            message               => [$html],
            use_email_template    => 0,
            email_content_is_html => 1,
            skip_text2html        => 1,
        });
    } catch ($error) {
        $log->warnf("Error handling an event from 'acquired.com'. Details: $error");
        exception_logged();
    }

    return;
}

1;
