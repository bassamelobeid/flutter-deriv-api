package BOM::Event::Actions::Client;

use strict;
use warnings;

=head1 NAME

BOM::Event::Actions::Client

=head1 DESCRIPTION

Provides handlers for client-related events.

=cut

no indirect;

use Log::Any qw($log);
use IO::Async::Loop;
use Locale::Codes::Country qw(country_code2code);
use DataDog::DogStatsd::Helper;
use Brands;
use Syntax::Keyword::Try;
use Template::AutoFilter;
use List::Util qw(any all);
use List::UtilsBy qw(rev_nsort_by);
use Future::Utils qw(fmap0);
use Future::AsyncAwait;
use JSON::MaybeUTF8 qw(decode_json_utf8 encode_json_utf8);
use Date::Utility;
use BOM::Config::Runtime;

use BOM::Config;
use BOM::Platform::Context qw(localize);
use BOM::Platform::Email qw(send_email);
use Email::Stuffer;
use BOM::User;
use BOM::User::Client;
use BOM::Database::ClientDB;
use BOM::Database::UserDB;
use BOM::Platform::S3Client;
use BOM::Platform::Event::Emitter;
use BOM::Config::RedisReplicated;
use BOM::Event::Services;
use Encode qw(decode_utf8 encode_utf8);
use Time::HiRes;

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
use constant ONFIDO_REPORT_KEY_PREFIX               => 'ONFIDO::REPORT::ID::';
use constant ONFIDO_DOCUMENT_ID_PREFIX              => 'ONFIDO::DOCUMENT::ID::';

use constant ONFIDO_SUPPORTED_COUNTRIES_KEY                    => 'ONFIDO_SUPPORTED_COUNTRIES';
use constant ONFIDO_SUPPORTED_COUNTRIES_TIMEOUT                => $ENV{ONFIDO_SUPPORTED_COUNTRIES_TIMEOUT} // 7 * 86400;                     # 1 week
use constant ONFIDO_UNSUPPORTED_COUNTRY_EMAIL_PER_USER_PREFIX  => 'ONFIDO::UNSUPPORTED::COUNTRY::EMAIL::PER::USER::';
use constant ONFIDO_UNSUPPORTED_COUNTRY_EMAIL_PER_USER_TIMEOUT => $ENV{ONFIDO_UNSUPPORTED_COUNTRY_EMAIL_PER_USER_TIMEOUT} // 24 * 60 * 60;
use constant ONFIDO_AGE_EMAIL_PER_USER_PREFIX                  => 'ONFIDO::AGE::VERIFICATION::EMAIL::PER::USER::';
use constant ONFIDO_AGE_EMAIL_PER_USER_TIMEOUT                 => $ENV{ONFIDO_AGE_EMAIL_PER_USER_TIMEOUT} // 24 * 60 * 60;
use constant ONFIDO_DOB_MISMATCH_EMAIL_PER_USER_PREFIX         => 'ONFIDO::DOB::MISMATCH::EMAIL::PER::USER::';
use constant ONFIDO_AGE_BELOW_EIGHTEEN_EMAIL_PER_USER_PREFIX   => 'ONFIDO::AGE::BELOW::EIGHTEEN::EMAIL::PER::USER::';
use constant ONFIDO_ADDRESS_REQUIRED_FIELDS                    => qw(address_postcode residence);

# Conversion from our database to the Onfido available fields
my %ONFIDO_DOCUMENT_TYPE_MAPPING = (
    passport                                     => 'passport',
    certified_passport                           => 'passport',
    selfie_with_id                               => 'live_photo',
    driverslicense                               => 'driving_licence',
    cardstatement                                => 'bank_statement',
    bankstatement                                => 'bank_statement',
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

# List of document types that we use as proof of address
my @POA_DOCUMENTS_TYPE = qw(proofaddress payslip bankstatement cardstatement);

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
}

