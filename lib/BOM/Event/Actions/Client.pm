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
use Encode                           qw(decode_utf8 encode_utf8);
use ExchangeRates::CurrencyConverter qw(convert_currency);
use File::Temp;
use Format::Util::Numbers qw(financialrounding formatnumber);
use Future::AsyncAwait;
use Future::Utils qw(fmap0);
use IO::Async::Loop;
use JSON::MaybeUTF8        qw(decode_json_utf8 encode_json_utf8);
use List::Util             qw(any all first uniq none min uniqstr);
use Locale::Codes::Country qw(country_code2code);
use Log::Any               qw($log);
use POSIX                  qw(strftime);
use Syntax::Keyword::Try;
use Template::AutoFilter;
use Time::HiRes;
use Text::Levenshtein::XS;
use Array::Utils qw(intersect array_minus);
use Scalar::Util qw(blessed);
use Text::Trim   qw(trim);
use WebService::MyAffiliates;
use Array::Utils qw(array_minus);
use Digest::SHA  qw/sha256_hex/;

use BOM::Config;
use BOM::Config::Onfido;
use BOM::Config::Redis;
use BOM::Config::Runtime;
use BOM::Config::Services;
use BOM::Database::ClientDB;
use BOM::Database::CommissionDB;
use BOM::Database::UserDB;
use BOM::Event::Actions::Common;
use BOM::Event::Services;
use BOM::Event::Services::Track;
use BOM::Event::Utility qw(exception_logged);
use BOM::Platform::Client::IDAuthentication;
use BOM::Platform::Context qw(localize request);
use BOM::Platform::Email   qw(send_email);
use BOM::Platform::Event::Emitter;
use BOM::Platform::Redis;
use BOM::Platform::S3Client;
use BOM::User;
use BOM::User::Client;
use BOM::User::Client::PaymentTransaction;
use BOM::User::Onfido;
use BOM::User::PaymentRecord;
use BOM::Rules::Engine;
use BOM::Config::Payments::PaymentMethods;
use BOM::Platform::Client::AntiFraud;
use Locale::Country qw/code2country/;
use BOM::Platform::Client::AntiFraud;
use BOM::Platform::Utility;

# this one shoud come after BOM::Platform::Email
use Email::Stuffer;

# For smartystreets datadog stats_timing
$Future::TIMES = 1;

# Number of seconds to allow for just the verification step.
use constant VERIFICATION_TIMEOUT => 60;

# Redis key namespace to store onfido applicant id
use constant ONFIDO_REQUEST_PER_USER_PREFIX  => 'ONFIDO::REQUEST::PER::USER::';
use constant ONFIDO_REQUEST_PER_USER_TIMEOUT => BOM::User::Onfido::timeout_per_user();
use constant ONFIDO_PENDING_REQUEST_PREFIX   => 'ONFIDO::PENDING::REQUEST::';
use constant ONFIDO_PENDING_REQUEST_TIMEOUT  => 20 * 60;

# Redis key namespace to store onfido results and link
use constant ONFIDO_LIMIT_TIMEOUT                   => $ENV{ONFIDO_LIMIT_TIMEOUT} // 24 * 60 * 60;
use constant ONFIDO_AUTHENTICATION_CHECK_MASTER_KEY => 'ONFIDO_AUTHENTICATION_REQUEST_CHECK';
use constant ONFIDO_REQUEST_COUNT_KEY               => 'ONFIDO_REQUEST_COUNT';
use constant ONFIDO_CHECK_EXCEEDED_KEY              => 'ONFIDO_CHECK_EXCEEDED';
use constant ONFIDO_APPLICANT_CONTEXT_HOLDER_KEY    => 'ONFIDO::APPLICANT_CONTEXT::ID::';
use constant ONFIDO_REPORT_KEY_PREFIX               => 'ONFIDO::REPORT::ID::';
use constant ONFIDO_DOCUMENT_ID_PREFIX              => 'ONFIDO::DOCUMENT::ID::';
use constant ONFIDO_IS_A_RESUBMISSION_KEY_PREFIX    => 'ONFIDO::IS_A_RESUBMISSION::ID::';

use constant ONFIDO_SUPPORTED_COUNTRIES_KEY                    => 'ONFIDO_SUPPORTED_COUNTRIES';
use constant ONFIDO_SUPPORTED_COUNTRIES_TIMEOUT                => $ENV{ONFIDO_SUPPORTED_COUNTRIES_TIMEOUT} // 7 * 86400;    # 1 week
use constant ONFIDO_UNSUPPORTED_COUNTRY_EMAIL_PER_USER_PREFIX  => 'ONFIDO::UNSUPPORTED::COUNTRY::EMAIL::PER::USER::';
use constant ONFIDO_UNSUPPORTED_COUNTRY_EMAIL_PER_USER_TIMEOUT => $ENV{ONFIDO_UNSUPPORTED_COUNTRY_EMAIL_PER_USER_TIMEOUT} // 24 * 60 * 60;
use constant ONFIDO_AGE_EMAIL_PER_USER_TIMEOUT                 => $ENV{ONFIDO_AGE_EMAIL_PER_USER_TIMEOUT}                 // 24 * 60 * 60;
use constant ONFIDO_AGE_BELOW_EIGHTEEN_EMAIL_PER_USER_PREFIX   => 'ONFIDO::AGE::BELOW::EIGHTEEN::EMAIL::PER::USER::';
use constant ONFIDO_UPLOAD_TIMEOUT_SECONDS                     => 30;
use constant SR_CHECK_TIMEOUT                                  => 5;
use constant FORGED_DOCUMENT_EMAIL_LOCK                        => 'FORGED::EMAIL::LOCK::';
use constant TTL_FORGED_DOCUMENT_EMAIL_LOCK                    => 600;
use constant PAYMENT_ACCOUNT_LIMIT_REACHED_TTL                 => 86400;                                                    # one day
use constant PAYMENT_ACCOUNT_LIMIT_REACHED_KEY                 => 'PAYMENT_ACCOUNT_LIMIT_REACHED';
use constant ONFIDO_DAILY_LIMIT_FLAG                           => 'ONFIDO_DAILY_LIMIT_FLAG::';
use constant SECONDS_IN_DAY                                    => 86400;

# Redis TTLs
use constant TTL_ONFIDO_APPLICANT_CONTEXT_HOLDER => 240 * 60 * 60;                                                          # 10 days in seconds

# Redis key for resubmission counter
use constant ONFIDO_RESUBMISSION_COUNTER_KEY_PREFIX => 'ONFIDO::RESUBMISSION_COUNTER::ID::';
use constant ONFIDO_RESUBMISSION_COUNTER_TTL        => 2592000;                                                             # 30 days (in seconds)

# Redis key for SR keys expire
use constant SR_30_DAYS_EXP => 86400 * 30;

# Applicant check lock
use constant APPLICANT_CHECK_LOCK_PREFIX => 'ONFIDO::APPLICANT_CHECK_LOCK::';
use constant APPLICANT_CHECK_LOCK_TTL    => 30;
use constant APPLICANT_ONFIDO_TIMING     => 'ONFIDO::APPLICANT::TIMING::';
use constant APPLICANT_ONFIDO_TIMING_TTL => 86400;

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

    try {
        my $loginid = $args->{loginid}
            or die 'No client login ID supplied?';
        my $file_id = $args->{file_id}
            or die 'No file ID supplied?';

        my $client = BOM::User::Client->new({loginid => $loginid})
            or die 'Could not instantiate client for login ID ' . $loginid;

        my $uploaded_manually_by_staff = $args->{uploaded_manually_by_staff} // 0;

        # We need information from the database to confirm file name and date
        my $document_entry = _get_document_details(
            loginid => $loginid,
            file_id => $file_id
        );

        unless ($document_entry) {
            $log->errorf('Could not get document %s from database for client %s', $file_id, $loginid);
            return;
        }

        die 'Expired document ' . $document_entry->{expiration_date}
            if $document_entry->{expiration_date} and Date::Utility->new($document_entry->{expiration_date})->is_before(Date::Utility->today);

        my $is_poa_document = any { $_ eq $document_entry->{document_type} } $client->documents->poa_types->@*;
        my $is_poi_document =
            any { $_ eq $document_entry->{document_type} } intersect($client->documents->poi_types->@*, $client->documents->preferred_types->@*);
        my $is_onfido_document =
            any { $_ eq $document_entry->{document_type} } keys $client->documents->provider_types->{onfido}->%*;

        my $is_pow_document = any { $_ eq $document_entry->{document_type} } $client->documents->pow_types->@*;
        $log->warnf("Unsupported document by onfido $document_entry->{document_type}") if $is_poi_document && !$is_onfido_document;

        $client->propagate_clear_status('allow_poi_resubmission') if $is_poi_document || $is_onfido_document;

        #clear allow_poinc_resubmission status when a new document of this type is uploaded
        $client->propagate_clear_status('allow_poinc_resubmission') if $is_pow_document;

        # If is a POI document but not Onfido supported, send an email to CS
        if ($is_poi_document && !$is_onfido_document && !$uploaded_manually_by_staff) {
            _notify_onfido_unsupported_document($client, $document_entry);
        }

        # If is a POI document and the client has document forged reason (on any status), send an email to CS
        if ($is_poi_document && $client->has_forged_documents && !$uploaded_manually_by_staff) {
            await _notify_onfido_on_forged_document($client);
        }

        my $document_args = {
            args              => $args,
            client            => $client,
            document_entry    => $document_entry,
            uploaded_by_staff => $uploaded_manually_by_staff,
        };

        return await _upload_poa_document($document_args) if $is_poa_document;
        return await _upload_poi_document($document_args) if $is_onfido_document;
        return await _upload_pow_document($document_args) if $is_pow_document;

    } catch ($e) {
        $log->errorf('Failed to process Onfido application for %s : %s', $args->{loginid}, $e);
        exception_logged();
        DataDog::DogStatsd::Helper::stats_inc("event.document_upload.failure",);
    }

    return;
}

=head2 _notify_onfido_on_forged_document

Send an email to CS about Onfido document uploaded when the client has forged document reason (of any status).

=over 4

=item * C<$client> - The client instance.

=back

Returns C<undef>.

=cut

async sub _notify_onfido_on_forged_document {
    my ($client) = @_;
    my $redis_events_write = _redis_events_write();
    await $redis_events_write->connect;

    # check the cooldown
    return undef if await $redis_events_write->get(FORGED_DOCUMENT_EMAIL_LOCK . $client->loginid);

    my $brand   = request()->brand;
    my $country = code2country($client->residence);
    my $msg =
        'Client uploaded new POI and account is locked due to forged SOP, please help to check and unlock if the document is legit, and to follow forged SOP if the document is forged again.';
    my $email_subject  = "New POI uploaded for acc with forged lock - $country";
    my $email_template = "\
        <p>$msg</p>
        <ul>
            <li><b>loginid:</b> " . $client->loginid . "</li>
            <li><b>residence:</b> " . $country . "</li>
        </ul>
        Team " . $brand->website_name . "\
        ";

    my $from_email = $brand->emails('no-reply');
    my $to_email   = $brand->emails('authentications');

    Email::Stuffer->from($from_email)->to($to_email)->subject($email_subject)->html_body($email_template)->send();

    await $redis_events_write->setex(FORGED_DOCUMENT_EMAIL_LOCK . $client->loginid, TTL_FORGED_DOCUMENT_EMAIL_LOCK, 1);

    return undef;
}

=head2 _notify_onfido_unsupported_document

Send an email to CS about unsupported onfido document uploaded by the client.

=over 4

=item * C<$client> - The client instance.

=item * C<$document_entry> - The document uploaded.

=back

Returns C<undef>.

=cut

sub _notify_onfido_unsupported_document {
    my ($client, $document_entry) = @_;
    my $brand = request()->brand;
    my $msg   = 'POI document type not supported by Onfido: ' . $document_entry->{document_type} . '. Please verify the age of the client manually.';
    my $email_subject  = "Manual age verification needed for " . $client->loginid;
    my $email_template = "\
        <p>$msg</p>
        <ul>
            <li><b>loginid:</b> " . $client->loginid . "</li>
            <li><b>place of birth:</b> " . (code2country($client->place_of_birth) // 'not set') . "</li>
            <li><b>residence:</b> " . code2country($client->residence) . "</li>
        </ul>
        Team " . $brand->website_name . "\
        ";

    my $from_email = $brand->emails('no-reply');
    my $to_email   = $brand->emails('authentications');

    Email::Stuffer->from($from_email)->to($to_email)->subject($email_subject)->html_body($email_template)->send();

    return undef;
}

=head2 _upload_poa_document

This subroutine handles uploading POA documents

=cut

async sub _upload_poa_document {
    my $args = shift;

    my ($client, $document_entry, $uploaded_by_staff) = @{$args}{qw/client document_entry uploaded_by_staff/};

    $client->propagate_clear_status('allow_poa_resubmission');

    BOM::Platform::Event::Emitter::emit(
        'document_uploaded',
        {
            loginid    => $client->loginid,
            properties => {
                uploaded_manually_by_staff => $uploaded_by_staff,
                %$document_entry
            }});

    await _send_email_notification_for_poa($client) unless $uploaded_by_staff;
}

=head2 _upload_poi_document

This subroutine handles uploading POI documents to onfido.

=cut

