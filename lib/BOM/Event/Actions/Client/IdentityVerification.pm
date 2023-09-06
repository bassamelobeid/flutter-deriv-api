package BOM::Event::Actions::Client::IdentityVerification;

use strict;
use warnings;
no indirect;

=head1 NAME

BOM::Event::Actions::Client::IdentityVerification

=head1 DESCRIPTION

Provides microservice handler for ID verification events.

=cut

use Brands::Countries;
use DataDog::DogStatsd::Helper;
use Future::AsyncAwait;
use IO::Async::Loop;
use JSON::MaybeUTF8 qw(:v2);
use List::Util      qw( any uniq );
use Log::Any        qw( $log );
use Scalar::Util    qw( blessed );
use Syntax::Keyword::Try;
use Time::HiRes;
use MIME::Base64  qw(decode_base64);
use Digest::MD5   qw(md5_hex);
use List::Util    qw(first);
use JSON::MaybeXS qw(decode_json encode_json);

use BOM::Config::Services;
use BOM::Event::Services;
use BOM::Event::Services::Track;
use BOM::Event::Utility    qw( exception_logged );
use BOM::Platform::Context qw( localize request );
use BOM::Platform::Utility;
use BOM::Platform::Event::Emitter;
use BOM::User::IdentityVerification;
use BOM::User::Client;
use BOM::Platform::S3Client;

use constant IDV_UPLOAD_TIMEOUT_SECONDS => 30;

use constant RESULT_STATUS => {
    pass     => \&idv_pass,
    verified => \&idv_verified,
    failed   => \&idv_failed,
    refuted  => \&idv_refuted,
    callback => \&idv_callback,
    pending  => \&idv_pending,
};

use constant DOCUMENT_UPLOAD_STATUS => {
    failed   => 'rejected',
    refuted  => 'rejected',
    verified => 'verified',
};

my $loop = IO::Async::Loop->new;
$loop->add(my $services = BOM::Event::Services->new);

{

    sub _http {
        return $services->http_idv();
    }

    sub _redis_replicated_write {
        return $services->redis_replicated_write();
    }

    sub _redis_events_write {
        return $services->redis_events_write();
    }
}

=head2 verify_identity

Handle identity verification
for given client loginid.

=over 4

=item * C<$loginid> - the client's loginid

=back

Returns 1 on sucess or undef on error

=cut

async sub verify_identity {
    my $args = shift;

    my ($loginid) = @{$args}{qw/loginid/};

    my $client = BOM::User::Client->new({loginid => $loginid})
        or die sprintf("Could not initiate client for loginid: %s", $loginid);

    my $idv_model    = BOM::User::IdentityVerification->new(user_id => $client->binary_user_id);
    my $pending_lock = $idv_model->get_pending_lock();
    $idv_model->remove_lock();

    die sprintf("No pending lock found for loginid: %s", $client->loginid) unless defined $pending_lock;

    # head scratching huh? however the claim was made at RPC level, if the event gets here
    # and submissions left = 0 the only way could've been by expired chance used.
    my $has_expired_chance = $idv_model->has_expired_document_chance();

    die sprintf("No submissions left, IDV request has ignored for loginid: %s", $client->loginid)
        if $pending_lock <= 0 && $has_expired_chance;

    die $log->errorf('Could not trigger IDV, microservice is not enabled.') unless BOM::Config::Services->is_enabled('identity_verification');

    my $document = $idv_model->get_standby_document();

    die 'No standby document found, IDV request skipped.' unless $document;

    my $provider = _get_provider($document->{issuing_country}, $document->{document_type});

    return undef unless $provider;

    my @common_datadog_tags = (sprintf('provider:%s', $provider), sprintf('country:%s', $document->{issuing_country}));

    try {
        $log->debugf('Start triggering identity verification microservice (contacting %s) for document %s associated by loginid: %s',
            $provider, $document->{id}, $loginid);

        my $request_start = [Time::HiRes::gettimeofday];

        my @result = await _trigger(
            $client,
            $document,
            sub {
                my $request_body = shift;

                $idv_model->update_document_check({
                    document_id  => $document->{id},
                    status       => 'pending',
                    messages     => ['VERIFICATION_STARTED'],
                    provider     => $provider,
                    request_body => $request_body
                });

                BOM::Platform::Event::Emitter::emit(
                    'sync_mt5_accounts_status',
                    {
                        binary_user_id => $client->binary_user_id,
                        client_loginid => $client->loginid
                    });
            }) // undef;

        DataDog::DogStatsd::Helper::stats_timing(
            'event.identity_verification.callout.timing',
            (1000 * Time::HiRes::tv_interval($request_start)),
            {tags => [@common_datadog_tags,]});

        DataDog::DogStatsd::Helper::stats_inc(
            'event.identity_verification.request',
            {
                tags => [@common_datadog_tags,],
            });

        my ($status, $response_hash, $message) = @result;

        await verify_process({
            loginid       => $loginid,
            status        => $status,
            response_hash => $response_hash,
            message       => $message,
        });

        BOM::Platform::Event::Emitter::emit(
            'sync_mt5_accounts_status',
            {
                binary_user_id => $client->binary_user_id,
                client_loginid => $client->loginid
            });
    } catch ($e) {
        $log->errorf('An error occurred while triggering IDV for document %s associated by client %s via provider %s due to %s',
            $document->{id}, $loginid, $provider, $e);

        exception_logged();

        die $e;    # Keeps event in the queue.
    }

    return 1;
}