#load Brands object globally,
my $BRANDS = Brands->new();

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

        my $redis_events_write = _redis_events_write();

        await $redis_events_write->connect;

        # trigger address verification if not already address_verified
        try {
            await _address_verification(client => $client)
                if (not $client->status->address_verified
                and (await $redis_events_write->hsetnx('ADDRESS_VERIFICATION_TRIGGER', $client->binary_user_id, 1)));
        }
        catch {
            my $e = $@;
            $log->errorf('Failed to verify applicants address: %s', $e);
        }

        $log->debugf('Applying Onfido verification process for client %s', $loginid);
        my $file_data = $args->{content};

        # We need information from the database to confirm file name and date
        my $document_entry = _get_document_details(
            loginid => $loginid,
            file_id => $file_id
        );

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

    }
    catch {
        my $e = $@;
        $log->errorf('Failed to process Onfido application: %s', $e);
        DataDog::DogStatsd::Helper::stats_inc("event.document_upload.failure",);
    };

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

        my @documents = $onfido->document_list(applicant_id => $applicant_id)->get;

        $log->debugf('Have %d documents for applicant %s', 0 + @documents, $applicant_id);

        my ($doc, $poa_doc) = rev_nsort_by {
            ($_->side eq 'front' ? 10 : 1) * ($ONFIDO_DOCUMENT_TYPE_PRIORITY{$_->type} // 0)
        }
        @documents;

        my $client = BOM::User::Client->new({loginid => $loginid})
            or die 'Could not instantiate client for login ID ' . $loginid;

        if ($client->status->age_verification) {
            $log->debugf("Onfido request aborted because %s is already age-verified.", $loginid);
            return "Onfido request aborted because $loginid is already age-verified.";
        }

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

        DataDog::DogStatsd::Helper::stats_inc('event.ready_for_authentication.onfido.applicant_check.count');

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

        await Future->wait_any(
            $loop->timeout_future(after => VERIFICATION_TIMEOUT)->on_fail(sub { $log->errorf('Time out waiting for Onfido verfication.') }),

            _check_applicant($args, $onfido, $applicant_id, $broker, $loginid, $residence, $doc, $poa_doc, $redis_events_write, $client));
    }
    catch {
        my $e = $@;
        $log->errorf('Failed to process Onfido verification: %s', $e);
    };

    return;
}