async sub _upload_poi_document {
    die 'Onfido is suspended' if BOM::Config::Runtime->instance->app_config->system->suspend->onfido;

    my $data = shift;

    my ($args, $client, $document_entry, $uploaded_by_staff) = @{$data}{qw/args client document_entry uploaded_by_staff/};

    my $country                     = $client->place_of_birth // $client->residence;
    my $is_onfido_supported_country = BOM::Config::Onfido::is_country_supported($country);

    return unless $is_onfido_supported_country;    # unsupported countries should not attempt to create onfido applicant

    $log->debugf('Applying Onfido verification process for client %s', $client->loginid);

    my $file_data = $args->{content};

    BOM::Platform::Event::Emitter::emit(
        'document_uploaded',
        {
            loginid    => $client->loginid,
            properties => {
                issuing_country            => $args->{issuing_country},
                uploaded_manually_by_staff => $uploaded_by_staff,
                %$document_entry
            }});

    await _upload_onfido_documents(
        onfido                     => _onfido(),
        client                     => $client,
        document_entry             => $document_entry,
        file_data                  => $file_data,
        uploaded_manually_by_staff => $uploaded_by_staff,
        issuing_country            => $args->{issuing_country},
    );
}

=head2 _upload_pow_document

This subroutine handles uploading POW(proof of wealth/income) documents

=cut

async sub _upload_pow_document {
    my $args = shift;

    my ($client, $document_entry, $uploaded_by_staff) = @{$args}{qw/client document_entry uploaded_by_staff/};

    BOM::Platform::Event::Emitter::emit(
        'document_uploaded',
        {
            loginid    => $client->loginid,
            properties => {
                uploaded_manually_by_staff => $uploaded_by_staff,
                %$document_entry
            }});

    await _send_complaince_email_pow_uploaded(client => $client) unless $uploaded_by_staff;
}

=head2 poa_updated

This event is triggered on POA document update, this can only over happen from the BO.
New uploads from RPC/BP should be handled at `document_upload`.

Side effects:

=over 4

=item  * populate the `users.poa_issuance` table

=back

Resolves to C<undef>.

=cut

async sub poa_updated {
    my ($args) = @_;

    my $loginid = $args->{loginid}
        or die 'No client login ID supplied?';

    my $client = BOM::User::Client->new({loginid => $loginid})
        or die 'Could not instantiate client for login ID ' . $loginid;

    if (my $best_poa_date = $client->documents->best_issue_date('proof_of_address')) {
        $client->user->dbic->run(
            fixup => sub {
                $_->do('SELECT * FROM users.upsert_poa_issuance(?::BIGINT, ?::DATE)', undef, $client->binary_user_id, $best_poa_date->date_yyyymmdd);
            });
    } else {
        $client->user->dbic->run(
            fixup => sub {
                $_->do('SELECT * FROM users.delete_poa_issuance(?::BIGINT)', undef, $client->binary_user_id);
            });
    }

    return undef;
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
    my $tags = [];
    my $client;
    my $res;

    try {
        my $loginid = $args->{loginid}
            or die 'No client login ID supplied?';
        my $applicant_id = $args->{applicant_id}
            or die 'No Onfido applicant ID supplied?';

        my ($broker) = $loginid =~ /^([A-Z]+)\d+$/
            or die 'could not extract broker code from login ID';

        my $loop = IO::Async::Loop->new;

        $log->debugf('Processing ready_for_authentication event for %s (applicant ID %s)', $loginid, $applicant_id);

        $client = BOM::User::Client->new({loginid => $loginid})
            or die 'Could not instantiate client for login ID ' . $loginid;

        my $redis_events_write = _redis_events_write();
        my $request_start      = [Time::HiRes::gettimeofday];
        await $redis_events_write->setex(APPLICANT_ONFIDO_TIMING . $client->binary_user_id,
            APPLICANT_ONFIDO_TIMING_TTL, encode_json_utf8($request_start));

        my $country     = $client->place_of_birth // $client->residence;
        my $country_tag = $country ? uc(country_code2code($country, 'alpha-2', 'alpha-3')) : '';
        $tags = ["country:$country_tag"];
        DataDog::DogStatsd::Helper::stats_inc('event.onfido.ready_for_authentication.dispatch', {tags => $tags});

        # We want to increment the resubmission counter when the resubmission flag is active.

        my $resubmission_flag = $client->status->allow_poi_resubmission;
        $resubmission_flag = 0 unless BOM::User::Onfido::get_latest_onfido_check($client->binary_user_id);
        $client->propagate_clear_status('allow_poi_resubmission');

        my ($request_count, $user_request_count);

        # INCR Onfido check request count in Redis
        await $redis_events_write->connect;

        ($request_count, $user_request_count) = await Future->needs_all(
            $redis_events_write->hget(ONFIDO_AUTHENTICATION_CHECK_MASTER_KEY, ONFIDO_REQUEST_COUNT_KEY),
            $redis_events_write->get(ONFIDO_REQUEST_PER_USER_PREFIX . $client->binary_user_id),
        );

        $request_count      //= 0;
        $user_request_count //= 0;

        my $limit_for_user = BOM::User::Onfido::limit_per_user($country);

        if (!$args->{is_pending} && $user_request_count > $limit_for_user) {
            DataDog::DogStatsd::Helper::stats_inc('event.onfido.ready_for_authentication.user_limit', {tags => $tags});
            $log->debugf('No check performed as client %s exceeded daily limit of %d requests.', $loginid, $limit_for_user);
            my $time_to_live = await $redis_events_write->ttl(ONFIDO_REQUEST_PER_USER_PREFIX . $client->binary_user_id);

            await $redis_events_write->expire(ONFIDO_REQUEST_PER_USER_PREFIX . $client->binary_user_id, ONFIDO_REQUEST_PER_USER_TIMEOUT)
                if ($time_to_live < 0);

            die "Onfido authentication requests limit $limit_for_user is hit by $loginid (to be expired in $time_to_live seconds).";
        }
        my $app_config = BOM::Config::Runtime->instance->app_config;
        $app_config->check_for_update;
        my $onfido_request_limit = $app_config->system->onfido->global_daily_limit;

        if ($request_count >= $onfido_request_limit) {
            my $today        = Date::Utility->new()->date_yyyymmdd;
            my $acquire_lock = await $redis_events_write->set(ONFIDO_DAILY_LIMIT_FLAG . $today, 1, 'EX', SECONDS_IN_DAY, 'NX');

            if ($acquire_lock) {
                DataDog::DogStatsd::Helper::stats_inc('event.onfido.ready_for_authentication.global_daily_limit_reached');
            }

            die 'We exceeded our Onfido authentication check request per day';
        }

        my $redis_replicated_write = _redis_replicated_write();
        await $redis_replicated_write->connect;
        await $redis_replicated_write->del(ONFIDO_IS_A_RESUBMISSION_KEY_PREFIX . $client->binary_user_id);

        if ($resubmission_flag) {
            DataDog::DogStatsd::Helper::stats_inc('event.onfido.ready_for_authentication.resubmission', {tags => $tags});

            # The following redis keys block email sending on client verification failure. We might clear them for resubmission
            my @delete_on_resubmission = (BOM::Event::Actions::Common::ONFIDO_AGE_BELOW_EIGHTEEN_EMAIL_PER_USER_PREFIX . $client->binary_user_id,);

            await $redis_events_write->connect;
            foreach my $email_blocker (@delete_on_resubmission) {
                await $redis_events_write->del($email_blocker);
            }

            # Deal with resubmission counter and context
            await $redis_replicated_write->incr(ONFIDO_RESUBMISSION_COUNTER_KEY_PREFIX . $client->binary_user_id);
            await $redis_replicated_write->set(ONFIDO_IS_A_RESUBMISSION_KEY_PREFIX . $client->binary_user_id, 1);
            await $redis_replicated_write->expire(ONFIDO_RESUBMISSION_COUNTER_KEY_PREFIX . $client->binary_user_id, ONFIDO_RESUBMISSION_COUNTER_TTL);
        } else {
            await $redis_replicated_write->del(ONFIDO_IS_A_RESUBMISSION_KEY_PREFIX . $client->binary_user_id);
        }

        await _save_request_context($applicant_id);
        $res = await Future->wait_any(
            $loop->timeout_future(after => VERIFICATION_TIMEOUT)
                ->on_fail(sub { $log->errorf('Time out waiting for Onfido verification.'); return undef }),

            _check_applicant({
                    client       => $client,
                    documents    => $args->{documents},
                    staff_name   => $args->{staff_name},
                    applicant_id => $applicant_id,
                }));

        if ($res) {
            DataDog::DogStatsd::Helper::stats_inc('event.onfido.ready_for_authentication.success', {tags => $tags});
        } else {
            DataDog::DogStatsd::Helper::stats_inc('event.onfido.ready_for_authentication.failure', {tags => $tags});
        }

        BOM::Platform::Event::Emitter::emit(
            'sync_mt5_accounts_status',
            {
                binary_user_id => $client->binary_user_id,
                client_loginid => $client->loginid
            });

    } catch ($e) {
        if (!$client) {
            DataDog::DogStatsd::Helper::stats_inc('event.onfido.ready_for_authentication.not_ready');
        } else {
            DataDog::DogStatsd::Helper::stats_inc('event.onfido.ready_for_authentication.failure', {tags => $tags});
            $log->errorf('Failed to process Onfido verification for %s: %s', $args->{loginid}, $e);
            exception_logged();
        }
    }

    unless ($res) {
        # release the pending lock under check failure scenario
        if ($client) {
            my $redis_events_write = _redis_events_write();
            await $redis_events_write->del(+BOM::User::Onfido::ONFIDO_REQUEST_PENDING_PREFIX . $client->binary_user_id);
        }
    }

    return;
}

=head2 client_verification

This events handles the Onfido webhook report response from
the Onfido service.

It will update onfido checks and reports on the database, will
also download all the related documents to the BO.

Finally, it will analyze the report to get the client age verified.
Some extra validation rules are applied such as: dob mismatch, name mismatch.

=cut