=head2 verify_process

Handle side-effects for identity verification
for given client.

=over 4

=item * C<$loginid> - the client's loginid

=item * C<$status> - status from idv provider

=item * C<$response_hash> - response hash from idv provider

=item * C<$message> - message from idv provider


=back

Returns 1 on sucess or undef on error

=cut

async sub verify_process {
    my $args = shift;

    my ($loginid, $status, $response_hash, $message) =
        @{$args}{qw/loginid status response_hash message/};

    die 'No status received.' unless $status;

    my $client = BOM::User::Client->new({loginid => $loginid})
        or die sprintf("Could not initiate client for loginid: %s", $loginid);

    my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->binary_user_id);

    die $log->errorf('Could not trigger IDV, microservice is not enabled.') unless BOM::Config::Services->is_enabled('identity_verification');

    my $document = $idv_model->get_standby_document();

    die 'No standby document found, IDV request skipped.' unless $document;

    my $provider = _get_provider($document->{issuing_country}, $document->{document_type});

    return undef unless $provider;

    my @common_datadog_tags = (sprintf('provider:%s', $provider), sprintf('country:%s', $document->{issuing_country}));

    my $report          = $response_hash->{report} // {};
    my $response_status = $response_hash->{status} // '';
    my $selfie          = delete $report->{selfie};
    my $document_pic    = delete $report->{document};
    my $selfie_file_id;
    my $document_file_id;

    $selfie_file_id = await _upload_photo({
            photo    => $selfie,
            client   => $client,
            status   => $response_status,
            document => $document,
        }) if $selfie;

    $document_file_id = await _upload_photo({
            photo    => $document_pic,
            client   => $client,
            status   => $response_status,
            document => $document,
        }) if $document_pic;

    my @messages = ref $message eq 'ARRAY' ? $message->@* : ($message // ());

    @messages = uniq @messages;

    my $callback = RESULT_STATUS->{$status} // RESULT_STATUS->{failed};
    my $pictures = [grep { $_ } ($document_file_id, $selfie_file_id)];

    await $callback->({
        client              => $client,
        messages            => \@messages,
        document            => $document,
        provider            => $provider,
        response_hash       => $response_hash,
        common_datadog_tags => \@common_datadog_tags,
        errors              => _messages_to_hashref(@messages),
        pictures            => scalar @$pictures ? $pictures : undef,
    });

    return 1;
}

=head2 idv_verified

Verified Result Status for IDV, when the document was cleared

=cut