async sub client_verification {
    my ($args) = @_;
    $log->debugf('Client verification with %s', $args);

    try {
        my $url = $args->{check_url};
        $log->debugf('Had client verification result %s with check URL %s', $args->{status}, $args->{check_url});

        my ($applicant_id, $check_id) = $url =~ m{/applicants/([^/]+)/checks/([^/]+)} or die 'no check ID found';

        my $check = await _onfido()->check_get(
            check_id     => $check_id,
            applicant_id => $applicant_id,
        );

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

            my $dbic = BOM::Database::UserDB::rose_db()->dbic;

            $dbic->run(
                fixup => sub {
                    $_->do(
                        'select users.add_onfido_check(?::TEXT, ?::TEXT, ?::TIMESTAMP, ?::TEXT, ?::TEXT, ?::TEXT, ?::TEXT, ?::TEXT, ?::TEXT, ?::TEXT[])',
                        undef,
                        $check->id,
                        $applicant_id,
                        Date::Utility->new($check->created_at)->datetime_yyyymmdd_hhmmss,
                        $check->href,
                        $check->type,
                        $check->status,
                        $check->result,
                        $check->results_uri,
                        $check->download_uri,
                        $check->tags
                    );
                });

            my @all_report = await $check->reports->as_list;

            for my $each_report (@all_report) {
                $dbic->run(
                    fixup => sub {
                        $_->do(
                            'select users.add_onfido_report(?::TEXT, ?::TEXT, ?::TEXT, ?::TIMESTAMP, ?::TEXT, ?::TEXT, ?::TEXT, ?::TEXT, ?::JSONB, ?::JSONB)',
                            undef,
                            $each_report->id,
                            $check->id,
                            $each_report->name,
                            Date::Utility->new($each_report->created_at)->datetime_yyyymmdd_hhmmss,
                            $each_report->status,
                            $each_report->result,
                            $each_report->sub_result,
                            $each_report->variant,
                            encode_json_utf8($each_report->breakdown),
                            encode_json_utf8($each_report->properties));
                    });
            }

            my $redis_events_write = _redis_events_write();

            my $pending_key = ONFIDO_PENDING_REQUEST_PREFIX . $client->binary_user_id;

            my $args = await $redis_events_write->get($pending_key);

            if (($check_status ne 'pass') and $args) {
                $log->debugf('Onfido check failed. Resending the last pending request: %s', $args);
                BOM::Platform::Event::Emitter::emit(ready_for_authentication => decode_json_utf8($args));
            }

            await $redis_events_write->del($pending_key);

            $log->debugf('Onfido pending key cleared');

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
                    my ($first_dob, @other_dob) = keys %dob;
                    # All documents should have the same date of birth
                    if (@other_dob) {
                        await _send_report_automated_age_verification_failed(
                            $client,
                            "as birth dates are not the same in the documents.",
                            ONFIDO_DOB_MISMATCH_EMAIL_PER_USER_PREFIX . $client->binary_user_id
                        );
                    } else {
                        # Override date_of_birth if there is mismatch between Onfido report and client submited data
                        if ($client->date_of_birth ne $first_dob) {
                            $client->date_of_birth($first_dob);
                            $client->save;
                            # Update applicant data
                            BOM::Platform::Event::Emitter::emit('sync_onfido_details', {loginid => $client->loginid});
                            $log->debugf("Updating client's date of birth due to mismatch between Onfido's response and submitted information");
                        }
                        # Age verified if report is clear and age is above minimum allowed age, otherwise send an email to notify cs
                        # Get the minimum age from the client's residence
                        my $min_age = $BRANDS->countries_instance->minimum_age_for_country($client->residence);
                        if (Date::Utility->new($first_dob)->is_before(Date::Utility->new->_minus_years($min_age))) {
                            _update_client_status(
                                client  => $client,
                                status  => 'age_verification',
                                message => 'Onfido - age verified'
                            );
                        } else {
                            await _send_report_automated_age_verification_failed(
                                $client,
                                "because Onfido reported the date of birth as $first_dob which is below age 18.",
                                ONFIDO_AGE_BELOW_EIGHTEEN_EMAIL_PER_USER_PREFIX . $client->binary_user_id
                            );
                        }
                    }
                } else {
                    my $result = @reports ? $reports[0]->result : 'blank';
                    my $failure_reason = "as onfido result was marked as $result.";
                    await _send_report_automated_age_verification_failed($client, $failure_reason,
                        ONFIDO_AGE_EMAIL_PER_USER_PREFIX . $client->binary_user_id);
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
                                    $log->infof('Expiration_date and document_id of document %s for client %s have been updated',
                                        $db_doc->id, $loginid);
                                }
                            }
                        }
                    }
                }
                return;
            }
            catch {
                my $e = $@;
                $log->errorf('An error occurred while retrieving reports for client %s check %s: %s', $loginid, $check->id, $e);
                die $e;
            }
        }
        catch {
            my $e = $@;
            $log->errorf('Failed to do verification callback - %s', $e);
            die $e;
        };
    }
    catch {
        my $e = $@;
        $log->errorf('Exception while handling client verification result: %s', $e);
    };

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
        my $client = BOM::User::Client->new({loginid => $loginid});

        my $dbic = BOM::Database::UserDB::rose_db()->dbic;

        my $applicant_data = $dbic->run(
            fixup => sub {
                my $sth = $_->selectrow_hashref('select * from users.get_onfido_applicant(?::BIGINT)', undef, $client->user_id);
            });

        my $applicant_id = $applicant_data->{id};

        # Only for users that are registered in onfido
        return unless $applicant_id;

        # Instantiate client and onfido object
        my $client_details_onfido = _client_onfido_details($client);

        $client_details_onfido->{applicant_id} = $applicant_id;

        my $response = await _onfido()->applicant_update(%$client_details_onfido);

        return $response;

    }
    catch {
        my $e = $@;
        $log->errorf('Failed to update details in Onfido: %s', $e);
    };

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

    # clear existing status
    $client->status->clear_address_verified();

    return await _address_verification(client => $client);
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
        $log->debugf('Returning as address verification already performed for same details.');
        return;
    }

    # Next step is an address check. Let's make sure that whatever they
    # are sending is valid at least to locality level.
    my $future_verify_ss = _smartystreets()->verify(%details);

    $future_verify_ss->on_fail(
        sub {
            $log->errorf('Address lookup failed for %s - %s', $client->loginid, $_[0]);
            return;
        }
        )->on_done(
        sub {
            DataDog::DogStatsd::Helper::stats_timing("event.address_verification.smartystreet.verify." . $future_verify_ss->state . ".elapsed",
                $future_verify_ss->elapsed);
        });

    my $addr = await $future_verify_ss;

    my $status = $addr->status;
    $log->debugf('Smartystreets verification status: %s', $status);
    $log->debugf('Address info back from SmartyStreets is %s', {%$addr});

    unless ($addr->accuracy_at_least('locality')) {
        DataDog::DogStatsd::Helper::stats_inc('smartystreet.verification.failure', {tags => [$status]});
        $log->warnf('Inaccurate address - only verified to %s precision', $addr->address_precision);
        return;
    }

    DataDog::DogStatsd::Helper::stats_inc('smartystreet.verification.success', {tags => [$status]});
    $log->debugf('Address verified with accuracy of locality level by smartystreet.');

    _update_client_status(
        client  => $client,
        status  => 'address_verified',
        message => 'SmartyStreets - address verified',
    );

    my $redis_events_write = _redis_events_write();
    await $redis_events_write->connect;
    await $redis_events_write->hset('ADDRESS_VERIFICATION_RESULT' . $client->binary_user_id,
        encode_utf8(join(' ', ($freeform, ($client->residence // '')))), $status);

    return;

}

=head2 _is_supported_country_onfido

Check if the passed country is supported by Onfido.

=over 4

=item * C<$country> - two letter country code to check for Onfido support

=back

=cut

async sub _is_supported_country_onfido {
    my ($country, $onfido) = @_;

    my $countries_list;
    my $redis_events_read = _redis_events_read();
    await $redis_events_read->connect;

    $countries_list = await $redis_events_read->get(ONFIDO_SUPPORTED_COUNTRIES_KEY);
    if ($countries_list) {
        $countries_list = decode_json_utf8($countries_list);
    } else {
        $countries_list = await $onfido->countries_list();
        if ($countries_list) {
            my $redis_events_write = _redis_events_write();
            await $redis_events_write->connect;
            await $redis_events_write->set(ONFIDO_SUPPORTED_COUNTRIES_KEY, encode_json_utf8($countries_list));
            await $redis_events_write->expire(ONFIDO_SUPPORTED_COUNTRIES_KEY, ONFIDO_SUPPORTED_COUNTRIES_TIMEOUT);
        }
    }

    return $countries_list->{uc $country} // 0;
}

async sub _get_onfido_applicant {
    my (%args) = @_;

    my $client                     = $args{client};
    my $onfido                     = $args{onfido};
    my $uploaded_manually_by_staff = $args{uploaded_manually_by_staff};

    my $country = $client->place_of_birth // $client->residence;
    try {
        my $dbic = BOM::Database::UserDB::rose_db()->dbic;

        my $is_supported_country = await _is_supported_country_onfido($country, $onfido);
        unless ($is_supported_country) {
            DataDog::DogStatsd::Helper::stats_inc('onfido.unsupported_country', {tags => [$country]});
            await _send_email_onfido_unsupported_country_cs($client) unless $uploaded_manually_by_staff;
            $log->debugf('Document not uploaded to Onfido as client is from list of countries not supported by Onfido');
            return undef;
        }
        # accessing applicant_data from onfido_applicant table
        my $applicant_data = $dbic->run(
            fixup => sub {
                my $sth = $_->selectrow_hashref('select * from users.get_onfido_applicant(?::BIGINT)', undef, $client->user_id);
            });

        my $applicant_id = $applicant_data->{id};

        if ($applicant_id) {
            $log->debugf('Applicant id already exists, returning that instead of creating new one');
            return await $onfido->applicant_get(applicant_id => $applicant_id);
        }

        my $start     = Time::HiRes::time();
        my $applicant = await $onfido->applicant_create(%{_client_onfido_details($client)});
        my $elapsed   = Time::HiRes::time() - $start;

        # saving data into onfido_applicant table
        $dbic->run(
            fixup => sub {
                $_->do(
                    'select users.add_onfido_applicant(?::TEXT,?::TIMESTAMP,?::TEXT,?::BIGINT)',
                    undef, $applicant->id, Date::Utility->new($applicant->created_at)->datetime_yyyymmdd_hhmmss,
                    $applicant->href, $client->user_id
                );
            });

        $applicant
            ? DataDog::DogStatsd::Helper::stats_timing("event.document_upload.onfido.applicant_create.done.elapsed",   $elapsed)
            : DataDog::DogStatsd::Helper::stats_timing("event.document_upload.onfido.applicant_create.failed.elapsed", $elapsed);

        return $applicant;
    }
    catch {
        my $e = $@;
        $log->warn($e);
    };

    return undef;
}

sub _get_document_details {
    my (%args) = @_;

    my $loginid = $args{loginid};
    my $file_id = $args{file_id};

    return do {
        my $start = Time::HiRes::time();
        my $dbic  = BOM::Database::ClientDB->new({
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
            my $elapsed = Time::HiRes::time() - $start;
            DataDog::DogStatsd::Helper::stats_timing("event.document_upload.database.document_lookup.elapsed", $elapsed);
        }
        catch {
            die "An error occurred while getting document details ($file_id) from database for login ID $loginid.";
        };
        $doc;
    };
}

sub _update_client_status {
    my (%args) = @_;

    my $client = $args{client};
    $log->debugf('Updating status on %s to %s (%s)', $client->loginid, $args{status}, $args{message});
    if ($args{status} eq 'age_verification') {
        _email_client_age_verified($client);
    }
    $client->status->set($args{status}, 'system', $args{message});

    return;
}

=head2 account_closure_event

Send email to CS that a client has closed their accounts.

=cut

sub account_closure {
    my $data = shift;

    my $system_email  = $BRANDS->emails('system');
    my $support_email = $BRANDS->emails('support');

    _send_email_account_closure_cs($data, $system_email, $support_email);

    _send_email_account_closure_client($data->{loginid}, $support_email);

    return undef;
}

sub _send_email_account_closure_cs {
    my ($data, $system_email, $support_email) = @_;

    my $loginid = $data->{loginid};
    my $user = BOM::User->new(loginid => $loginid);

    my @mt5_loginids = grep { $_ =~ qr/^MT[0-9]+$/ } $user->loginids;
    my $mt5_loginids_string = @mt5_loginids ? join ",", @mt5_loginids : undef;

    my $data_tt = {
        loginid               => $loginid,
        successfully_disabled => $data->{loginids_disabled},
        failed_disabled       => $data->{loginids_failed},
        mt5_loginids_string   => $mt5_loginids_string,
        reasoning             => $data->{closing_reason}};

    my $email_subject = "Account closure done by $loginid";

    # Send email to CS
    my $tt = Template::AutoFilter->new({
        ABSOLUTE => 1,
        ENCODING => 'utf8'
    });

    try {
        $tt->process('/home/git/regentmarkets/bom-events/share/templates/email/account_closure.html.tt', $data_tt, \my $html);
        die "Template error: @{[$tt->error]}" if $tt->error;

        die "failed to send email to CS for Account closure ($loginid)"
            unless Email::Stuffer->from($system_email)->to($support_email)->subject($email_subject)->html_body($html)->send();

        return undef;
    }
    catch {
        my $e = $@;
        $log->warn($e);
    };

    return undef;
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

    return unless $client->landing_company()->{actions}->{account_verified}->{email_client};

    return if $client->status->age_verification;
    my $from_email   = $BRANDS->emails('no-reply');
    my $website_name = $BRANDS->website_name;
    my $data_tt      = {
        client       => $client,
        l            => \&localize,
        website_name => $website_name,
    };
    my $email_subject = localize("Age and identity verification");
    my $tt = Template->new(ABSOLUTE => 1);

    try {
        $tt->process('/home/git/regentmarkets/bom-events/share/templates/email/age_verified.html.tt', $data_tt, \my $html);
        die "Template error: @{[$tt->error]}" if $tt->error;
        send_email({
            from                  => $from_email,
            to                    => $client->email,
            subject               => $email_subject,
            message               => [$html],
            use_email_template    => 1,
            email_content_is_html => 1,
            skip_text2html        => 1,
        });
    }
    catch {
        $log->warn($@);
    };
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

    my $client = BOM::User::Client->new($args);

    my $from_email   = $BRANDS->emails('no-reply');
    my $website_name = $BRANDS->website_name;

    my $data_tt = {
        client       => $client,
        l            => \&localize,
        website_name => $website_name,
    };

    my $email_subject = localize("Account verification");
    my $tt = Template->new(ABSOLUTE => 1);

    try {
        $tt->process('/home/git/regentmarkets/bom-events/share/templates/email/account_verification.html.tt', $data_tt, \my $html);
        die "Template error: @{[$tt->error]}" if $tt->error;
        send_email({
            from                  => $from_email,
            to                    => $client->email,
            subject               => $email_subject,
            message               => [$html],
            use_email_template    => 1,
            email_content_is_html => 1,
            skip_text2html        => 1,
        });
    }
    catch {
        $log->warn($@);
    };
    return undef;
}

sub _send_email_account_closure_client {
    my ($loginid, $support_email) = @_;

    my $client = BOM::User::Client->new({loginid => $loginid});

    my $client_email_template = localize(
        "\
        <p><b>We're sorry you're leaving.</b></p>
        <p>You have requested to close your [_1] accounts. This is to confirm that all your accounts have been terminated successfully.</p>
        <p>Thank you.</p>
        Team [_1]
        ", ucfirst BOM::Config::domain()->{default_domain});

    send_email({
        from                  => $support_email,
        to                    => $client->email,
        subject               => localize("We're sorry you're leaving"),
        message               => [$client_email_template],
        use_email_template    => 1,
        email_content_is_html => 1,
        skip_text2html        => 1
    });

    return undef;
}

=head2 _send_report_automated_age_verification_failed

Send email to CS because of which we were not able to mark client as age_verified

=cut

async sub _send_report_automated_age_verification_failed {
    my ($client, $failure_reason, $redis_key) = @_;

    # Prevent sending multiple emails for the same user
    my $redis_events_read = _redis_events_read();
    await $redis_events_read->connect;
    return undef if await $redis_events_read->exists($redis_key);

    my $loginid = $client->loginid;
    $log->debugf("Can not mark client (%s) as age verified, failure reason is %s", $loginid, $failure_reason);

    my $email_subject = "Automated age verification failed for $loginid";

    my $from_email = $BRANDS->emails('no-reply');
    my $to_email   = $BRANDS->emails('authentications');
    my $email_status =
        Email::Stuffer->from($from_email)->to($to_email)->subject($email_subject)
        ->text_body("We were unable to automatically mark client ($loginid) as age verified, $failure_reason Please check and verify.")->send();

    if ($email_status) {
        my $redis_events_write = _redis_events_write();
        await $redis_events_write->connect;
        await $redis_events_write->set($redis_key, 1);
        await $redis_events_write->expire($redis_key, ONFIDO_AGE_EMAIL_PER_USER_TIMEOUT);
    } else {
        $log->warn('failed to send Onfido age verification email.');
        return 0;
    }

    return undef;
}

async sub _send_poa_email {
    my ($client) = @_;
    my $redis_replicated_write = _redis_replicated_write();
    await $redis_replicated_write->connect;

    my $need_to_send_email = await $redis_replicated_write->hsetnx('EMAIL_NOTIFICATION_POA', $client->binary_user_id, 1);

    my $from_email = $BRANDS->emails('no-reply');
    my $to_email   = $BRANDS->emails('authentications');
    # using replicated one
    # as this key is used in backoffice as well
    Email::Stuffer->from($from_email)->to($to_email)->subject('New uploaded POA document for: ' . $client->loginid)
        ->text_body('New proof of address document was uploaded for ' . $client->loginid)->send()
        if $need_to_send_email;

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
    return undef unless (any { $_ eq $document_entry->{document_type} } @POA_DOCUMENTS_TYPE);

    # don't send email if client is already authenticated
    return undef if $client->fully_authenticated();

    # send email for landing company other than costarica
    # TODO: remove this landing company check
    # when we enable it for all landing companies
    # this should be a config in landing company
    unless ($client->landing_company->short eq 'svg') {
        await _send_poa_email($client);
        return undef;
    }

    my @mt_loginid_keys = map { /^MT(\d+)$/ ? "MT5_USER_GROUP::$1" : () } $client->user->loginids;

    return undef unless scalar(@mt_loginid_keys);

    my $redis_mt5_user = _redis_mt5user_read();
    await $redis_mt5_user->connect;
    my $mt5_groups = await $redis_mt5_user->mget(@mt_loginid_keys);

    # loop through all mt5 loginids check
    # non demo mt5 group has advanced|standard then
    # its considered as financial
    if (any { defined && /^(?!demo).*(_standard|_advanced)/ } @$mt5_groups) {
        await _send_poa_email($client);
    }
    return undef;
}

sub _send_email_onfido_check_exceeded_cs {
    my $request_count        = shift;
    my $system_email         = $BRANDS->emails('system');
    my @email_recipient_list = ($BRANDS->emails('support'), $BRANDS->emails('compliance_alert'));
    my $email_subject        = 'Onfido request count limit exceeded';
    my $email_template       = "\
        <p><b>IMPORTANT: We exceeded our Onfido authentication check request per day..</b></p>
        <p>We have sent about $request_count requests which exceeds (" . ONFIDO_REQUESTS_LIMIT . "\)
        our own request limit per day with Onfido server.</p>
        Team Binary.com
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
        Team Binary.com
        ";

    my $from_email = $BRANDS->emails('no-reply');
    my $to_email   = $BRANDS->emails('authentications');
    my $email_status =
        Email::Stuffer->from($from_email)->to($to_email)->subject($email_subject)->html_body($email_template)->send();

    if ($email_status) {
        my $redis_events_write = _redis_events_write();
        await $redis_events_write->connect;
        await $redis_events_write->set($redis_key, 1);
        await $redis_events_write->expire($redis_key, ONFIDO_UNSUPPORTED_COUNTRY_EMAIL_PER_USER_TIMEOUT);
    } else {
        $log->warn('failed to send Onfido unsupported country email.');
        return 0;
    }

    return 1;
}

=head2 social_responsibility_check

This check is to verify whether clients are at-risk in trading, and this check is done on an on-going basis.
The checks to be done are in the social_responsibility_check.yml file in bom-config.
If a client has breached certain thresholds, then an email will be sent to the
social responsibility team for further action.
After the email has been sent, the monitoring starts again.

This is required as per the following document: https://www.gamblingcommission.gov.uk/PDF/Customer-interaction-%E2%80%93-guidance-for-remote-gambling-operators.pdf
(Read pages 2,4,6)

NOTE: This is for MX-MLT clients only (Last updated: 1st May, 2019)

=cut

sub social_responsibility_check {
    my $data = shift;

    my $loginid = $data->{loginid};

    my $redis = BOM::Config::RedisReplicated::redis_events();

    my $hash_key   = 'social_responsibility';
    my $event_name = $loginid . '_sr_check';

    my $client_sr_values = {};

    foreach my $sr_key (qw/num_contract turnover losses deposit_amount deposit_count/) {
        $client_sr_values->{$sr_key} = $redis->hget($hash_key, $loginid . '_' . $sr_key) // 0;
    }

    # Remove flag from redis
    $redis->hdel($hash_key, $event_name);

    foreach my $threshold_list (@{BOM::Config::social_responsibility_thresholds()->{limits}}) {

        my $hits_required = $threshold_list->{hits_required};

        my @breached_info;

        my $hits = 0;

        foreach my $attribute (keys %$client_sr_values) {

            my $client_attribute_val = $client_sr_values->{$attribute};
            my $threshold_val        = $threshold_list->{$attribute};

            if ($client_attribute_val >= $threshold_val) {
                push @breached_info,
                    {
                    attribute     => $attribute,
                    client_val    => $client_attribute_val,
                    threshold_val => $threshold_val
                    };

                $hits++;
            }
        }

        last unless $hits;

        if ($hits >= $hits_required) {

            my $system_email  = $BRANDS->emails('system');
            my $sr_email      = $BRANDS->emails('social_responsibility');
            my $email_subject = 'Social Responsibility Check required - ' . $loginid;

            my $tt = Template::AutoFilter->new({
                ABSOLUTE => 1,
                ENCODING => 'utf8'
            });

            my $data = {
                loginid       => $loginid,
                breached_info => \@breached_info
            };

            # Remove keys from redis
            $redis->hdel($hash_key, $loginid . '_' . $_) for keys %$client_sr_values;

            try {
                $tt->process('/home/git/regentmarkets/bom-events/share/templates/email/social_responsibiliy.html.tt', $data, \my $html);
                die "Template error: @{[$tt->error]}" if $tt->error;

                die "failed to send social responsibility email ($loginid)"
                    unless Email::Stuffer->from($system_email)->to($sr_email)->subject($email_subject)->html_body($html)->send();

                return undef;
            }
            catch {
                $log->warn($@);
                return undef;
            };
        }
    }

    return undef;
}

=head2 _client_onfido_details

Generate the list of client personal details needed for Onfido API

=cut

sub _client_onfido_details {
    my $client = shift;

    my $details = {
        (map { $_ => $client->$_ } qw(first_name last_name email)),
        title   => $client->salutation,
        dob     => $client->date_of_birth,
        country => uc(country_code2code($client->place_of_birth, 'alpha-2', 'alpha-3')),
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

    my $start_time = Time::HiRes::time();

    # Start with an applicant and the file data (which might come from S3
    # or be provided locally)
    my ($applicant, $file_data) = await Future->needs_all(
        _get_onfido_applicant(%args{onfido}, %args{client}, %args{uploaded_manually_by_staff}),
        _get_document_s3(%args{file_data}, %args{document_entry}),
    );

    DataDog::DogStatsd::Helper::stats_timing("event.document_upload.onfido.upload.triggered.elapse ", Time::HiRes::time() - $start_time,);

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

    my $file = await _http()->GET($url, connection => 'close')->on_ready(
        sub {
            my $f = shift;
            DataDog::DogStatsd::Helper::stats_timing("event.document_upload.s3.download." . $f->state . ".elapsed", $f->elapsed,);
        });

    return $file->decoded_content;
}

async sub _upload_documents {
    my (%args) = @_;

    my $onfido                     = $args{onfido};
    my $client                     = $args{client};
    my $document_entry             = $args{document_entry};
    my $file_data                  = $args{file_data};
    my $uploaded_manually_by_staff = $args{uploaded_manually_by_staff};

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
        my (undef, $type, $side, $file_type) = split /\./, $document_entry->{file_name};

        $type = $ONFIDO_DOCUMENT_TYPE_MAPPING{$type} // 'unknown';
        $side =~ s{^\d+_?}{};
        $side = $ONFIDO_DOCUMENT_SIDE_MAPPING{$side} // 'front';
        $type = 'live_photo' if $side eq 'photo';

        my $future_upload_item;

        my $start_time = Time::HiRes::time();

        if ($type eq 'live_photo') {
            $future_upload_item = $onfido->live_photo_upload(
                applicant_id => $applicant->id,
                data         => $file_data,
                filename     => $document_entry->{file_name},
            );
        } else {
            $future_upload_item = $onfido->document_upload(
                applicant_id    => $applicant->id,
                data            => $file_data,
                filename        => $document_entry->{file_name},
                issuing_country => uc(country_code2code($client->place_of_birth, 'alpha-2', 'alpha-3')),
                side            => $side,
                type            => $type,
            );
        }

        $future_upload_item->on_fail(
            sub {
                my ($err, $category, @details) = @_;

                $log->errorf('An error occurred while uploading document to Onfido: %s', $err) unless ($category // '') eq 'http';

                # details is in res, req form
                my ($res) = @details;
                $log->errorf('An error occurred while uploading document to Onfido: %s with response %s', $err, ($res ? $res->content : ''));

            });

        my $doc = await $future_upload_item;

        DataDog::DogStatsd::Helper::stats_timing("event.document_upload.onfido.upload.triggered.elapse ", Time::HiRes::time() - $start_time);

        my $clientdb = BOM::Database::ClientDB->new({broker_code => $client->broker});
        my $dbic = BOM::Database::UserDB::rose_db()->dbic;

        if ($type eq 'live_photo') {
            $dbic->run(
                fixup => sub {
                    $_->do(
                        'select users.add_onfido_live_photo(?::TEXT, ?::TEXT, ?::TIMESTAMP, ?::TEXT, ?::TEXT, ?::TEXT, ?::TEXT, ?::INTEGER)',
                        undef, $doc->id, $applicant->id, Date::Utility->new($doc->created_at)->datetime_yyyymmdd_hhmmss,
                        $doc->href, $doc->download_href, $doc->file_name, $doc->file_type, $doc->file_size
                    );
                });
        } else {
            $dbic->run(
                fixup => sub {
                    $_->do(
                        'select users.add_onfido_document(?::TEXT, ?::TEXT, ?::TIMESTAMP, ?::TEXT, ?::TEXT, ?::TEXT, ?::TEXT, ?::TEXT, ?::TEXT, ?::TEXT, ?::INTEGER)',
                        undef,
                        $doc->id,
                        $applicant->id,
                        Date::Utility->new($doc->created_at)->datetime_yyyymmdd_hhmmss,
                        $doc->href,
                        $doc->download_href,
                        $type,
                        $side,
                        uc(country_code2code($client->place_of_birth, 'alpha-2', 'alpha-3')),
                        $doc->file_name,
                        $doc->file_type,
                        $doc->file_size
                    );
                });
        }

        $log->debugf('Document %s created for applicant %s', $doc->id, $applicant->id,);

        # At this point, we may have enough information to start verification.
        # Since this could vary by landing company, the logic ideally belongs there,
        # but for now we're using the Onfido rules and assuming that we need 3 things
        # in all cases:
        # - proof of identity
        # - proof of address
        # - "live" photo showing the client holding one of the documents
        # We start by pulling a full list of documents and photos for this applicant.
        # Note that we *cannot* just use the database for this, because there's
        # a race condition: if 2 documents are uploaded simultaneously, then we'll
        # assume that we've also processed and sent to Onfido, but one of those may
        # still be stuck in the queue.
        $start_time = Time::HiRes::time();

        my ($documents, $photos) = await Future->needs_all($onfido->document_list(applicant_id => $applicant->id)->as_arrayref,
            $onfido->photo_list(applicant_id => $applicant->id)->as_arrayref);

        $log->debugf('Have %d documents for applicant %s', 0 + @$documents, $applicant->id);
        $log->debugf('Have %d photos for applicant %s',    0 + @$photos,    $applicant->id);

        # Since the list of types may change, and we don't really have a good
        # way of mapping the Onfido data to our document types at the moment,
        # we use a basic heuristic of "if we sent it, this is one of the documents
        # that we need for verification, and we should be able to verify when
        # we have 2 or more including a live photo".
        return 1 if @$documents < 2 or not grep { $_->isa('WebService::Async::Onfido::Photo') } @$photos;

        $log->debugf('Emitting ready_for_authentication event for %s (applicant ID %s)', $loginid, $applicant->id);

        BOM::Platform::Event::Emitter::emit(
            ready_for_authentication => {
                loginid      => $loginid,
                applicant_id => $applicant->id,
            });

        DataDog::DogStatsd::Helper::stats_timing("event.document_upload.onfido.list_documents.triggered.elapse ", Time::HiRes::time() - $start_time);

        return 1;

    }
    catch {
        my $e = $@;
        $log->errorf('An error occurred while uploading document to Onfido: %s', $e);
    }
}

async sub _check_applicant {
    my ($args, $onfido, $applicant_id, $broker, $loginid, $residence, $doc, $poa_doc, $redis_events_write, $client) = @_;

    try {
        my $error_type;

        my $future_applicant_check = $onfido->applicant_check(

            applicant_id => $applicant_id,
            # We don't want Onfido to start emailing people
            suppress_form_emails => 1,
            # Used for reporting and filtering in the web interface
            tags => ['automated', $broker, $loginid, $residence],
            # Note that there are additional report types which are not currently useful:
            # - proof_of_address - only works for UK documents
            # - street_level - involves posting a letter and requesting the user enter
            # a verification code on the Onfido site
            # plus others that would require the feature to be enabled on the account:
            # - identity
            # - watchlist
            # for facial similarity we are passing document id for document
            # that onfido will use to compare photo uploaded
            reports => [{
                    name      => 'document',
                    documents => [$doc->id],
                },
                {
                    name      => 'facial_similarity',
                    variant   => 'standard',
                    documents => [$doc->id],
                },
                # We also submit a POA document to see if we can extract any information from it
                (
                    $poa_doc
                    ? {
                        name      => 'document',
                        documents => [$poa_doc->id],
                        }
                    : ())
            ],
            # async flag if true will queue checks for processing and
            # return a response immediately
            async => 1,
            # The type is always "express" since we are sending data via API.
            # https://documentation.onfido.com/#check-types
            type => 'express',
            )->on_fail(
            sub {
                my ($type, $message, $response, $request) = @_;

                $error_type = ($response and $response->content) ? decode_json_utf8($response->content)->{error}->{type} : '';

                if ($error_type eq 'incomplete_checks') {
                    $log->debugf('There is an existing request running for login_id: %s. The currenct request is pending until it finishes.',
                        $loginid);
                    $args->{is_pending} = 1;
                } else {
                    $log->errorf('An error occurred while processing Onfido verification: %s', join(' ', @_));
                }
            });

        my $start_time = Time::HiRes::time();

        await $future_applicant_check;

        if (defined $error_type and $error_type eq 'incomplete_checks') {
            await $redis_events_write->set(ONFIDO_PENDING_REQUEST_PREFIX . $client->binary_user_id, encode_json_utf8($args));
            await $redis_events_write->expire(ONFIDO_PENDING_REQUEST_PREFIX . $client->binary_user_id, ONFIDO_PENDING_REQUEST_TIMEOUT);
        }

        DataDog::DogStatsd::Helper::stats_timing(
            "event.ready_for_authentication.onfido.applicant_check.triggered.elapsed",
            Time::HiRes::time() - $start_time,
        );
    }
    catch {
        my $e = $@;
        $log->errorf('An error occurred while processing Onfido verification: %s', $e);
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
        }
        catch {
            my $e = $@;
            $log->debugf("Failed in adding expire to ONFIDO_AUTHENTICATION_CHECK_MASTER_KEY: %s", $e);
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
        }
        catch {
            my $e = $@;
            $log->debugf("Failed in adding expire to ONFIDO_REQUEST_PER_USER_PREFIX: %s", $e);
        }
    }

    return 1;
}

1;