async sub client_verification {
    my ($args) = @_;
    my $brand = request->brand;
    my $client;
    my $redis_events_write;
    my $url = $args->{check_url};
    my $check;
    my $db_check;
    my $check_completed;

    $log->debugf('Client verification with %s', $args);
    DataDog::DogStatsd::Helper::stats_inc('event.onfido.client_verification.dispatch');

    try {
        $log->debugf('Had client verification result %s with check URL %s', $args->{status}, $args->{check_url});

        my ($check_id) = $url =~ m{/v3/checks/([^/]+)};

        ($check_id) = $url =~ m{/v3\.4/checks/([^/]+)} unless $check_id;

        # Onfido Sadness. It seems on live we are still getting the old format
        # with v2. We will make the code version agnostic until further notice.

        (undef, $check_id) = $url =~ m{/v2/applicants/([^/]+)/checks/([^/]+)} unless $check_id;

        die 'no check ID found' unless $check_id;

        $check = await _onfido()->check_get(
            check_id => $check_id,
        );

        my $applicant_id = $check->applicant_id;
        my $result       = $check->result;

        my @common_datadog_tags = (sprintf('check:%s', $result));

        await _restore_request($applicant_id, $check->tags);

        try {
            my $age_verified;

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

            $client = BOM::User::Client->new({loginid => $loginid})
                or die 'Could not instantiate client for login ID ' . $loginid;
            $args->{loginid} = $loginid;    # to get logged in case of timeout
            $log->debugf('Onfido check result for %s (applicant %s): %s (%s)', $loginid, $applicant_id, $result, $check_status);

            # check if the applicant already exist for this check. If not, store the applicant record in db
            # this is to cater the case where CS/Compliance perform manual check in Onfido dashboard
            await check_or_store_onfido_applicant($loginid, $applicant_id);

            $db_check = BOM::User::Onfido::get_onfido_check($client->binary_user_id, $applicant_id, $check_id);

            # little trickery: from our POV the check is still "in_progress" we must change this status at the end of the process
            # when all is set and done
            $check->{status} = 'in_progress';

            BOM::User::Onfido::store_onfido_check($applicant_id, $check) unless $db_check;

            my $country     = $client->place_of_birth // $client->residence;
            my $country_tag = $country ? uc(country_code2code($country, 'alpha-2', 'alpha-3')) : '';
            push @common_datadog_tags, sprintf("country:$country_tag");

            BOM::Platform::Redis::release_lock(APPLICANT_CHECK_LOCK_PREFIX . $client->binary_user_id);

            my @all_report = await $check->reports->as_list;

            for my $each_report (@all_report) {
                # safe to call on repeated reports (conflict do nothing)
                BOM::User::Onfido::store_onfido_report($check, $each_report);
            }

            await _store_applicant_documents($applicant_id, $client, \@all_report);

            my $pending_key = ONFIDO_PENDING_REQUEST_PREFIX . $client->binary_user_id;

            $redis_events_write = _redis_events_write();

            await $redis_events_write->connect;

            my $args = await $redis_events_write->get($pending_key);

            if (($check_status ne 'pass') and $args) {
                DataDog::DogStatsd::Helper::stats_inc('event.onfido.client_verification.resend', {tags => [@common_datadog_tags]});

                $log->debugf('Onfido check failed. Resending the last pending request: %s', $args);
                BOM::Platform::Event::Emitter::emit(ready_for_authentication => decode_json_utf8($args));
            }

            await $redis_events_write->del($pending_key);
            await _clear_cached_context($applicant_id);

            $log->debugf('Onfido pending key cleared');

            # Send email to CS if client has forged document status reason
            if ($client->has_forged_documents) {
                await _notify_onfido_on_forged_document($client);
            }

            # Consume resubmission context
            my $redis_replicated_write = _redis_replicated_write();

            await $redis_replicated_write->connect;

            await $redis_replicated_write->del(ONFIDO_IS_A_RESUBMISSION_KEY_PREFIX . $client->binary_user_id);

            # TODO: remove this check when we have fully integrated Onfido
            try {
                my @reports;
                if ($client->landing_company->requires_face_similarity_check) {
                    #for MF accounts we take into consideration the document and the face similarity check report
                    @reports = await $check->reports->as_list;
                } else {
                    #for CR and ROW we filter out and use only the report for the documents
                    @reports = await $check->reports->filter(name => 'document')->as_list;
                }

                # map the reports for documents and selfies
                my $reports = +{map { ($_->{name} => $_) } @reports};

                my $document_report = $reports->{document};
                push @common_datadog_tags, sprintf("report:%s", $document_report->result);

                # Process the minimum_accepted_age result from Onfido
                # we will consider the client as underage only if this result is defined and not equal to `clear`.
                my $minimum_accepted_age = $document_report->{breakdown}->{age_validation}->{breakdown}->{minimum_accepted_age}->{result};
                my $underage_detected    = defined $minimum_accepted_age && $minimum_accepted_age ne 'clear';

                if ($underage_detected) {
                    DataDog::DogStatsd::Helper::stats_inc('event.onfido.client_verification.underage_detected', {tags => [@common_datadog_tags]});

                    BOM::Event::Actions::Common::handle_under_age_client($client, 'Onfido');
                }

                # Extract all clear documents to check consistency between DOBs
                elsif (my @valid_doc = grep { (defined $_->{properties}->{date_of_birth} and $_->result eq 'clear') } @reports) {
                    my %dob = map { ($_->{properties}{date_of_birth} // '') => 1 } @valid_doc;
                    my ($first_dob) = keys %dob;

                    # Age verified if report is clear and age is above minimum allowed age, otherwise send an email to notify cs
                    # Get the minimum age from the client's residence
                    my $min_age = $brand->countries_instance->minimum_age_for_country($client->residence);

                    if (Date::Utility->new($first_dob)->is_before(Date::Utility->new->_minus_years($min_age))) {
                        # we check facial similarity result exists by peeking both keys from the reports for a match
                        my $selfie_report = $reports->{facial_similarity_photo} // $reports->{facial_similarity};
                        my $selfie_result = $selfie_report ? $selfie_report->result : '';

                        # we first check if facial similarity is clear for LCs with the required flag active, currently just for MF
                        if ($selfie_result eq 'clear' || !$client->landing_company->requires_face_similarity_check) {
                            await check_onfido_rules({
                                loginid      => $client->loginid,
                                check_id     => $check_id,
                                datadog_tags => \@common_datadog_tags,
                            });

                            if ($age_verified =
                                await BOM::Event::Actions::Common::set_age_verification($client, 'Onfido', $redis_events_write, 'onfido'))
                            {
                                push @common_datadog_tags, "result:age_verified";
                                DataDog::DogStatsd::Helper::stats_inc('event.onfido.client_verification.result', {tags => [@common_datadog_tags]});
                            }
                        } else {
                            push @common_datadog_tags, "result:selfie_rejected";
                            DataDog::DogStatsd::Helper::stats_inc('event.onfido.client_verification.result', {tags => [@common_datadog_tags]});
                        }
                    } else {
                        push @common_datadog_tags, "result:underage_detected";
                        DataDog::DogStatsd::Helper::stats_inc('event.onfido.client_verification.result', {tags => [@common_datadog_tags]});
                        BOM::Event::Actions::Common::handle_under_age_client($client, 'Onfido');
                    }
                } else {
                    push @common_datadog_tags, "result:dob_not_reported";
                    DataDog::DogStatsd::Helper::stats_inc('event.onfido.client_verification.result', {tags => [@common_datadog_tags]});
                }

                # Update expiration_date and document_id of each document in DB
                # Using corresponding values in Onfido response

                @reports = grep { ($_->{properties}->{document_type} // '') ne 'live_photo' } @reports;

                foreach my $report (@reports) {

                    # It seems that expiration date and document number of all documents in $report->{documents} list are similar
                    my ($expiration_date, $doc_numbers) = @{$report->{properties}}{qw(date_of_expiry document_numbers)};
                    my $documents = $report->documents // [];

                    foreach my $onfido_doc ($documents->@*) {
                        my $onfido_doc_id = $onfido_doc->{id};

                        await $redis_events_write->connect;
                        my $db_doc_id = await $redis_events_write->get(ONFIDO_DOCUMENT_ID_PREFIX . $onfido_doc_id);

                        if ($db_doc_id) {
                            await $redis_events_write->del(ONFIDO_DOCUMENT_ID_PREFIX . $onfido_doc_id);

                            # There is a possibility that corresponding DB document of onfido document has been deleted (e.g. by BO user)
                            my ($db_doc) = $client->find_client_authentication_document(query => [id => $db_doc_id]);

                            if ($db_doc) {
                                if ($report->result eq 'clear' && $age_verified) {
                                    $db_doc->expiration_date($expiration_date);
                                    $db_doc->document_id($doc_numbers->[0]->{value});
                                    $db_doc->status('verified');
                                } else {
                                    $db_doc->status('rejected');
                                }

                                if ($db_doc->save) {
                                    $log->debugf('%s document %s for client %s have been updated with Onfido info',
                                        $db_doc->status, $db_doc->id, $loginid);
                                }
                            }
                        }
                    }
                }

                if (!$age_verified) {
                    DataDog::DogStatsd::Helper::stats_inc('event.onfido.client_verification.not_verified', {tags => [@common_datadog_tags]});
                }

                # at this point the check has been completed
                $check_completed = 1;
                DataDog::DogStatsd::Helper::stats_inc('event.onfido.client_verification.success');
            } catch ($e) {
                DataDog::DogStatsd::Helper::stats_inc('event.onfido.client_verification.failure');
                $log->errorf('An error occurred while retrieving reports for client %s check %s: %s', $loginid, $check->id, $e);
                die $e;
            }

            await $redis_events_write->connect;

            my $request_start = await $redis_events_write->get(APPLICANT_ONFIDO_TIMING . $client->binary_user_id);

            if ($request_start) {
                DataDog::DogStatsd::Helper::stats_timing(
                    'event.onfido.callout.timing',
                    (1000 * Time::HiRes::tv_interval(decode_json_utf8($request_start))),
                    {tags => [@common_datadog_tags,]});

                await $redis_events_write->del(APPLICANT_ONFIDO_TIMING . $client->binary_user_id);

            }

            BOM::Platform::Event::Emitter::emit(
                'sync_mt5_accounts_status',
                {
                    binary_user_id => $client->binary_user_id,
                    client_loginid => $client->loginid
                });

        } catch ($e) {
            DataDog::DogStatsd::Helper::stats_inc('event.onfido.client_verification.failure');
            $log->errorf('Failed to do verification callback - %s', $e);
            die $e;
        }
    } catch ($e) {
        DataDog::DogStatsd::Helper::stats_inc('event.onfido.client_verification.failure');
        $log->errorf('Exception while handling client verification (%s) result: %s', $url // 'no url', $e);
        exception_logged();
    }

    # transition the check to complete
    if ($check && $check_completed) {
        $check->{status} = 'complete';
        BOM::User::Onfido::update_onfido_check($check);
    }

    # release the applicant check lock
    # release the get_account_status pending lock
    if ($client) {
        $redis_events_write //= _redis_events_write();
        await $redis_events_write->del(+BOM::User::Onfido::ONFIDO_REQUEST_PENDING_PREFIX . $client->binary_user_id);
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
    my $facial_similarity_report;

    # Build hash index for onfido document id to report.
    my %report_for_doc_id;
    my $reported_documents = 0;

    for my $report (@{$check_reports}) {
        if ($report->name eq 'facial_similarity_photo') {
            $facial_similarity_report = $report;

            # we can assume there is a selfie, note that `documents` is not particularly useful on this kind of report
            $reported_documents++;
        } elsif ($report->name eq 'document') {
            my @report_documents = @{$report->documents};
            $reported_documents += scalar @report_documents;
            push @documents, map { $_->{id} } @report_documents;
            $report_for_doc_id{$_->{id}} = $report for @report_documents;
        }
    }

    DataDog::DogStatsd::Helper::stats_histogram('event.onfido.client_verification.reported_documents', $reported_documents);

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

        my $issuing_country = $doc->issuing_country // $client->place_of_birth // $client->residence;
        BOM::User::Onfido::store_onfido_document($doc, $applicant_id, $issuing_country, $type, $side);

        my ($expiration_date, $document_numbers) = @{$report_for_doc_id{$doc->id}{properties}}{qw(date_of_expiry document_numbers)};
        my $doc_number = $document_numbers ? $document_numbers->[0]->{value} : undef;

        await onfido_doc_ready_for_upload({
                final_status   => _get_document_final_status($report_for_doc_id{$doc->id}{result}),
                type           => 'document',
                document_id    => $doc->id,
                client_loginid => $client->loginid,
                applicant_id   => $applicant_id,
                file_type      => $doc->file_type,
                document_info  => {
                    issuing_country => $doc->issuing_country ? lc(country_code2code($doc->issuing_country, 'alpha-3', 'alpha-2')) : $issuing_country,
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

    await onfido_doc_ready_for_upload({
        $facial_similarity_report ? (final_status => _get_document_final_status($facial_similarity_report->result)) : (),
        type           => 'photo',
        document_id    => $photo->id,
        client_loginid => $client->loginid,
        applicant_id   => $applicant_id,
        file_type      => $photo->file_type,
    });

    return undef;
}

=head2 check_onfido_rules

Applies the `check_results` L<BOM::Rules::Engine> action upon the latest Onfido check.

Takes the following named parameters:

=over 4

=item * C<loginid> - the login id of the client.

=item * C<check_id> - the id of the onfido check (optional, if not given will try to get the last one from db).

=item * C<datadog_tags> - (optional) tags to send send along the DD metrics.

=back

The following side effects could happen on rules engine verification error:

=over 4

=item * C<NameMismatch>: the client will be flagged with the C<poi_name_mismatch> status.

=item * C<DobMismatch>: the client will be flagged with the C<poi_dob_mismatch> status.

=back

Returns a L<Future> which resolves to C<1> on success.

=cut

async sub check_onfido_rules {
    my ($args)  = @_;
    my $loginid = $args->{loginid}                              or die 'No loginid supplied';
    my $client  = BOM::User::Client->new({loginid => $loginid}) or die "Client not found: $loginid";
    die "Virtual account should not meddle with Onfido" if $client->is_virtual;

    my $tags     = $args->{datadog_tags};
    my $check_id = $args->{check_id};
    my $check    = BOM::User::Onfido::get_latest_check($client)->{user_check} // {};
    $check_id = $check->{id};

    my $redis_events_write = _redis_events_write();
    await $redis_events_write->connect;

    if ($check_id) {
        my ($report) =
            grep { $_->{api_name} eq 'document' } values BOM::User::Onfido::get_all_onfido_reports($client->binary_user_id, $check_id)->%*;

        if ($report) {
            my $rule_engine = BOM::Rules::Engine->new(
                client          => $client,
                stop_on_failure => 0
            );
            my $report_result = $report->{result} // '';
            my $check_result  = $check->{result}  // '';

            # get the current rejected reasons and drop the name mismatches if any.
            my @bad_reasons = qw(data_comparison.first_name data_comparison.last_name data_comparison.date_of_birth);
            my @reasons     = array_minus(BOM::User::Onfido::get_consider_reasons($client)->@*, @bad_reasons);

            my $rules_result = $rule_engine->verify_action(
                'check_results',
                loginid => $client->loginid,
                report  => $report,
            );
            unless ($rules_result->has_failure) {
                my $poi_name_mismatch = $client->status->poi_name_mismatch;

                $client->propagate_clear_status('poi_name_mismatch');
                $client->status->clear_poi_name_mismatch;

                my $poi_dob_mismatch = $client->status->poi_dob_mismatch;

                $client->propagate_clear_status('poi_dob_mismatch');
                $client->status->clear_poi_dob_mismatch;

                # If the user had this status but now is clear then age verification is due,
                # we should alse ensure the aren't other rejection reasons.
                my $age_verification_due = $poi_name_mismatch || $poi_dob_mismatch;

                if ($age_verification_due && $report_result eq 'clear' && $check_result eq 'clear' && scalar @reasons == 0) {

                    $client->db->dbic->run(
                        fixup => sub {
                            $_->do('SELECT * FROM betonmarkets.set_onfido_doc_status_to_verified(?)', undef, $client->binary_user_id);
                        });

                    if (await BOM::Event::Actions::Common::set_age_verification($client, 'Onfido', $redis_events_write, 'onfido')) {
                        if ($tags) {
                            DataDog::DogStatsd::Helper::stats_inc(
                                'event.onfido.client_verification.result',
                                {
                                    tags => $tags,
                                });
                        }
                    }
                }
            } else {
                my $errors = $rules_result->errors;
                my $tags   = $args->{datadog_tags};

                if (exists $errors->{NameMismatch}) {
                    if ($tags) {
                        push @$tags, 'result:name_mismatch';
                        DataDog::DogStatsd::Helper::stats_inc(
                            'event.onfido.client_verification.result',
                            {
                                tags => $tags,
                            });
                    }

                    $client->propagate_status('poi_name_mismatch', 'system', "Name in client details and Onfido report don't match");
                } else {
                    $client->propagate_clear_status('poi_name_mismatch');
                }

                if (exists $errors->{DobMismatch}) {
                    if ($tags) {
                        push @$tags, 'result:dob_mismatch';
                        DataDog::DogStatsd::Helper::stats_inc(
                            'event.onfido.client_verification.result',
                            {
                                tags => $tags,
                            });
                    }

                    $client->propagate_status('poi_dob_mismatch', 'system', "DOB in client details and Onfido report don't match");
                } else {
                    $client->propagate_clear_status('poi_dob_mismatch');
                }
            }
        }
    }

    return 1;
}

=head2 _get_document_final_status

Determines which status should we set the document uploaded

We have `uploaded` and `verified`.

For a `clear` result from Onfido Report we can set `verified` otherwise we pick `uploaded` (also known as needs review).

It takes the following arguments:

=over 4

=item * C<result> The Onfido report result.

=back


Returns a string for this final status.

=cut

sub _get_document_final_status {
    my $result = shift // '';
    my $status = {
        clear    => 'verified',
        consider => 'rejected',
        suspect  => 'rejected'
    };

    return $status->{$result} // 'uploaded';
}

=head2 onfido_doc_ready_for_upload

Gets the client's documents from Onfido and upload to S3

=cut

async sub onfido_doc_ready_for_upload {
    my $data = shift;
    my ($type, $doc_id, $client_loginid, $applicant_id, $file_type, $document_info, $final_status) =
        @{$data}{qw/type document_id client_loginid applicant_id file_type document_info final_status/};

    my $client          = BOM::User::Client->new({loginid => $client_loginid});
    my $s3_client       = BOM::Platform::S3Client->new(BOM::Config::s3()->{document_auth});
    my $onfido          = _onfido();
    my $issuing_country = $document_info->{issuing_country};
    my $doc_type        = $document_info->{type};
    my $page_type       = $document_info->{side} // '';
    $final_status //= 'uploaded';

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
    die "Invalid expiration date"
        if ($expiration_date
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

    # send dog metric if there's an existent document
    return DataDog::DogStatsd::Helper::stats_inc('onfido.document.cannot_acquire_lock') unless $acquire_lock;

    try {
        my $lifetime_valid = $expiration_date ? 0 : 1;
        my @maybe_lifetime = $client->documents->maybe_lifetime_types->@*;

        # lifetime only applies to favored POI types
        $lifetime_valid = 0 if none { $_ eq $doc_type } @maybe_lifetime;

        # a bit of sadness
        # at QAbox the ON CONFLICT DO UPDATE returns undef,
        # whereas at circle ci is returning a hashref with the next.id of the sequence (previous id totally stomped).
        # so we are forced to ensure the document is there to make the tests green everywhere.
        my $is_doc_really_there = $client->db->dbic->run(
            ping => sub {
                $_->selectrow_hashref(
                    'SELECT id FROM betonmarkets.client_authentication_document WHERE checksum = ? AND document_type = ? AND client_loginid = ? ',
                    {Slice => {}},
                    $file_checksum, $doc_type, $client_loginid,
                );
            });

        if ($is_doc_really_there) {
            DataDog::DogStatsd::Helper::stats_inc('onfido.document.skip_repeated');
        } else {
            $upload_info = $client->db->dbic->run(
                ping => sub {
                    $_->selectrow_hashref(
                        'SELECT * FROM betonmarkets.start_document_upload(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?::betonmarkets.client_document_origin, ?)',
                        undef,
                        $client_loginid, $doc_type, $file_type,      $expiration_date || undef, $document_info->{number} || '', $file_checksum, '',
                        $page_type,      undef,     $lifetime_valid, 'onfido', $issuing_country
                    );
                });
        }

        if ($upload_info) {
            ($file_id, $new_file_name) = @{$upload_info}{qw/file_id file_name/};

            # This redis key allow further date/numbers update
            await $redis_events_write->setex(ONFIDO_DOCUMENT_ID_PREFIX . $doc_id, ONFIDO_PENDING_REQUEST_TIMEOUT, $file_id);

            $log->debugf("Starting to upload file_id: $file_id to S3 ");
            $s3_uploaded = await $s3_client->upload($new_file_name, $tmp_filename, $file_checksum);
        }

        if ($s3_uploaded) {
            $log->debugf("Successfully uploaded file_id: $file_id to S3 ");
            my $finish_upload_result = $client->db->dbic->run(
                ping => sub {
                    $_->selectrow_array('SELECT * FROM betonmarkets.finish_document_upload(?, ?::status_type)', undef, $file_id, $final_status);
                });

            die "Db returned unexpected file_id on finish. Expected $file_id but got $finish_upload_result. Please check the record"
                unless $finish_upload_result == $file_id;

            my $document_info = {

                # to avoid a db hit, we can estimate the `upload_date` to the current timestamp.
                # all the other fields can be derived from current symbols table.
                upload_date     => Date::Utility->new->datetime_yyyymmdd_hhmmss,
                file_name       => $new_file_name,
                id              => $file_id,
                lifetime_valid  => $lifetime_valid,
                document_id     => $document_info->{number} || '',
                comments        => '',
                expiration_date => $expiration_date || undef,
                document_type   => $doc_type
            };

            if ($document_info) {
                BOM::Platform::Event::Emitter::emit(
                    'document_uploaded',
                    {
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

    my $loginid = $data->{loginid}                              or die 'No loginid supplied';
    my $client  = BOM::User::Client->new({loginid => $loginid}) or die "Client not found: $loginid";
    die "Virtual account should not meddle with Onfido" if $client->is_virtual;

    my $client_details_onfido;

    try {
        my $applicant_data = BOM::User::Onfido::get_user_onfido_applicant($client->binary_user_id);
        my $applicant_id   = $applicant_data->{id};

        # Only for users that are registered in onfido
        return unless $applicant_id;

        # Instantiate client and onfido object
        $client_details_onfido = BOM::User::Onfido::applicant_info($client);

        $client_details_onfido->{applicant_id} = $applicant_id;

        my $response = await _onfido()->applicant_update(%$client_details_onfido);

        return $response;

    } catch ($e) {
        local $log->context->{applicant_info} = $client_details_onfido->{address} if $client_details_onfido && $client_details_onfido->{address};
        $log->errorf('Failed to update details in Onfido for %s : %s', $data->{loginid}, $e);
        exception_logged();
    }

    return;
}

=head2 verify_address

This event is triggered once client or someone from backoffice
have updated client address.

It first clear existing smarty_streets_validated status and then
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
        } catch ($e) {
            if ($e =~ /too many attempts/) {
                DataDog::DogStatsd::Helper::stats_inc('event.address_verification.too_many_attempts', {tags => \@dd_tags});
            } else {
                DataDog::DogStatsd::Helper::stats_inc('event.address_verification.exception', {tags => \@dd_tags});
            }

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

        # We'll pick the proper license per client residence
        license => _smarty_license($client),
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

    my $redis_events_write = _redis_events_write();
    await $redis_events_write->connect;

    my $counter_to_lock = await $redis_events_write->incr('ADDRESS_CHANGE_LOCK' . $client->binary_user_id);
    await $redis_events_write->expire('ADDRESS_CHANGE_LOCK' . $client->binary_user_id, 84600);

    die 'too many attempts' if $counter_to_lock > 3;

    DataDog::DogStatsd::Helper::stats_inc('smartystreet.verification.trigger');

    # Next step is an address check. Let's make sure that whatever they
    # are sending is valid at least to locality level.
    my $future_verify_ss = _smartystreets()->verify(%details);

    $future_verify_ss->on_fail(
        sub {
            my (undef, undef, $e) = @_;

            # extract payload error message and try to map it into a metric
            if (blessed($e) and $e->isa('HTTP::Response')) {
                my $match;
                DataDog::DogStatsd::Helper::stats_inc('smartystreet.lookup.unacceptable_address')
                    if $e->content =~ /Unable to process the input provided/ && ($match = 1);
                DataDog::DogStatsd::Helper::stats_inc('smartystreet.lookup.subscription_required')
                    if $e->content =~ /Active subscription required/ && ($match = 1);

                # log the unhandled message for debugging
                $log->warnf(sprintf("SmartyStreets HTTP status %d error: %s", $e->code, $e->content)) unless $match;
            }

            DataDog::DogStatsd::Helper::stats_inc('smartystreet.lookup.failure');

            # clear current status on failure, if any
            $client->status->clear_smarty_streets_validated();
            return;
        }
    )->on_done(
        sub {
            DataDog::DogStatsd::Helper::stats_inc('smartystreet.lookup.success');
        });

    my $addr = await $future_verify_ss;

    my $status = $addr->status;
    $log->debugf('Smartystreets verification status: %s',      $status);
    $log->debugf('Address info back from SmartyStreets is %s', {%$addr});

    if (not $addr->accuracy_at_least('locality')) {
        DataDog::DogStatsd::Helper::stats_inc('smartystreet.verification.failure', {tags => ['verify_address:' . $status]});
        $log->debugf('Inaccurate address - only verified to %s precision', $addr->address_precision);
    } else {
        DataDog::DogStatsd::Helper::stats_inc('smartystreet.verification.success', {tags => ['verify_address:' . $status]});
        $log->debugf('Address verified with accuracy of locality level by smartystreet.');

        _set_smarty_streets_validated($client);
    }

    await $redis_events_write->hset('ADDRESS_VERIFICATION_RESULT' . $client->binary_user_id,
        encode_utf8(join(' ', ($freeform, ($client->residence // '')))), $status);
    await $redis_events_write->expire('ADDRESS_VERIFICATION_RESULT' . $client->binary_user_id, 86400);    #TTL for Hash is set for 1 day.
    DataDog::DogStatsd::Helper::stats_inc('event.address_verification.recorded.redis');

    return;
}

=head2 _smarty_license

Determines the license for the given client.

This computation depends on the residence of the client.

It takes the following params:

=over 4

=item * C<$client> - the L<BOM::User::Client> instance.

=back

Returns the proper license as string.

=cut

sub _smarty_license {
    my ($client)  = @_;
    my $residence = lc($client->residence // '');
    my $config    = BOM::Config::third_party()->{smartystreets};
    my ($licenses, $countries) = @{$config}{qw/licenses countries/};

    for my $license (keys $countries->%*) {
        return $licenses->{$license} if any { $_ eq $residence } $countries->{$license}->@*;
    }

    return $licenses->{basic};
}

async sub _get_onfido_applicant {
    my (%args) = @_;

    my $client                     = $args{client};
    my $onfido                     = $args{onfido};
    my $uploaded_manually_by_staff = $args{uploaded_manually_by_staff};
    my $country                    = $args{country} // $client->place_of_birth // $client->residence;

    try {
        my $is_supported_country = BOM::Config::Onfido::is_country_supported($country);

        unless ($is_supported_country) {
            DataDog::DogStatsd::Helper::stats_inc('onfido.unsupported_country', {tags => [$country]});

            await _send_email_onfido_unsupported_country_cs($client, $country) unless $uploaded_manually_by_staff;
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
        my $applicant = await $onfido->applicant_create(%{BOM::User::Onfido::applicant_info($client)});
        my $elapsed   = Time::HiRes::time() - $start;

        # saving data into onfido_applicant table
        BOM::User::Onfido::store_onfido_applicant($applicant, $client->binary_user_id) if $applicant;

        $applicant
            ? DataDog::DogStatsd::Helper::stats_timing("event.document_upload.onfido.applicant_create.done.elapsed",   $elapsed)
            : DataDog::DogStatsd::Helper::stats_timing("event.document_upload.onfido.applicant_create.failed.elapsed", $elapsed);

        return $applicant;
    } catch ($e) {
        if (blessed($e) and $e->isa('Future::Exception')) {
            my ($payload) = $e->details;

            if (blessed($payload) && $payload->can('content')) {
                $log->warnf('Onfido http exception: %s', $payload->content);
            }
        }

        exception_logged();
        die $e;
    }

    return undef;
}

sub _get_document_details {
    my (%args) = @_;

    my $loginid = $args{loginid};
    my $file_id = $args{file_id};
    my $doc     = {};

    try {
        my $client = BOM::User::Client->new({loginid => $loginid});
        $doc = $client->db->dbic->run(
            ping => sub {
                $_->selectrow_hashref('SELECT * FROM betonmarkets.get_authentication_document_details(?, ?)', undef, $file_id, $loginid);
            });
    } catch {
        exception_logged();
        die "An error occurred while getting document details ($file_id) from database for login ID $loginid.";
    }

    # The code is expecting a falsey
    unless ($doc->{id}) {
        return undef;
    }

    return $doc;
}

=head2 _set_smarty_streets_validated

This method sets the specified client as B<smarty_streets_validated> by SmartyStreets.

It takes the following arguments:

=over 4

=item * C<client> an instance of L<BOM::User::Client>

=back

Returns undef.

=cut

sub _set_smarty_streets_validated {
    my $client      = shift;
    my $status_code = 'smarty_streets_validated';
    my $reason      = 'SmartyStreets verified';
    my $staff       = 'system';

    $log->debugf('Updating status on %s to %s (%s)', $client->loginid, $status_code, $reason);

    $client->status->setnx($status_code, $staff, $reason);

    return undef;
}

=head2 track_account_closure

This is handler for each B<account_closure> event emitted, when handled by the track worker.

=cut

sub track_account_closure {
    my $data = shift;

    return BOM::Event::Services::Track::account_closure($data);
}

=head2 account_reactivated

It's the handler for the event emitted on account reactivation, sending emails to the client and social responsibility team.

=cut

sub account_reactivated {
    my $data = shift;

    my $client = BOM::User::Client->new({loginid => $data->{loginid}});
    my $brand  = request->brand;

    BOM::Platform::Email::send_email({
            to            => $brand->emails('social_responsibility'),
            from          => $brand->emails('no-reply'),
            subject       => $client->loginid . ' has been reactivated',
            template_name => 'account_reactivated_sr',
            template_args => {
                loginid => $client->loginid,
                email   => $client->email,
                reason  => $data->{closure_reason},
            },
            use_email_template    => 1,
            email_content_is_html => 1,
            use_event             => 0
        }) if $client->landing_company->social_responsibility_check && $client->landing_company->social_responsibility_check eq 'required';
    return 1;
}

=head2 track_account_reactivated

This is handler for each B<account_reactivated> event emitted, when handled by the track worker.

=cut

sub track_account_reactivated {
    my ($args) = @_;

    my $client = BOM::User::Client->new({loginid => $args->{loginid}});
    my $brand  = request->brand;

    return BOM::Event::Services::Track::account_reactivated({
        loginid          => $client->loginid,
        needs_poi        => $client->needs_poi_verification(),
        profile_url      => $brand->profile_url({language => uc(request->language // 'en')}),
        resp_trading_url => $brand->responsible_trading_url({language => uc(request->language // 'en')}),
        live_chat_url    => $brand->live_chat_url({language => uc(request->language // 'en')}),
        first_name       => $client->first_name,
        new_campaign     => 1,
    });
}

=head2 authenticated_with_scans

Emails client when they have been successfully verified by Back Office
Raunak 19/06/2019 Please note that we decided to do it as frontend notification but since that is not yet drafted and designed so we will implement email notification

=over 4

=item * C<<{loginid=>'clients loginid'}>>  hashref with a loginid key of the user who has had their account verified.

=back

Returns undef

=cut

sub authenticated_with_scans {
    my ($args)          = @_;
    my $client          = BOM::User::Client->new($args);
    my ($latest_poi_by) = $client->latest_poi_by({only_verified => 1});

    return BOM::Event::Services::Track::authenticated_with_scans({
        %$args,
        live_chat_url => request->brand->live_chat_url,
        contact_url   => request->brand->contact_url,
        loginid       => $client->loginid,
        email         => $client->email,
        first_name    => $client->first_name,
        latest_poi_by => $latest_poi_by,
    });
}

async sub _send_CS_email_POA_uploaded {
    my ($client) = @_;
    my $brand = request->brand;

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
- send only if client is MF client

need to extend later for all landing companies

=cut

async sub _send_email_notification_for_poa {
    my $client = shift;

    return undef if $client->fully_authenticated();

    if ($client->landing_company->short eq 'maltainvest') {
        await _send_CS_email_POA_uploaded($client);
    }

    return undef;
}

=head2 _send_email_onfido_unsupported_country_cs

Send email to CS when Onfido does not support the client's country.

=cut

async sub _send_email_onfido_unsupported_country_cs {
    my ($client, $country) = @_;
    my $brand = request->brand;

    $country //= '';

    # Prevent sending multiple emails for the same user
    my $redis_key         = ONFIDO_UNSUPPORTED_COUNTRY_EMAIL_PER_USER_PREFIX . $client->binary_user_id;
    my $redis_events_read = _redis_events_read();
    await $redis_events_read->connect;
    return undef if await $redis_events_read->exists($redis_key);

    my $msg = "";

    if ($client->place_of_birth) {
        if (!$country || $client->place_of_birth eq $country) {
            $msg = 'Place of birth is not supported by Onfido. Please verify the age of the client manually.';
        } else {
            $msg = 'The specified country by user `' . $country . '` is not supported by Onfido. Please verify the age of the client manually.';
        }
    } else {
        $msg =
            'No country specified by user, place of birth is not set and residence is not supported by Onfido. Please verify the age of the client manually.';
    }

    my $email_subject  = "Manual age verification needed for " . $client->loginid;
    my $email_template = "\
        <p>$msg</p>
        <ul>
            <li><b>loginid:</b> " . $client->loginid . "</li>
            <li><b>specified country:</b> " . (code2country($country) // 'not set') . "</li>
            <li><b>place of birth:</b> " . (code2country($client->place_of_birth) // 'not set') . "</li>
            <li><b>residence:</b> " . code2country($client->residence) . "</li>
        </ul>
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

=head2 _send_complaince_email_pow_uploaded

Send email to complaince when client uploads a document

=cut

async sub _send_complaince_email_pow_uploaded {
    my (%args) = @_;
    my $client = $args{client};
    my $brand  = request->brand;

    my $from_email = $brand->emails('no-reply');
    my $to_email   = $brand->emails('compliance_ops');

    Email::Stuffer->from($from_email)->to($to_email)->subject('New uploaded EDD document for: ' . $client->loginid)
        ->text_body('New proof of income document was uploaded for ' . $client->loginid)->send();

    return undef;
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

NOTE: This is for MX-MLT-CR clients only (Last updated: Dec 22, 2021)

=cut

sub social_responsibility_check {
    my $data  = shift;
    my $brand = request->brand;

    my $loginid = $data->{loginid} or die "Missing loginid";

    my $attribute = $data->{attribute} or die "No attribute to check";

    my $client = BOM::User::Client->new({loginid => $loginid}) or die "Invalid loginid: $loginid";

    my $redis = BOM::Config::Redis::redis_events();

    my $lock_key     = join q{-} => ('SOCIAL_RESPONSIBILITY_CHECK', $loginid,);
    my $acquire_lock = BOM::Platform::Redis::acquire_lock($lock_key, SR_CHECK_TIMEOUT);
    return unless $acquire_lock;

    my $event_name = $loginid . ':sr_check:';

    my $client_sr_values = {};

    $client_sr_values->{$attribute} = $redis->get($event_name . $attribute) // 0;

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
        my $email_subject = "Social Responsibility Check required ($attribute) - " . $loginid;

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
        my $sr_status_key = $loginid . ':sr_risk_status';
        $redis->set(
            $sr_status_key => 'high',
            EX             => SR_30_DAYS_EXP
        );
        my $today = Date::Utility->today();
        $log->infof(
            "Social Responsibility Status for $loginid is set to high, $attribute has a value $client_attribute_val which %s threshold : $threshold_val.",
            $client_attribute_val == $threshold_val ? "is equal to" : "exceeds"
        );
        $log->infof("Social Responsibility high risk status for $loginid starts in %s and expires in %s",
            $today->date_yyyymmdd, $today->plus_time_interval(SR_30_DAYS_EXP)->date_yyyymmdd);
        try {
            $tt->process(BOM::Event::Actions::Common::TEMPLATE_PREFIX_PATH . 'social_responsibiliy.html.tt', $data, \my $html);
            die "Template error: @{[$tt->error]}" if $tt->error;

            die "failed to send social responsibility email ($loginid)"
                unless Email::Stuffer->from($system_email)->to($sr_email)->subject($email_subject)->html_body($html)->send();

            # Here we set a key for which breached thresholds we have
            # sent an email. There is no point for the key to have a ttl
            # longer than the client's monitoring period of 30 days so
            # we copy the remaining ttl of "$loginid:sr_risk_status"
            $redis->set(
                $event_name . $attribute . ":email" => 1,
                'EX'                                => $redis->ttl($sr_status_key),
                'NX'
            );
            BOM::Platform::Redis::release_lock($lock_key);
            return undef;
        } catch ($e) {
            $log->warn($e);
            exception_logged();
            BOM::Platform::Redis::release_lock($lock_key);
            return undef;
        }
    }
    BOM::Platform::Redis::release_lock($lock_key);
    return undef;
}

async sub _get_applicant_and_file {
    my (%args) = @_;

    # Start with an applicant and the file data (which might come from S3
    # or be provided locally)
    my ($applicant, $file_data) = await Future->needs_all(
        _get_onfido_applicant(%args{onfido}, %args{client}, %args{uploaded_manually_by_staff}, %args{country}),
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

    # Schedule the next HTTP call to be invoked as soon as the current round of IO operations is complete.
    await $loop->later;

    my $file = await _http()->GET($url, (connection => 'close'));

    return $file->decoded_content;
}

async sub _upload_onfido_documents {
    my (%args) = @_;

    my $onfido         = $args{onfido};
    my $client         = $args{client};
    my $document_entry = $args{document_entry};
    my $file_data      = $args{file_data};
    my $country        = $args{issuing_country} // $client->place_of_birth // $client->residence;

    try {
        my $applicant;
        ($applicant, $file_data) = await _get_applicant_and_file(
            onfido                     => $onfido,
            client                     => $client,
            document_entry             => $document_entry,
            file_data                  => $file_data,
            uploaded_manually_by_staff => $args{uploaded_manually_by_staff},
            country                    => $country
        );

        # Unsupported onfido country, we should do nothing.
        return 1 unless $applicant;

        $log->debugf('Applicant created: %s, uploading %d bytes for document', $applicant->id, length($file_data));

        # NOTE that this is very dependent on our current filename format
        my (undef, $type, $side) = split /\./, $document_entry->{file_name};

        $type = $ONFIDO_DOCUMENT_TYPE_MAPPING{$type} // 'unknown';
        $side =~ s{^\d+_?}{};
        $side = $ONFIDO_DOCUMENT_SIDE_MAPPING{$side} // 'front';
        $type = 'live_photo' if $side eq 'photo';

        my $future_upload_item;
        my %request;

        if ($type eq 'live_photo') {
            %request = (
                applicant_id => $applicant->id,
                data         => $file_data,
                filename     => $document_entry->{file_name},
            );

            $future_upload_item = $onfido->live_photo_upload(%request);
        } else {

            # We already checked country when _get_applicant_and_file
            %request = (
                applicant_id    => $applicant->id,
                data            => $file_data,
                filename        => $document_entry->{file_name},
                issuing_country => uc(country_code2code($country, 'alpha-2', 'alpha-3') // ''),
                side            => $side,
                type            => $type,
            );

            $future_upload_item = $onfido->document_upload(%request);
        }

        $future_upload_item->on_fail(
            sub {
                my ($err, $category, @details) = @_;
                $log->errorf('An error occurred while uploading document to Onfido for %s : %s', $client->loginid, $err)
                    unless ($category // '') eq 'http';

                # details is in res, req form
                my ($res) = @details;
                local $log->context->{place_of_birth}             = $country // 'unknown';
                local $log->context->{uploaded_manually_by_staff} = $args{uploaded_manually_by_staff} ? 1 : 0;

                delete $request{data};
                local $log->context->{request} = encode_json_utf8(\%request);

                $log->errorf('An error occurred while uploading document to Onfido for %s : %s with response %s ',
                    $client->loginid, $err, ($res ? $res->content : ''));

            });

        my $doc = await $future_upload_item;

        my $redis_events_write = _redis_events_write();

        if ($type eq 'live_photo') {
            BOM::User::Onfido::store_onfido_live_photo($doc, $applicant->id);
        } else {
            BOM::User::Onfido::store_onfido_document($doc, $applicant->id, $country, $type, $side);

            await $redis_events_write->connect;

            # Set expiry time for document id key in case of no onfido response due to
            # `applicant_check` is not being called in `ready_for_authentication`
            await $redis_events_write->setex(ONFIDO_DOCUMENT_ID_PREFIX . $doc->id, ONFIDO_PENDING_REQUEST_TIMEOUT, $document_entry->{id});
        }

        $log->debugf('Document %s created for applicant %s', $doc->id, $applicant->id,);

        return 1;

    } catch ($e) {
        $log->errorf('An error occurred while uploading document to Onfido for %s : %s', $client->loginid, $e);
        exception_logged();
    }
}

async sub _check_applicant {
    my ($args) = @_;
    my ($client, $applicant_id, $documents, $staff_name) = @{$args}{qw/client applicant_id documents staff_name/};

    my $onfido             = _onfido();
    my $broker             = $client->broker_code;
    my $loginid            = $client->loginid;
    my $residence          = uc(country_code2code($client->residence, 'alpha-2', 'alpha-3'));
    my $redis_events_write = _redis_events_write();
    my $res;

    # Open a mutex lock to avoid race conditions.
    # It's very unlikely that we would want to perform more than one check on the same binary_user_id
    # for whatever reason within a short timeframe. Note this lock will be released when
    # we get a webhook push from Onfido letting us know the check is ready or expire timeout.
    return unless BOM::Platform::Redis::acquire_lock(APPLICANT_CHECK_LOCK_PREFIX . $client->binary_user_id, APPLICANT_CHECK_LOCK_TTL);

    my $country     = $client->place_of_birth // $client->residence;
    my $country_tag = $country ? uc(country_code2code($country, 'alpha-2', 'alpha-3')) : '';
    my $tags        = ["country:$country_tag"];
    DataDog::DogStatsd::Helper::stats_inc('event.onfido.check_applicant.dispatch', {tags => $tags});

    try {
        # On v3.4, the applicant needs location in order to perform checks
        # make sure the applicant has a proper location before attempting a check
        # https://developers.onfido.com/guide/api-v3-to-v3.4-migration-guide#location

        await $onfido->applicant_update(
            applicant_id => $applicant_id,
            location     => BOM::User::Onfido::applicant_info($client)->{location},
        );

        $documents //= [];
        my $document_count = scalar $documents->@*;

        die 'documents not specified' if !$document_count && !$staff_name;

        # skip validation if the events was emitted from the BO
        # BO cannot specify documents, so it will use the last uploaded docs
        unless ($staff_name) {
            my $onfido_docs;

            if ($client->landing_company->requires_face_similarity_check) {
                my @live_photos = await $onfido->photo_list(applicant_id => $applicant_id)->as_list;

                # logs do often report 422 errors, this may be due to lack of live photo uploaded,
                # if the client has live photos but we still hitting 422 in the logs, we can confirm
                # our `applicant_check` call is buggy, otherwise we'll keep digging.
                die "applicant $applicant_id does not have live photos" unless scalar @live_photos;

                my @live_photo_ids = map { $_->id } @live_photos;
                my ($selfie) = intersect(@live_photo_ids, $documents->@*);

                die 'invalid live photo' unless $selfie;

                # valid document count interval [2,3] (there should be a selfie + some document picture)
                die 'documents not specified' if $document_count < 2;
                die 'too many documents'      if $document_count > 3;

                # grab all the applicant's documents id
                $onfido_docs = [$selfie, map { $_->id } await $onfido->document_list(applicant_id => $applicant_id)->as_list];
            } else {
                # we can drop the selfie here id the FE is still sending us a face similarity check request
                # can be taken down once FE stops asking for selfies when not needed
                my @live_photos    = await $onfido->photo_list(applicant_id => $applicant_id)->as_list;
                my @live_photo_ids = map { $_->id } @live_photos;

                $documents      = [array_minus($documents->@*, @live_photo_ids)];
                $document_count = scalar $documents->@*;

                # valid document count interval [1,2] (there should only be some document picture)
                die 'documents not specified' if $document_count < 1;
                die 'too many documents'      if $document_count > 2;

                # grab all the applicant's documents id
                $onfido_docs = [map { $_->id } await $onfido->document_list(applicant_id => $applicant_id)->as_list];
            }
            # all the documents coming from the args must belong to this applicant
            # in other words, the args documents must be a subset of the applicant docs

            die 'invalid documents' if array_minus($documents->@*, $onfido_docs->@*);
        }

        my $error_type;
        my %request = (
            applicant_id => $applicant_id,

            # We don't want Onfido to start emailing people
            suppress_form_emails => 1,

            # Used for reporting and filtering in the web interface
            tags => [$staff_name ? 'staff:' . $staff_name : 'automated', $broker, $loginid, $residence, 'brand:' . request->brand->name],

            # On v3 we need to specify the array of documents
            $staff_name ? () : (document_ids => $documents),

            # On v3 we need to specify the report names depending of the LC's requirements
            report_names => $client->landing_company->requires_face_similarity_check ? [qw/document facial_similarity_photo/] : [qw/document/],
        );

        my $future_applicant_check = $onfido->applicant_check(%request)->on_fail(
            sub {
                my (undef, undef, $response) = @_;

                $error_type = ($response and $response->content) ? decode_json_utf8($response->content)->{error}->{type} : '';

                if ($error_type eq 'incomplete_checks') {
                    $log->debugf('There is an existing request running for login_id: %s. The currenct request is pending until it finishes.',
                        $loginid);
                    $args->{is_pending} = 1;
                } else {
                    local $log->context->{request}  = encode_json_utf8(\%request);
                    local $log->context->{response} = $response->content if $response and $response->content;

                    $log->errorf('An error occurred while processing Onfido verification for %s : %s', $loginid, join(' ', @_));
                }
            }
        )->on_done(
            sub {
                my ($check) = @_;
                DataDog::DogStatsd::Helper::stats_inc('event.onfido.check_applicant.success', {tags => $tags});
                BOM::User::Onfido::store_onfido_check($applicant_id, $check);
                $res = 1;
            });

        await $future_applicant_check;

        if (defined $error_type and $error_type eq 'incomplete_checks') {
            await $redis_events_write->setex(
                ONFIDO_PENDING_REQUEST_PREFIX . $client->binary_user_id,
                ONFIDO_PENDING_REQUEST_TIMEOUT,
                encode_json_utf8($args));
        }

    } catch ($e) {
        DataDog::DogStatsd::Helper::stats_inc('event.onfido.check_applicant.failure', {tags => $tags});

        $log->errorf('An error occurred while processing Onfido verification for %s : %s', $client->loginid, $e);
        exception_logged();
    }

    await Future->needs_all(_update_onfido_check_count($redis_events_write));
    return $res;
}

async sub _update_onfido_check_count {
    my ($redis_events_write) = @_;

    my $record_count = await $redis_events_write->hincrby(ONFIDO_AUTHENTICATION_CHECK_MASTER_KEY, ONFIDO_REQUEST_COUNT_KEY, 1);

    if ($record_count == 1) {
        try {
            my $redis_response = await $redis_events_write->expire(ONFIDO_AUTHENTICATION_CHECK_MASTER_KEY, ONFIDO_LIMIT_TIMEOUT);
            return $redis_response;
        } catch ($e) {
            $log->debugf("Failed in adding expire to ONFIDO_AUTHENTICATION_CHECK_MASTER_KEY: %s", $e);
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
            age_verified           => $status->age_verification ? 'Yes'               : 'No',
            authentication_status  => $auth_status eq 'no'      ? 'Not authenticated' : $auth_status,
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
            $tt->process(BOM::Event::Actions::Common::TEMPLATE_PREFIX_PATH . 'qualifying_payment_check.html.tt', $data, \my $html);
            die "Template error: @{[$tt->error]}" if $tt->error;

            die "failed to send qualifying_payment_check email ($loginid)"
                unless Email::Stuffer->from($system_email)->to($compliance_email)->subject($email_subject)->html_body($html)->send();

            return undef;
        } catch ($e) {
            $log->warn($e);
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

    my $is_first_deposit   = $args->{is_first_deposit};
    my $payment_processor  = $args->{payment_processor} // '';
    my $transaction_id     = $args->{transaction_id}    // '';
    my $account_identifier = $args->{account_identifier};
    my $payment_method     = $args->{payment_method} // '';
    my $payment_type       = $args->{payment_type}   // '';

    $account_identifier = sha256_hex($account_identifier) if $account_identifier;

    if ($is_first_deposit) {
        BOM::Platform::Event::Emitter::emit('verify_address', {loginid => $client->loginid});
        BOM::Platform::Client::IDAuthentication->new(client => $client)->run_authentication;
    }

    if ($payment_type && !$client->status->age_verification) {
        my $antifraud = BOM::Platform::Client::AntiFraud->new(client => $client);

        try {
            if ($antifraud->df_cumulative_total_by_payment_type($payment_type)) {
                $client->status->setnx('allow_document_upload', 'system',
                    "A deposit made with payment type $payment_type has crossed the cumulative limit");
                $client->status->upsert('df_deposit_requires_poi', 'system',
                    "DF deposits with payment type $payment_type locked until the client gets age verified");
            }
        } catch ($e) {
            $log->warnf('Failed to check for deposit limits of the client %s: %s', $loginid, $e);
        }
    }

    if ($payment_type eq 'CreditCard') {
        if (!$client->landing_company->is_eu) {
            $client->status->setnx('personal_details_locked', 'system',
                "A card deposit is made via $payment_processor with ref. id: $transaction_id");
            $client->save;
        }
    }

    my $pm_config          = BOM::Config::Payments::PaymentMethods->new();
    my $high_risk_settings = $pm_config->high_risk($payment_type);

    if ($high_risk_settings) {
        my $high_risk_pm = $pm_config->high_risk_group($payment_type);
        my $record       = BOM::User::PaymentRecord->new(user_id => $client->binary_user_id);
        my %payment      = (
            id => $account_identifier,
            pm => $payment_method,
            pp => $payment_processor,
            pt => $payment_type,
        );

        $record->add_payment(%payment);

        my $antifraud = BOM::Platform::Client::AntiFraud->new(client => $client);

        if ($antifraud->df_total_payments_by_payment_type($payment_type)) {
            await on_user_payment_accounts_limit_reached(
                loginid        => $client->loginid,
                limit          => $client->payment_accounts_limit($high_risk_settings->{limit}),
                payment_type   => $high_risk_pm,
                binary_user_id => $client->binary_user_id,
            );
        }
    }

    BOM::Platform::Event::Emitter::emit('check_name_changes_after_first_deposit', {loginid => $client->loginid});

    return 1;
}

=head2 track_payment_deposit

This is handler for each B<payment_deposit> event emitted, when handled by the track worker.

=cut

sub track_payment_deposit {
    my ($args) = @_;

    return BOM::Event::Services::Track::payment_deposit($args);
}

=head2 on_user_payment_accounts_limit_reached

Send an email to x-antifraud-alerts@deriv.com warn about the limit that has been reached for the user

=cut

async sub on_user_payment_accounts_limit_reached {
    my %args = @_;

    my $key = join '::', +PAYMENT_ACCOUNT_LIMIT_REACHED_KEY, 'PaymentType', $args{payment_type};

    return undef if await _redis_replicated_write()->hget($key, $args{binary_user_id});

    await _redis_replicated_write()->hset($key, $args{binary_user_id}, 1);

    send_email({
            from    => '<no-reply@deriv.com>',
            to      => 'x-antifraud-alerts@deriv.com',
            subject => sprintf('Allowed limit on %s reached by %s', $args{payment_type}, $args{loginid}),
            message => [
                sprintf("The maximum allowed limit on %s per user of %d has been reached by %s.", $args{payment_type}, $args{limit}, $args{loginid})
            ],
        });
}

=head2 withdrawal_limit_reached

Sets 'needs_action' to a client

=cut

sub withdrawal_limit_reached {
    my ($args) = @_;
    my $loginid = $args->{loginid} or die 'Client login ID was not given';

    my $client = BOM::User::Client->new({
            loginid => $loginid,
        }) or die 'Could not instantiate client for login ID ' . $loginid;

    return if $client->fully_authenticated();

    # check if POA is pending:
    my $documents = $client->documents->uploaded();
    return if $documents->{proof_of_address}->{is_pending};

    # set client as needs_action if only the status is not set yet
    unless (($client->authentication_status // '') eq 'needs_action') {
        $client->set_authentication('ID_DOCUMENT', {status => 'needs_action'});
        $client->save();
    }

    # allow client to upload documents and enforce special BO reason: WITHDRAWAL_LIMIT_REACHED
    $client->status->upsert('allow_document_upload', 'system', 'WITHDRAWAL_LIMIT_REACHED');

    return;
}

=head2 payops_event_update_account_status

Set or clear status on a client account

=cut

sub payops_event_update_account_status {
    my $args = shift;
    # Special flags for the stuffs
    my $loginid = $args->{loginid} // die 'No loginid provided';
    my $status  = $args->{status}  // die 'No status provided';
    # For these fields, it have a special behavior
    # When it is set to any truthy values except the below, it will perform operation as specified
    # when it is real, it means apply it to real sibilings
    # When it is all, it means apply it to all sibilings include virtual
    my $clear         = $args->{clear};
    my $set           = $args->{set} // ($clear ? undef : 1);
    my @special_flags = qw/real all/;
    die "Cannot set and clear status in a same call!" if defined $clear and defined $set;
    my $reason = $args->{reason} // "Requested by PayOps";
    my $client = BOM::User::Client->new({loginid => $loginid}) or die "$loginid does not exists";
    if ($clear) {
        if (grep { $_ eq $clear } @special_flags) {
            # We need to apply this to its sibilings so lets use this instead
            $client->clear_status_and_sync_to_siblings($status, $clear eq 'all', 0);
        } else {
            my $method = "clear_$status";
            $client->status->$method;
        }
    } else {
        $client->status->setnx($status, "system", $reason);
        if (grep { $_ eq $set } @special_flags) {
            # Copy it to its sibilings
            $client->copy_status_to_siblings($status, 'system', $set eq 'all');
        }
    }
}

=head2 payops_event_request_poo

Request proof of ownership (POO) from client

=cut

sub payops_event_request_poo {
    my $args = shift;
    for my $required_arg (qw/trace_id loginid payment_service_provider/) {
        die "Required argument $required_arg is absent" unless defined $args->{$required_arg};
    }
    my $loginid = delete $args->{loginid};
    # Note from payops it, it should never be able to temper the proof of ownership
    # so the maximum extent it can does it to request a new poo from client
    my $client = BOM::User::Client->new({loginid => $loginid}) or die "$loginid does not exists";
    $client->proof_of_ownership->create($args);
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
        } catch ($e) {
            push @errors, 'Error on line: ' . (join ', ', @$row) . ' - error: ' . $e;
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

async sub signup {
    my @args = @_;

    my ($data) = @args;
    my $loginid = $data->{loginid};

    my $client = BOM::User::Client->new({loginid => $loginid})
        or die 'Could not instantiate client for login ID ' . $loginid;

    my $emitting = 'verify_false_profile_info';
    try {
        BOM::Platform::Event::Emitter::emit(
            $emitting,
            {
                loginid => $client->loginid,
                map { $_ => $client->$_ } qw /first_name last_name/
            }) unless $client->is_virtual;
    } catch ($error) {
        $log->warnf('Failed to emit %s event for loginid %s, while processing the signup event: %s', $emitting, $client->loginid, $error);
    };

    await check_email_for_fraud($client);

    return 1;
}

=head2 track_signup

This is handler for each B<signup> event emitted, when handled by the track worker.

=cut

sub track_signup {
    my $data = shift;

    return BOM::Event::Services::Track::signup($data);
}

=head2 check_email_for_fraud

Helper for integration with fraud_prevention service.
Sends a request to the service if it's enabled.
In case fraud is detected, potential_fraud status will be set on suspicious accounts

=cut

async sub check_email_for_fraud {
    my ($client) = @_;

    try {
        return unless BOM::Config::Services->is_enabled('fraud_prevention');

        my $cfg = BOM::Config::Services->config('fraud_prevention');

        my $url = join q{} => ('http://', $cfg->{host}, ':', $cfg->{port}, '/check_email');

        # Schedule the next HTTP call to be invoked as soon as the current round of IO operations is complete.
        await $loop->later;

        my $result = await _http()->POST(
            $url, encode_json_utf8({email => $client->email}),
            content_type => 'application/json',
            timeout      => 5,
        );

        my $resp = decode_json_utf8($result->content);

        if ($resp->{error}) {
            die 'Error happend while proccessing fraud check ' . $resp->{error}{code} . ': ' . $resp->{error}{message};
        }

        die 'Unexpected format of the response: ' . $result->content unless $resp->{result};

        # No fraud detected.
        return if $resp->{result}{status} eq 'clear';

        die 'Unexpected fraud check status: ' . $resp->{result}{status}
            unless $resp->{result}{status} eq 'suspected';

        my $duplicates = $resp->{result}{details}{duplicate_emails};
        die 'Empty list of duplicate emails was returned' unless $duplicates && $duplicates->@*;

        my @real_users = grep { $_->bom_real_loginids() }
            map {
            eval { BOM::User->new(email => $_) }
                || ()
            } $duplicates->@*;

        # We're intrested only when client created more than 1 real account.
        return unless @real_users > 1;

        USER:
        for my $user (@real_users) {
            try {
                CLIENT:
                for my $client ($user->clients) {
                    next CLIENT if $client->is_virtual;
                    next USER   if $client->status->age_verification;
                    next CLIENT if $client->status->potential_fraud;

                    $client->status->setnx('potential_fraud', 'system', 'Duplicate emails: ' . join q{, } => $duplicates->@*);
                    $client->status->upsert('allow_document_upload', 'system', 'POTENTIAL_FRAUD');
                }
            } catch ($err) {
                $log->errorf('Fail while setting fraud status for user: %s', $err);
            }
        }
    } catch ($err) {
        $log->errorf('Fail to check email for fraud: %s', $err);
    }

    return;
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
        } catch ($e) {
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

=head2 crypto_withdrawal_email

Send an email to clients after a successful withdrawal

=over 4

=item * C<loginid> - required. Login id of the client.

=item * C<amount> - required. Amount of transaction

=item * C<currency> - required. Currency type

=item * C<transaction_hash> - required. Transaction hash

=item * C<transaction_url> - required. Transaction url

=item * C<transaction_status> - required. Transaction status

=back

=cut

sub crypto_withdrawal_email {

    my ($args) = @_;

    my %event_mapper = (
        SENT => {
            event_name => \&BOM::Event::Services::Track::crypto_withdrawal_sent_email,
            title      => localize('Your [_1] withdrawal is successful', $args->{currency}),
        },
        LOCKED => {
            event_name => \&BOM::Event::Services::Track::crypto_withdrawal_locked_email,
            title      => localize('Your [_1] withdrawal is in progress', $args->{currency}),
        },
        CANCELLED => {
            event_name => \&BOM::Event::Services::Track::crypto_withdrawal_cancelled_email,
            title      => localize('Your [_1] withdrawal is cancelled', $args->{currency}),
        },
    );

    return $event_mapper{$args->{transaction_status}}{event_name}({
        loginid            => $args->{loginid},
        transaction_hash   => $args->{transaction_hash},
        transaction_url    => $args->{transaction_url},
        transaction_status => $args->{transaction_status},
        amount             => $args->{amount},
        currency           => $args->{currency},
        reference_no       => $args->{reference_no},
        live_chat_url      => request->brand->live_chat_url,
        title              => $event_mapper{$args->{transaction_status}}{title},
    });
}

=head2 crypto_deposit_email

Send an email to clients upon a pending crypto deposit

=over 4

=item * C<loginid> - required. Login id of the client.

=item * C<amount> - required. Amount of transaction

=item * C<currency> - required. Currency type

=item * C<transaction_hash> - required. Transaction hash

=item * C<transaction_url> - required. Transaction url

=item * C<transaction_status> - required. Transaction status

=back

=cut

sub crypto_deposit_email {

    my ($args) = @_;

    my %event_mapper = (
        PENDING => {
            event_name => \&BOM::Event::Services::Track::crypto_deposit_pending_email,
            title      => localize('Your [_1] deposit is in progress', $args->{currency}),
        },
        CONFIRMED => {
            event_name => \&BOM::Event::Services::Track::crypto_deposit_confirmed_email,
            title      => localize('Your [_1] deposit is successful', $args->{currency}),
        },
    );

    return $event_mapper{$args->{transaction_status}}{event_name}({
        loginid            => $args->{loginid},
        amount             => $args->{amount},
        currency           => $args->{currency},
        live_chat_url      => request->brand->live_chat_url,
        title              => $event_mapper{$args->{transaction_status}}{title},
        transaction_hash   => $args->{transaction_hash},
        transaction_status => $args->{transaction_status},
        transaction_url    => $args->{transaction_url},
    });
}

=head2 crypto_withdrawal_rejected_email_v2

Handles sending event to trigger email from customer io and send required event data

=over 4

=item * C<loginid> - Login id of the client.

=item * C<reject_remark> - reject remark for rejecting payout

=item * C<reject_code> - reject code

=item * C<amount> - Amount requested

=item * C<currency> - Currency code

=item * C<title> - Title for email header

=item * C<reference_no> - db id of the withdrawal

=back

=cut

sub crypto_withdrawal_rejected_email_v2 {
    my ($params) = @_;

    my $prefrd_lang;
    try {
        my $user_dbic = BOM::Database::UserDB::rose_db()->dbic;
        $prefrd_lang = $user_dbic->run(
            fixup => sub {
                $_->selectrow_hashref('SELECT preferred_language FROM users.get_user_by_loginid(?)', undef, $params->{client_loginid});
            });
        $prefrd_lang = $prefrd_lang->{preferred_language} || '';
    } catch ($e) {
        $log->warnf('Failed to fetch user preferred language. Error::', $e);
    }
    my $brand      = Brands->new_from_app_id($params->{app_id});
    my $url_params = {
        app_id => $params->{app_id},
        $prefrd_lang ? (language => $prefrd_lang) : (),
    };
    my $reject_code = $params->{reject_code};
    my $meta_data   = '';
    # check if its special reject_code that is set from auto-reject script
    if ($reject_code =~ /--/) {
        my @reject_code_info = split('--', $reject_code);
        $reject_code = $reject_code_info[0];
        $meta_data   = $reject_code_info[1];
    }
    my $fiat_account_currency = BOM::Platform::Utility::get_fiat_sibling_account_currency_for($params->{loginid}) // 'fiat';
    return BOM::Event::Services::Track::crypto_withdrawal_rejected_email_v2({
        loginid       => $params->{loginid},
        reject_code   => $reject_code,
        reject_remark => $params->{reject_remark},
        meta_data     => $meta_data,
        amount        => $params->{amount},
        currency      => $params->{currency},
        title         => localize('Your [_1] withdrawal is declined', $params->{currency}),
        live_chat_url => $brand->live_chat_url($url_params),
        reference_no  => $params->{reference_no},
        fiat_account  => $fiat_account_currency,
    });
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
        } catch ($e) {
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
    my ($args)          = @_;
    my $client_loginid  = $args->{client_loginid} or die 'No client login ID specified';
    my $shared_loginids = $args->{shared_loginid} or die 'No shared client login ID specified';

    my $client = BOM::User::Client->new({loginid => $client_loginid})
        or die 'Could not instantiate client for login ID ' . $client_loginid;

    my @shared_loginid_array = sort(uniq(split(',', trim($shared_loginids))));

    die "Invalid shared loginids specified. Loginids string passed is empty." unless @shared_loginid_array;

    my $siblings = $client->get_siblings_information(
        include_virtual  => 0,
        include_disabled => 0,
        include_self     => 0,
        include_wallet   => 0,
    );
    my $siblings_loginids = [map { $siblings->{$_}->{loginid} } keys %$siblings];
    my @shared_clients    = ();
    my @filtered_loginids = ();
    push @shared_loginid_array, @$siblings_loginids;
    my %send_email_count = ($client->user->id => 1);

    foreach my $shared_loginid (@shared_loginid_array) {
        my $shared_client = BOM::User::Client->new({loginid => $shared_loginid});

        next unless $shared_client;

        push @filtered_loginids, $shared_loginid;
        push @shared_clients,    $shared_client;
    }
    splice @filtered_loginids, 10;    # The number of loginids in the reason is limited to 10

    # Lock the cashier and set shared PM to both clients
    $args->{staff} //= 'system';
    $client->status->setnx('cashier_locked', $args->{staff}, 'Shared payment method found');
    $client->status->upsert('shared_payment_method', $args->{staff}, _shared_payment_reason($client, join(',', @filtered_loginids)));

    # This may be dropped when POI/POA refactoring is done
    $client->status->upsert('allow_document_upload', $args->{staff}, 'Shared payment method found') unless $client->status->age_verification;
    _send_shared_payment_method_email($client);

    foreach my $shared (@shared_clients) {
        $shared->status->setnx('cashier_locked', $args->{staff}, 'Shared payment method found');
        $shared->status->upsert('shared_payment_method', $args->{staff}, _shared_payment_reason($shared, $client_loginid));

        # This may be dropped when POI/POA refactoring is done
        $shared->status->upsert('allow_document_upload', $args->{staff}, 'Shared payment method found') unless $shared->status->age_verification;
        unless ($send_email_count{$shared->user->id}) {
            _send_shared_payment_method_email($shared);
            $send_email_count{$shared->user->id} = 1;
        }
    }

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
    return $current if (any { $shared_loginid =~ /\b$_\b/ } @loginids) || scalar(@loginids) >= 10;
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

    # Each client may come from a different brand
    # this switches the template accordingly
    my $brand = Brands->new_from_app_id($client->source);
    request(BOM::Platform::Context::Request->new(brand_name => $brand->name));

    my $params = {
        language => request->language,
    };

    BOM::Platform::Event::Emitter::emit(
        'shared_payment_method_email_notification',
        {
            loginid    => $client->loginid,
            properties => {
                client_first_name   => $client_first_name,
                client_last_name    => $client_last_name,
                email               => $client->email,
                ask_poi             => !$client->status->age_verification,
                authentication_url  => $brand->authentication_url($params),
                payment_methods_url => $brand->payment_methods_url($params),
            }});

    return;
}

=head2 check_name_changes_after_first_deposit

Called when name is changed or doughflow deposit occurs.
Calculates a score for all name changes since first doughflow deposit.
If score exceeds a threshold and lifetime doughflow deposits are above a threshold,
withdrawal_locked is applied and an email sent to client.

=cut

sub check_name_changes_after_first_deposit {
    my ($args) = @_;

    my $loginid = $args->{loginid};

    my $deposit_total    = 100;    # check is run when aggregate doughflow deposits equal or exceed this amount
    my $change_threshold = 0.6;    # withdrawl lock is applied when name changes exceed this

    my $client = BOM::User->get_client_using_replica($loginid);
    return 1 if $client->status->age_verification || $client->fully_authenticated;
    return 1 if $client->status->withdrawal_locked;

    my $changes = $client->db->dbic->run(
        fixup => sub {
            $_->selectall_arrayref('SELECT * FROM payment.name_changes_after_first_deposit(?, ?)', {Slice => {}}, $loginid, $deposit_total);
        });

    return unless @$changes;

    my $total = 0;
    for my $change (@$changes) {
        my ($cur_first, $cur_last, $prev_first, $prev_last, $pg_userid) =
            $change->@{qw/cur_first_name cur_last_name prev_first_name prev_last_name pg_userid/};

        next unless $pg_userid eq 'system';    # exclude backoffice changes

        # a small number of clients in our db have empty names - we won't count their first name change
        next unless $prev_first and $prev_last;

        my $normal_score = Text::Levenshtein::XS::distance($cur_first, $prev_first);
        $normal_score += Text::Levenshtein::XS::distance($cur_last, $prev_last);
        $normal_score = $normal_score / length($prev_first . $prev_last);

        # compare the change with first name last name reversed
        my $flipped_score = Text::Levenshtein::XS::distance($cur_first, $prev_last);
        $flipped_score += Text::Levenshtein::XS::distance($cur_last, $prev_first);
        $flipped_score = $flipped_score / length($prev_first . $prev_last);

        $total += min($normal_score, $flipped_score);
    }

    if ($total > $change_threshold) {
        my $brand = request->brand();

        BOM::Platform::Event::Emitter::emit(
            account_with_false_info_locked => {
                loginid    => $loginid,
                properties => {
                    email              => $client->email,
                    authentication_url => $brand->authentication_url,
                    profile_url        => $brand->profile_url,
                    is_name_change     => 1,
                }});

        # assumes that allow_document_upload is added in RPC get_account_status when withdrawal_locked is present
        _set_all_sibling_status({
            loginid => $loginid,
            status  => 'withdrawal_locked',
            message => 'Excessive name changes after first deposit - pending POI'
        });
    }

    return 1;
}

=head2 link_affiliate_client

Add an affiliated client to commission database.

=over 4

=item * token - the affiliate token (MyAffiliates token)

=item * loginid - the loginid of the client account that needs to be linked to the affiliate

=item * binary_user_id - unique identifier for a binary user in user database

=item * platform - the platform string. (E.g. dxtrade)

=back

=cut

my $aff;

sub link_affiliate_client {
    my $args = shift;

    my ($myaffiliate_token, $loginid, $binary_user_id, $platform) = @{$args}{'token', 'loginid', 'binary_user_id', 'platform'};

    my $config = BOM::Config::third_party()->{myaffiliates};

    $aff //= WebService::MyAffiliates->new(
        user    => $config->{user},
        pass    => $config->{pass},
        host    => $config->{host},
        timeout => 10
    );

    unless ($aff) {
        DataDog::DogStatsd::Helper::stats_inc('myaffiliates.' . $platform . '.failure.get_aff_id', 1);
        $log->warnf("Unable to connect to MyAffiliate to parse token %s to link %s", $myaffiliate_token, $loginid);
        return;
    }

    my $myaffiliate_id = $aff->get_affiliate_id_from_token($myaffiliate_token);

    unless ($myaffiliate_id) {
        DataDog::DogStatsd::Helper::stats_inc('myaffiliates.' . $platform . '.failure.get_aff_id', 1);
        $log->warnf("Unable to parse token %s", $myaffiliate_token);
        return;
    }

    my $commission_db = BOM::Database::CommissionDB::rose_db();

    my $affiliate_id;
    try {
        my ($res) = $commission_db->dbic->run(
            fixup => sub {
                $_->selectall_array('SELECT id FROM affiliate.affiliate WHERE external_affiliate_id=?', undef, $myaffiliate_id);
            });
        $affiliate_id = $res->[0] if $res;
    } catch ($e) {
        $log->warnf("Exception thrown while querying data for affiliate [%s] error [%s]", $myaffiliate_id, $e);
    }

    unless ($affiliate_id) {
        DataDog::DogStatsd::Helper::stats_inc('myaffiliates.' . $platform . '.failure.get_internal_aff_id', 1);
        return;
    }

    try {
        $commission_db->dbic->run(
            ping => sub {
                $_->do('SELECT * FROM affiliate.add_new_affiliate_client(?,?,?,?)', undef, $loginid, $platform, $binary_user_id, $affiliate_id);
            });

        # notify commission deal listener about a new sign up
        my $stream = join '::', ($platform, 'real_signup');
        BOM::Config::Redis::redis_cfds_write()->execute('xadd', $stream, '*', 'platform', $platform, 'account_id', $loginid);
    } catch ($e) {
        $log->warnf("Unable to add client %s to affiliate.affiliate_client table. Error [%s]", $loginid, $e);
    }

    return;
}

=head2 account_opening_new

It is triggered for each B<account_opening_new> event emitted, delivering it to Segment.
It can be called with the following parameters:

=over

=item * C<properties> - Free-form dictionary of event properties.

=back

=cut

sub account_opening_new {
    my ($args) = @_;

    return BOM::Event::Services::Track::track_event(
        anonymous  => 1,
        event      => 'account_opening_new',
        properties => $args,
    );
}

=head2 self_tagging_affiliates

handler for self_tagging_affiliates event

We will have anonymous since we wont have the login id available for this flow as this comes from a affiliate url where they try to login/open a account

=cut

sub self_tagging_affiliates {
    my ($args) = @_;
    return BOM::Event::Services::Track::track_event(
        event      => 'self_tagging_affiliates',
        anonymous  => 1,
        properties => $args->{properties},
    );
}

# Some generated functions

=head2 pa_withdraw_confirm

It is triggered for each B<pa_withdraw_confirm> event emitted, delivering it to Segment.

=head2 pa_transfer_confirm

It is triggered for each B<pa_transfer_confirm> event emitted, delivering it to Segment.

=head2 reset_password_confirmation

It is triggered for each B<reset_password_confirmation> event emitted, delivering it to Segment.

=head2 reset_password_request

It is triggered for each B<reset_password_request> event emitted, delivering it to Segment.

=head2 confirm_change_email

Triggered after second stage in B<change_email tag: update> request.

=head2 verify_change_email

Triggered for first stage in B<change_email tag: verify>  request.

=head2 request_change_email

Triggered before B<change_email> request.

=head2 set_financial_assessment

It is triggered for each B<set_financial_assessment> event emitted.

=head2 api_token_delete

It is triggered for each B<api_token_delete> event emitted.

=head2 api_token_created

It is triggered for each B<api_token_create> event emitted.

=head2 transfer_between_accounts

It is triggered for each B<transfer_between_accounts> event emitted.

=head2 payment_withdrawal_reversal

Event to handle withdrawal_reversal payment type.

=head2 payment_withdrawal

Event to handle withdrawal payment type.

=head2 professional_status_requested

It is triggered for each B<professional_status_requested> event emitted.

=head2 shared_payment_method_email_notification

It is triggered for each B<shared_payment_method_email_notification> event emitted.

=over

=item * C<loginid> - required. Login Id of the user.

=item * C<properties> - Free-form dictionary of event properties.

=back

=cut

for my $func_name (
    qw(pa_withdraw_confirm
    pa_transfer_confirm
    reset_password_confirmation
    reset_password_request
    confirm_change_email
    verify_change_email
    request_change_email
    set_financial_assessment
    api_token_deleted
    api_token_created
    transfer_between_accounts
    payment_withdrawal_reversal
    payment_withdrawal
    professional_status_requested
    shared_payment_method_email_notification
    ))
{
    no strict 'refs';    # allow symbol table manipulation
    *{__PACKAGE__ . '::' . $func_name} = sub {
        my ($args) = @_;
        return &{"BOM::Event::Services::Track::$func_name"}($args);
    }
}

=head2 verify_email_closed_account_reset_password

handler for closed_account event

=head2 verify_email_closed_account_account_opening

handler for closed_account event

=head2 verify_email_closed_account_other

handler for closed_account event

=head2 request_payment_withdraw

handler for payment_withdrawal event

=head2 account_opening_existing

handler for account_opening_existing event

=head2 trading_platform_investor_password_change_failed

Handler for trading_platform_investor_password_change_failed event

=head2 trading_platform_investor_password_changed

Handler for trading_platform_investor_password_changed

=head2 trading_platform_password_change_failed

Handler for trading_platform_password_change_failed event

=head2 trading_platform_password_changed

Handler for trading_platform_password_changed event

=head2 trading_platform_investor_password_reset_request

Handler for trading_platform_investor_password_reset_request event

=head2 trading_platform_password_reset_request

Handler for trading_platform_password_reset_request event

=head2 trading_platform_account_created

Handler for trading_platform_account_created event

=head2 request_edd_document_upload

handler for Enhanced Due Diligence document upload request

=over

=item * C<args> - Free-form dictionary of event properties.

=back

=cut

for my $func_name (
    qw(verify_email_closed_account_reset_password
    verify_email_closed_account_account_opening
    verify_email_closed_account_other
    request_payment_withdraw
    request_edd_document_upload
    account_opening_existing
    trading_platform_investor_password_change_failed
    trading_platform_investor_password_changed
    trading_platform_password_change_failed
    trading_platform_password_changed
    trading_platform_investor_password_reset_request
    trading_platform_password_reset_request
    trading_platform_account_created
    ))
{
    no strict 'refs';    # allow symbol table manipulation
    *{__PACKAGE__ . '::' . $func_name} = sub {
        my ($args) = @_;
        return BOM::Event::Services::Track::track_event(
            event      => $func_name,
            loginid    => $args->{loginid},
            properties => $args->{properties},
        );
    }
}

=head2 derivx_account_deactivated

Sends email to a user notifiying them about their DerivX accounts being archived.
Takes the following named parameters

=over 4

=item * C<email> - user's  email address

=item * C<account> - user's inactive derivx account

=back

=cut

sub derivx_account_deactivated {
    my $args = shift;

    my $user    = eval { BOM::User->new(email => $args->{email}) } or die 'Invalid email address';
    my $loginid = eval { [$user->bom_loginids()]->[0] }            or die "User $args->{email} doesn't have any accounts";

    return BOM::Event::Services::Track::derivx_account_deactivated({
            loginid    => $loginid,
            email      => $args->{email},
            first_name => $args->{first_name},
            account    => $args->{account}});
}

=head2 bulk_client_status_update

updates the list of bulk login_ids with the status and reason provided in the
properties argument 

=over 4

=item * C<loginids> - list of client loginids to which the status change is to be applied

=item * C<properties> - properties to update the status of the client 

=back

=cut

async sub bulk_client_status_update {
    my ($args) = @_;
    my $loginids = $args->{loginids};
    my (@invalid_logins, @message, $status_op_summaries, $summary, $p2p_approved);
    my $properties = $args->{properties};
    my ($operation, $client_status_type, $status_checked, $reason, $clerk, $action, $req_params, $status_code) =
        @{$properties}{qw/status_op untrusted_action_type status_checked reason clerk action req_params status_code/};
    my $add_regex = qr/^add|^sync/;
    my @failed_update;

    push(@message, ("<br>",     "bulk operation details:"));
    push(@message, ("<br><br>", "action: " . $client_status_type));
    push(@message, ("<br>",     "operation: " . $operation));
    push(@message, ("<br>",     "clerk: " . $clerk . "<br><br>"));

    LOGIN:
    foreach my $loginid ($loginids->@*) {
        $status_op_summaries = "";
        $summary             = "";
        my $client = eval { BOM::User::Client::get_instance({'loginid' => $loginid}) };
        try {
            if (not $client) {
                push @invalid_logins, "<tr><td>" . $loginid . "</td></tr>";
                next LOGIN;
            }
            $p2p_approved = $client->_p2p_advertiser_cached->{is_approved} if $client->_p2p_advertiser_cached;
            if ($client_status_type eq 'disabledlogins') {
                if ($action eq 'insert_data' && $operation =~ $add_regex) {

                    #should check portfolio
                    if (@{$client->get_open_contracts}) {
                        $summary =
                            "<span class='error'>ERROR:</span>&nbsp;&nbsp;Account <b>$loginid</b> cannot be marked as disabled as account has open positions. Please check account portfolio.";
                    } else {
                        if (!$client->status->disabled) {
                            $client->status->upsert('disabled', $clerk, $reason);
                        } else {
                            $summary = "<span class='error'>ERROR:</span>&nbsp;&nbsp;Account <b>$loginid</b> status is already marked.";
                        }

                    }
                }

            } elsif ($client_status_type eq 'duplicateaccount' && ($operation =~ $add_regex)) {
                if ($client->status->$status_code) {
                    $summary =
                        "<span class='error'>ERROR:</span>&nbsp;&nbsp;<b>$loginid $reason ($clerk)</b>&nbsp;&nbsp;has not been saved, cannot override existing status reason</b>";
                    push @failed_update, "<tr><td>" . $summary . "</td></tr>";
                    next LOGIN;
                }
                $client->status->upsert($status_code, $clerk, $reason);
                my $m = BOM::Platform::Token::API->new;
                $m->remove_by_loginid($client->loginid);

            } else {
                if ($operation =~ $add_regex) {
                    $client->status->upsert($status_code, $clerk, $reason);
                    if ($status_code eq 'allow_document_upload' && $reason eq 'Pending payout request') {
                        BOM::User::Utility::notify_submission_of_documents_for_pending_payout($client);
                    }
                }
            }

            if ($client->_p2p_advertiser_cached) {
                delete $client->{_p2p_advertiser_cached};
                if ($p2p_approved ne $client->_p2p_advertiser_cached->{is_approved}) {
                    BOM::Event::Actions::P2P::p2p_advertiser_approval_changed({client_loginid => $client->loginid});
                }
            }
            $status_op_summaries = BOM::Platform::Utility::status_op_processor(
                $client,
                {
                    status_op             => $operation,
                    status_checked        => $status_checked,
                    untrusted_action_type => $client_status_type,
                    reason                => $reason,
                    clerk                 => $clerk
                });
        } catch {
            $summary =
                "<div class='notify notify--danger'><b>ERROR :</b>&nbsp;&nbsp;Failed to update $loginid, status <b>$client_status_type</b>. Please try again.</div>";
        }

        if ($summary =~ /ERROR/) {
            push @failed_update, "<tr><td>" . $summary . "</td></tr>";
        }
        if ($status_op_summaries && scalar $status_op_summaries->@*) {
            for my $status_op_summary ($status_op_summaries->@*) {
                my $status = $status_op_summary->{status};
                if (!$status_op_summary->{passed}) {
                    my $fail_op = 'process';
                    $fail_op = 'remove'                                                                        if $operation eq 'remove';
                    $fail_op = 'remove from siblings'                                                          if $operation eq 'remove_siblings';
                    $fail_op = 'copy to siblings'                                                              if $operation eq 'sync';
                    $fail_op = 'copy to accounts, only DISABLED ACCOUNTS can be synced to all accounts'        if $operation eq 'sync_accounts';
                    $fail_op = 'remove from accounts, only DISABLED ACCOUNTS can be removed from all accounts' if $operation eq 'remove_accounts';
                    $summary .=
                        "<div class='notify notify--danger'><b>ERROR :</b>&nbsp;&nbsp;Failed to $fail_op, status <b>$status</b>. Please try again.</div>";
                }

            }
            push @failed_update, "<tr><td>" . $summary . "</td></tr>";
        }
    }
    if (@invalid_logins) {
        push(@message, ("<br><h3>List of invalid logins: </h3>", "<table border='1'>"));
        push(@message, @invalid_logins);
        push(@message, "</table>");
    }

    if (@failed_update) {
        push(@message, ("<br><h3>List of failed updates: </h3>", "<table border='1'>"));
        push(@message, @failed_update);
        push(@message, "</table>");
    }

    if (!@failed_update && !@invalid_logins) {
        push(@message, "<br><h4> task completed no invalid logins were found or failures occured</h4>");
    } else {
        push(@message, "<br><h4> task completed some invalid logins were found or failures occured</h4>");
    }
    my $BRANDS     = BOM::Platform::Context::request()->brand();
    my $from_email = $BRANDS->emails('no-reply');
    my $to_email   = $BRANDS->emails('compliance');

    send_email({
        from                  => $from_email,
        to                    => $to_email,
        subject               => 'Client update status report',
        message               => \@message,
        email_content_is_html => 1,
    });
}

=head2 payops_event_email

Send email to notifiying though payops IT event.
Takes a hashref with the following named parameters

=over 4

=item * C<loginid>    - loginid

=item * C<subject>    - subject of email

=item * C<template>   - template of email

=item * C<properties> - properties of email

=item * C<recipient>  - email address 

=back

=cut

async sub payops_event_email {
    my $args = shift;

    my $subject = $args->{subject};
    my $loginid = $args->{loginid}
        or die 'No client loginid found';
    my $event_name = $args->{event_name};
    die 'No event specified' unless $event_name;

    my $client = BOM::User::Client->new({loginid => $loginid});
    die 'No client here' unless $client;
    my $template   = $args->{template};
    my $properties = $args->{properties};
    my $contents   = $args->{contents};

    my $recipient = $client->email;
    die 'No client email found' unless $recipient;

    return BOM::Event::Services::Track::track_event(
        event      => $event_name,
        properties => {
            properties     => $properties,
            subject        => $subject,
            email          => $recipient,
            contents       => $contents,
            email_template => $template,
        },
        loginid => $loginid
    );
}

=head2 underage_client_detected

Handles Underage clients.

It might disable the account if some conditions are met, otherwise it will inform the proper team via livechat.

Takes as hashref parameters:

=over 4

=item * C<loginid> - loginid of the client

=item * C<provider> - provider that detected the underage client

=item * C<from_loginid> - optional, in case the underage detection came from already uploaded docs

=back

Returns C<undef>

=cut

sub underage_client_detected {
    my $args = shift // {};

    my $provider = $args->{provider} or die 'provider is mandatory';

    my $loginid = $args->{loginid}
        or die 'No client login ID supplied?';

    my $client = BOM::User::Client->new({loginid => $loginid})
        or die 'Could not instantiate client for login ID ' . $loginid;

    my $from_client;

    $from_client = BOM::User::Client->new({loginid => $args->{from_loginid}}) if $args->{from_loginid};

    BOM::Event::Actions::Common::handle_under_age_client($client, $provider, $from_client);

    return undef;
}

1;