async sub idv_verified {
    my ($args) = @_;

    my ($client, $messages, $document, $provider, $response_hash, $pictures) =
        @{$args}{qw/client messages document provider response_hash pictures/};
    my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->binary_user_id);

    $client->propagate_clear_status('poi_name_mismatch');
    $client->propagate_clear_status('poi_dob_mismatch');

    if (any { $_ eq 'ADDRESS_VERIFIED' } @$messages) {
        $client->set_authentication('IDV', {status => 'pass'});
        $client->status->clear_unwelcome;
    } elsif ($pictures && scalar @$pictures) {
        $client->set_authentication('IDV_PHOTO', {status => 'pass'});
    }
    my $redis_events_write = _redis_events_write();
    await $redis_events_write->connect;

    await BOM::Event::Actions::Common::set_age_verification($client, $provider, $redis_events_write, 'idv');

    $idv_model->update_document_check({
        document_id     => $document->{id},
        status          => 'verified',
        provider        => $provider,
        messages        => [uniq @$messages],
        report          => encode_json_text($response_hash->{report} // {}),
        expiration_date => $response_hash->{report}->{expiry_date},
        request_body    => encode_json_text($response_hash->{request_body}  // {}),
        response_body   => encode_json_text($response_hash->{response_body} // {}),
        photo           => $pictures
    });
}

=head2 idv_refuted

Refuted Result Status for IDV, when the document was rejected 

=cut

async sub idv_refuted {
    my ($args) = @_;

    my ($client, $document, $provider, $messages, $response_hash, $errors, $pictures) =
        @{$args}{qw/client document provider messages response_hash errors pictures/};
    my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->binary_user_id);

    push $messages->@*,
        _resolve_error_messages({
            client => $client,
            errors => $errors,
        });

    _apply_side_effects({
        client   => $client,
        messages => $messages,
        provider => $provider,
    });

    $idv_model->update_document_check({
        document_id     => $document->{id},
        status          => 'refuted',
        report          => encode_json_text($response_hash->{report} // {}),
        expiration_date => $response_hash->{report}->{expiry_date},
        messages        => [uniq @$messages],
        provider        => $provider,
        request_body    => encode_json_text($response_hash->{request_body}  // {}),
        response_body   => encode_json_text($response_hash->{response_body} // {}),
        photo           => $pictures,
    });

    BOM::Platform::Event::Emitter::emit(
        'identity_verification_rejected',
        {
            loginid    => $client->loginid,
            properties => {
                authentication_url => request->brand->authentication_url,
                live_chat_url      => request->brand->live_chat_url,
                title              => localize('We were unable to verify your document details'),
            }});
}

=head2 idv_failed

Failed Result Status, when there is an exception when calling IDV

=cut

async sub idv_failed {
    my ($args) = @_;

    my ($client, $document, $provider, $messages, $response_hash, $common_datadog_tags) =
        @{$args}{qw/client document provider messages response_hash common_datadog_tags/};

    my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->binary_user_id);

    DataDog::DogStatsd::Helper::stats_inc(
        'event.identity_verification.failure',
        {
            tags => [@$common_datadog_tags, sprintf('message:%s', $messages->[0] // 'UNKNOWN'),],
        });

    $idv_model->update_document_check({
        document_id   => $document->{id},
        status        => 'failed',
        messages      => $messages,
        provider      => $provider,
        request_body  => encode_json_text($response_hash->{request_body}  // {}),
        response_body => encode_json_text($response_hash->{response_body} // {}),
    });

    $log->infof('Identity verification for document %s via provider %s get failed due to %s', $document->{id}, $provider, $messages);
}

=head2 idv_pending

Pending Result Status, left the check hanging in the pending status.

=cut

async sub idv_pending {
    my ($args) = @_;

    my ($client, $provider, $document, $messages, $response_hash) = @{$args}{qw/client provider document messages response_hash/};

    my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->binary_user_id);

    $idv_model->update_document_check({
        document_id  => $document->{id},
        status       => 'pending',
        messages     => $messages,
        provider     => $provider,
        request_body => encode_json_text($response_hash->{request_body} // {}),
    });
}

=head2 idv_pass

Pass Result Status, when there is no failure when calling IDV

=cut

async sub idv_pass {
    my ($args) = @_;

    my ($client, $document, $messages, $response_hash) = @{$args}{qw/client document messages response_hash/};

    my $rule_engine = BOM::Rules::Engine->new(
        client          => $client,
        residence       => $client->residence,
        stop_on_failure => 0
    );

    my $rules_result = $rule_engine->verify_action(
        'identity_verification',
        loginid  => $client->loginid,
        result   => $response_hash->{report},
        document => $document,
    );

    unless ($rules_result->has_failure) {
        await idv_verified($args);
    } else {
        await idv_refuted({$args->%*, errors => $rules_result->errors});
    }
}

=head2 idv_callback

Callback Result Status, to set status as deferred in DB when calling IDV

=cut

async sub idv_callback {
    my ($args) = @_;

    my ($client, $provider, $document, $messages, $response_hash) = @{$args}{qw/client provider document messages response_hash/};

    my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->binary_user_id);

    $idv_model->update_document_check({
        document_id  => $document->{id},
        status       => 'deferred',
        messages     => $messages,
        provider     => $provider,
        request_body => encode_json_text($response_hash->{request_body} // {}),
    });
}

=head2 _messages_to_hashref

Given a list of error messages, map them into a hashref that is rule engine output equivalent.

=cut

sub _messages_to_hashref {
    my $mappings = {
        NAME_MISMATCH => 'NameMismatch',
        UNDERAGE      => 'UnderAge',
        DOB_MISMATCH  => 'DobMismatch',
        EXPIRED       => 'Expired',
    };

    return +{map { exists $mappings->{$_} ? ($mappings->{$_} => 1) : () } @_};
}

=head2 _resolve_error_messages

Given a hashref of possible validation errors, resolves the error messages.

It takes the following arguments as hashref:

=over 4

=item C<client> - the L<BOM::User::Client> instance.

=item C<errors> - the hashref with validations errors to process.

=back

Returns a list of possible error messages.

=cut

sub _resolve_error_messages {
    my $args = shift;
    my ($client, $errors) = @{$args}{qw/client errors/};

    my @messages;

    unless (exists $errors->{Expired}) {
        if (exists $errors->{NameMismatch}) {
            push @messages, "NAME_MISMATCH";
        }

        if (exists $errors->{UnderAge}) {
            push @messages, 'UNDERAGE';

        }

        if (exists $errors->{DobMismatch}) {
            push @messages, 'DOB_MISMATCH';
        }
    } else {
        push @messages, 'EXPIRED';
    }

    return @messages;
}

=head2 _apply_side_effects

Given a hashref of possible validation errors, applies the side effects required.

It takes the following arguments as hashref:

=over 4

=item C<client> - the L<BOM::User::Client> instance.

=item C<messages> - the hashref with messages to process.

=item C<provider> - the name of the IDV provider.

=back

Returns undef.

=cut

sub _apply_side_effects {
    my $args = shift;
    my ($client, $messages, $provider) = @{$args}{qw/client messages provider/};
    my $clear_age_verification;

    unless (any { $_ eq 'EXPIRED' } $messages->@*) {
        if (any { $_ eq 'NAME_MISMATCH' } $messages->@*) {
            $client->propagate_status('poi_name_mismatch', 'system', "Client's name doesn't match with provided name by $provider");
            $clear_age_verification = 1;
        }

        if (any { $_ eq 'UNDERAGE' } $messages->@*) {
            BOM::Event::Actions::Common::handle_under_age_client($client, $provider);
            $clear_age_verification = 1;
            BOM::User::IdentityVerification::reset_to_zero_left_submissions($client->binary_user_id);    # no second attempts allowed
        }

        if (any { $_ eq 'DOB_MISMATCH' } $messages->@*) {
            $client->propagate_status('poi_dob_mismatch', 'system', "Client's DOB doesn't match with provided DOB by $provider");
            $clear_age_verification = 1;
        }

    } else {
        $clear_age_verification = 1;
    }

    $client->propagate_clear_status('age_verification') if $clear_age_verification;
    return undef;
}

=head2 _trigger

Triggers given provider through IDV microservice.

=over 4

=item * C<client> - the client instance

=item * C<docuemnt> - the standby document

=item * C<before_request_hook> - a annonymous subroutine that going to be called right before sending requests and accept the request body.

=item * C<provider> - The provider name

=back

Returns an array includes (status, request + response, status message).

=cut

async sub _trigger {
    my ($client, $document, $before_request_hook) = @_;

    my $config = BOM::Config::Services->config('identity_verification');

    my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->binary_user_id);

    my $api_base_url = sprintf('http://%s:%s', $config->{host}, $config->{port});

    my $req_body = encode_json_utf8 {
        document => {
            issuing_country => $document->{issuing_country},
            type            => $document->{document_type},
            number          => $document->{document_number},
            $document->{document_additional} ? (additional => $document->{document_additional}) : (),
        },
        profile => {
            id         => $client->loginid,
            first_name => $client->first_name,
            last_name  => $client->last_name,
            birthdate  => $client->date_of_birth,
        },
        address => {
            line_1    => $client->address_line_1,
            line_2    => $client->address_line_2,
            postcode  => $client->address_postcode,
            residence => $client->residence,
            city      => $client->address_city,
        }};

    my $response         = undef;
    my $decoded_response = undef;

    my $status         = undef;
    my $status_message = [];

    $before_request_hook->($req_body);

    my $url = "$api_base_url/v1/idv";

    try {
        # Schedule the next HTTP POST request to be invoked as soon as the current round of IO operations is complete.
        await $loop->later;

        $response         = (await _http()->POST($url, $req_body, (content_type => 'application/json')))->content;
        $decoded_response = eval { decode_json_utf8 $response }
            // {};    # further json encoding of this hashref should not convert to utf8 again, use `json_encode_text` instead

        $status         = $decoded_response->{status};
        $status_message = $decoded_response->{messages};
    } catch ($e) {
        if (blessed($e) and $e->isa('Future::Exception')) {
            my ($payload) = $e->details;
            $response = $payload->content;

            $decoded_response = eval { decode_json_utf8 $response } // {};

            $status = 'failed';

            $status_message = $log->errorf(
                "Identity Verification Microservice responded an error to our request for verify document %s with code: %s, message: %s - %s",
                $document->{id}, $decoded_response->{code} // 'UNKNOWN',
                $e->message, $decoded_response->{error} // 'UNKNOWN'
            );
        } elsif ($e =~ /\bconnection refused\b/i) {

            # Give back a submission attempt
            $idv_model->decr_submissions();

            # Update the status to failed as for it to not remain in perpetual 'pending' state
            $status         = 'failed';
            $status_message = "CONNECTION_REFUSED";

        } else {
            $log->errorf('Unhandled IDV exception: %s', $e);
        }
    }

    unless ($status) {
        $status         = 'failed';
        $status_message = 'UNAVAILABLE_MICROSERVICE';
    }

    return ($status, $decoded_response, $status_message);
}

=head2 _get_provider

Find IDV service provider based on 
client's document issuer country.

=over 4

=item * C<issuing_country> - the document's issuing country

=back

Returns string.

=cut

sub _get_provider {
    my ($issuing_country, $document_type) = @_;

    return 'qa' if BOM::Config::on_qa() && $issuing_country eq 'qq';

    my $country_configs = Brands::Countries->new();
    my $idv_config      = $country_configs->get_idv_config($issuing_country);

    return undef
        unless BOM::Platform::Utility::has_idv(
        country       => $issuing_country,
        provider      => $idv_config->{provider},
        document_type => $document_type
        );

    return $idv_config->{provider};
}

=head2 idv_webhook_relay

Relay the IDV request from the webhook to our idv microservice

=over 4

=item * C<webhook_response> - the response from the webhook

=back

Returns an array includes (status, request + response, status message).

=cut

async sub idv_webhook_relay {
    my $args = shift;

    my $config = BOM::Config::Services->config('identity_verification');

    my $api_base_url = sprintf('http://%s:%s', $config->{host}, $config->{port});

    my ($response, $idv_retry_response, $decoded_response, $webhook_response, $login_id, $status);

    my $status_message = [];

    my $url = "$api_base_url/v1/idv/webhook";

    # make header comparison case insensitive
    my $headers_lc = {map { lc($_) => $args->{headers}->{$_} } keys $args->{headers}->%*};

    try {
        # if 'x-retry-attempts' present in header, it means that it came from the IDV retry mechanism
        if ($headers_lc->{'x-retry-attempts'}) {
            my $retry_attempts = $headers_lc->{'x-retry-attempts'};
            $log->debugf("Got IDV webhook with attempt number: $retry_attempts");
            $idv_retry_response = $args->{data}->{json};

        }
        # if 'x-request-id' present in header, it means that it came from MetaMap IDV provider
        elsif ($headers_lc->{'x-request-id'}) {
            # Schedule the next HTTP POST request to be invoked as soon as the current round of IO operations is complete.
            await $loop->later;
            delete $args->{headers}->{'Content-Length'};

            $response = (
                await _http()->POST(
                    $url,
                    encode_json_utf8($args->{data}->{json}),
                    (
                        content_type => 'application/json',
                        headers      => $args->{headers})))->content;

            $decoded_response = decode_json_utf8($response);
            # further json encoding of this hashref should not convert to utf8 again, use `json_encode_text` instead
        } else {
            die 'no recognizable headers';
        }

        $webhook_response = $idv_retry_response // $decoded_response;

        die 'no req_echo' unless defined $webhook_response->{req_echo};

        $status         = $webhook_response->{status};
        $status_message = $webhook_response->{messages};
        $login_id       = $webhook_response->{req_echo}->{profile}->{id};

        await verify_process({
            loginid       => $login_id,
            status        => $status,
            response_hash => $webhook_response,
            message       => $status_message,
        });

    } catch ($e) {
        if (blessed($e) and $e->isa('Future::Exception')) {
            my ($payload) = $e->details;
            $response = $payload->content;

            $webhook_response = eval { decode_json_utf8 $response } // {};

            $status = 'failed';

            $status_message = $log->errorf(
                "Identity Verification Microservice responded an error to our request for passing the webhook response with code: %s, message: %s - %s",
                $webhook_response->{code} // 'UNKNOWN',
                $e->message,
                $webhook_response->{error} // 'UNKNOWN'
            );
        } elsif ($e =~ /\bconnection refused\b/i) {

            # Update the status to failed as for it to not remain in perpetual 'pending' state
            $status         = 'failed';
            $status_message = "CONNECTION_REFUSED";

        } else {
            $log->errorf('Unhandled IDV exception: %s', $e);
        }
    }

    unless ($status) {
        $status         = 'failed';
        $status_message = 'UNAVAILABLE_MICROSERVICE';
    }

    return ($status, $webhook_response, $status_message);

}

=head2 _upload_photo

Gets the client's photo from IDV and uploads to S3

=over 4

=item * C<data> - the data of the current idv object as hashref containing:

=item * C<photo> - the base64 photo as a string

=item * C<client> - the client instance

=item * C<status> - the status returned by the idv check

=item * C<document> - a hashref representing the IDV document

=back

Returns the file id of the photo uploaded to s3

=cut

async sub _upload_photo {
    my $data = shift;
    my ($photo, $client, $status, $document) =
        @{$data}{qw/photo client status document/};

    my $s3_client = BOM::Platform::S3Client->new(BOM::Config::s3()->{document_auth});

    my $final_status = DOCUMENT_UPLOAD_STATUS->{$status} // 'uploaded';

    my $decoded_photo = decode_base64($photo);    # here we convert the photo from base64 to binary
    my $upload_info;
    my $s3_uploaded;
    my $file_id;
    my $new_file_name;

    my $file_type = _detect_mime_type($photo);

    return undef unless $file_type;

    my @file_type_array = split('/', $file_type);

    $file_type = pop(@file_type_array);

    my $file_checksum = md5_hex($decoded_photo);

    # If the following key exists, the document is already being uploaded,
    # so we can safely drop this event.
    my $lock_key     = join q{-} => ('IDV_UPLOAD_BAG', $client->loginid, $file_checksum);
    my $acquire_lock = BOM::Platform::Redis::acquire_lock($lock_key, IDV_UPLOAD_TIMEOUT_SECONDS);

    unless ($acquire_lock) {
        $log->warn("Document already exists");
        return;
    }

    try {
        my $lifetime_valid = 0;
        my $new_document   = 1;

        $upload_info = $client->db->dbic->run(
            ping => sub {
                $_->selectrow_hashref(
                    'SELECT * FROM betonmarkets.start_document_upload(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?::betonmarkets.client_document_origin, ?)',
                    undef, $client->loginid, 'photo', $file_type, undef, '', $file_checksum, '', '', undef, $lifetime_valid, 'idv',
                    $document->{issuing_country});
            });

        if ($upload_info && $upload_info->{file_id}) {
            ($file_id, $new_file_name) = @{$upload_info}{qw/file_id file_name/};

            $log->debugf("Starting to upload file_id: $file_id to S3 ");
            $s3_uploaded = await $s3_client->upload_binary($new_file_name, $decoded_photo, $file_checksum);

        } else {
            $log->warn(sprintf("Document with this file id already exists, checksum=%s loginid=%s", $file_checksum, $client->loginid));

            # if the document is already present in betonmarkets document table
            # it should've already been uploaded to s3, we can assume it's there
            # with this we are only recovering the existing ID from the documents table in order
            # to inject it into the idv check record

            $upload_info = $client->db->dbic->run(
                ping => sub {
                    $_->selectrow_hashref(
                        'SELECT id, file_name FROM betonmarkets.client_authentication_document WHERE checksum = ? AND client_loginid = ? AND document_type = ?',
                        undef, $file_checksum, $client->loginid, 'photo'
                    );
                });

            ($file_id, $new_file_name) = @{$upload_info}{qw/id file_name/};
            $s3_uploaded  = $upload_info && $upload_info->{file_id};
            $new_document = 0;
        }

        if ($s3_uploaded) {

            # only new documents need to be finished
            # we can assume existing documents were already finished previously

            if ($new_document) {
                $log->debugf("Successfully uploaded file_id: $file_id to S3 ");
                my $finish_upload_result = $client->db->dbic->run(
                    ping => sub {
                        $_->selectrow_array('SELECT * FROM betonmarkets.finish_document_upload(?, ?::status_type)', undef, $file_id, $final_status);
                    });

                die "Db returned unexpected file_id on finish. Expected $file_id but got $finish_upload_result. Please check the record"
                    unless $finish_upload_result == $file_id;
            }

            my $document_info = {
                # to avoid a db hit, we can estimate the `upload_date` to the current timestamp.
                # all the other fields can be derived from current symbols table.
                upload_date     => Date::Utility->new->datetime_yyyymmdd_hhmmss,
                file_name       => $new_file_name,
                id              => $file_id,
                lifetime_valid  => $lifetime_valid,
                document_id     => '',
                comments        => '',
                expiration_date => undef,
                document_type   => 'photo'
            };

            if ($document_info) {
                await BOM::Event::Services::Track::document_upload({
                    client     => $client,
                    loginid    => $client->loginid,
                    properties => $document_info
                });
            } else {
                $log->errorf('Could not get document %s from database for client %s', $file_id, $client->loginid);
            }
        }
    } catch ($error) {
        $log->errorf("Error in creating record in db and uploading IDV photo to S3 for %s : %s", $client->loginid, $error);
        exception_logged();
    }

    BOM::Platform::Redis::release_lock($lock_key);

    return $file_id;
}

=head2 _detect_mime_type

Detects the mime type based on the starting characters of the string.

=over 4

=item * C<base64_photo> - the base64 photo as a string

=back

Returns string of mime type detected

=cut

sub _detect_mime_type {
    my $base64_photo = shift;

    my %signatures = (
        iVBORw0KGgo => "image/png",
        "/9j/"      => "image/jpg"
    );

    # These signatures are unique to these specific image mime.

    my $sign = first { index($base64_photo, $_) == 0 } keys %signatures;

    return undef unless $sign;

    return $signatures{$sign};

}

1
