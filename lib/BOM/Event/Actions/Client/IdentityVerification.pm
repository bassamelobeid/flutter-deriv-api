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
use constant ONE_SECOND_IN_MS           => 1000;

use constant RESULT_STATUS => {
    verified => \&idv_verified,
    failed   => \&idv_failed,
    refuted  => \&idv_refuted,
    callback => \&idv_callback,
    pending  => \&idv_pending,
};

use constant IDV_DOCUMENT_STATUS => {
    pending  => 'pending',
    failed   => 'failed',
    deferred => 'deferred',
    verified => 'verified',
    pass     => 'pass',
    refuted  => 'refuted',
};

use constant IDV_MESSAGES => {
    VERIFICATION_STARTED     => 'VERIFICATION_STARTED',
    UNAVAILABLE_MICROSERVICE => 'UNAVAILABLE_MICROSERVICE',
    CONNECTION_REFUSED       => 'CONNECTION_REFUSED',
    ADDRESS_VERIFIED         => 'ADDRESS_VERIFIED',
    EXPIRED                  => 'EXPIRED',
    UNDERAGE                 => 'UNDERAGE',
    DOB_MISMATCH             => 'DOB_MISMATCH',
    NAME_MISMATCH            => 'NAME_MISMATCH',
    UNKNOWN                  => 'UNKNOWN',
};

use constant IDV_ERROR_MAPPING => {
    NAME_MISMATCH => 'NameMismatch',
    UNDERAGE      => 'UnderAge',
    DOB_MISMATCH  => 'DobMismatch',
    EXPIRED       => 'Expired',
};

use constant DOCUMENT_UPLOAD_STATUS => {
    failed   => 'rejected',
    refuted  => 'rejected',
    verified => 'verified',
    uploaded => 'uploaded',
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

        my $config = BOM::Config::Services->config('identity_verification');

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

        $idv_model->update_document_check({
            document_id  => $document->{id},
            status       => IDV_DOCUMENT_STATUS->{pending},
            messages     => [IDV_MESSAGES->{VERIFICATION_STARTED}],
            provider     => $provider,
            request_body => $req_body
        });

        # Schedule the next HTTP POST request to be invoked as soon as the current round of IO operations is complete.
        await $loop->later;
        await _http()->POST("$api_base_url/v1/idv", $req_body, (content_type => 'application/json'));

        DataDog::DogStatsd::Helper::stats_timing(
            'event.identity_verification.callout.timing',
            (ONE_SECOND_IN_MS * Time::HiRes::tv_interval($request_start)),
            {tags => [@common_datadog_tags]});

        DataDog::DogStatsd::Helper::stats_inc(
            'event.identity_verification.request',
            {
                tags => [@common_datadog_tags],
            });
    } catch ($e) {
        if (blessed($e) and $e->isa('Future::Exception')) {
            my ($payload) = $e->details;

            $idv_model->update_document_check({
                document_id => $document->{id},
                status      => IDV_DOCUMENT_STATUS->{failed},
                messages    => [IDV_MESSAGES->{UNAVAILABLE_MICROSERVICE}],
                provider    => $provider,
            });

            $log->error('Identity Verification Microservice responded an error to our request for verify document: %d', $payload->status);
        } elsif ($e =~ /\bconnection refused\b/i) {

            # Give back a submission attempt
            $idv_model->decr_submissions();

            $log->error('Identity Verification Microservice is refusing connections');

            $idv_model->update_document_check({
                document_id => $document->{id},
                status      => IDV_DOCUMENT_STATUS->{failed},
                messages    => [IDV_MESSAGES->{CONNECTION_REFUSED}],
                provider    => $provider,
            });
        } else {
            $idv_model->update_document_check({
                document_id => $document->{id},
                status      => IDV_DOCUMENT_STATUS->{failed},
                messages    => [IDV_MESSAGES->{UNAVAILABLE_MICROSERVICE}],
                provider    => $provider,
            });

            $log->errorf('An error occurred while triggering IDV for document %s associated by client %s via provider %s due to %s',
                $document->{id}, $loginid, $provider, $e);
        }

        exception_logged();
    }

    return 1;
}

=head2 verify_process

Handle side-effects for identity verification
for given client.

=over 4

=item * C<$id> - the client's loginid returned by the IDV microservice, in fact this corresponds to whatever profile.id is sent at the verification request.

=item * C<$status> - status from idv provider

=item * C<$messages> - an array of messages (strings) coming from the provider

=item * C<$report> - report from the IDV provider containing info details such as the DOB, name, etc.

=item * C<$response_body> - raw response body from the provider

=item * C<$request_body> - raw request body to the provider

=back

Returns 1 on sucess or undef on error

=cut

async sub verify_process {
    my $args = shift;

    my ($loginid, $status, $messages, $report, $response_body, $request_body) =
        @{$args}{qw/id status messages report response_body request_body/};

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

    my $selfie;
    my $document_pic;

    $selfie       = delete $report->{selfie}   if ref($report) eq 'HASH';
    $document_pic = delete $report->{document} if ref($report) eq 'HASH';

    my $selfie_file_id;
    my $document_file_id;

    $selfie_file_id = await _upload_photo({
            photo    => $selfie,
            client   => $client,
            status   => $status,
            document => $document,
        }) if $selfie;

    $document_file_id = await _upload_photo({
            photo    => $document_pic,
            client   => $client,
            status   => $status,
            document => $document,
        }) if $document_pic;

    my $callback = RESULT_STATUS->{$status} // RESULT_STATUS->{failed};
    my $pictures = [grep { $_ } ($document_file_id, $selfie_file_id)];

    await $callback->({
        client              => $client,
        document            => $document,
        provider            => $provider,
        report              => $report,
        messages            => $messages,
        status              => $status,
        response_body       => $response_body,
        request_body        => $request_body,
        common_datadog_tags => \@common_datadog_tags,
        pictures            => scalar @$pictures ? $pictures : undef,
        errors              => _messages_to_hashref(@$messages),
    });

    BOM::Platform::Event::Emitter::emit(
        'sync_mt5_accounts_status',
        {
            binary_user_id => $client->binary_user_id,
            client_loginid => $client->loginid
        });

    return 1;
}

=head2 idv_verified

Verified Result Status for IDV, when the document was cleared

=cut

async sub idv_verified {
    my ($args) = @_;

    my ($client, $messages, $document, $provider, $report, $response_body, $request_body, $pictures) =
        @{$args}{qw/client messages document provider report response_body request_body pictures/};
    my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->binary_user_id);

    $client->propagate_clear_status('poi_name_mismatch');
    $client->propagate_clear_status('poi_dob_mismatch');

    if (any { $_ eq IDV_MESSAGES->{ADDRESS_VERIFIED} } @$messages) {
        $client->set_authentication('IDV', {status => IDV_DOCUMENT_STATUS->{pass}});
        $client->status->clear_unwelcome;
    } elsif ($pictures && scalar @$pictures) {
        $client->set_authentication('IDV_PHOTO', {status => IDV_DOCUMENT_STATUS->{pass}});
    }
    my $redis_events_write = _redis_events_write();
    await $redis_events_write->connect;

    await BOM::Event::Actions::Common::set_age_verification($client, $provider, $redis_events_write, 'idv');

    $idv_model->update_document_check({
            document_id => $document->{id},
            status      => IDV_DOCUMENT_STATUS->{verified},
            provider    => $provider,
            messages    => [uniq @$messages],
            photo       => $pictures,
            response_hash_destructuring({
                    response_body => $response_body,
                    request_body  => $request_body,
                    report        => $report,
                }
            )->%*,
        });
}

=head2 idv_refuted

Refuted Result Status for IDV, when the document was rejected 

=cut

async sub idv_refuted {
    my ($args) = @_;

    my ($client, $document, $provider, $messages, $report, $request_body, $response_body, $pictures, $errors) =
        @{$args}{qw/client document provider messages report request_body response_body pictures errors/};

    my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->binary_user_id);
    push $messages->@*,
        _resolve_error_messages({
            client => $client,
            errors => $errors,
        });

    $messages = [uniq @$messages];

    _apply_side_effects({
        client   => $client,
        messages => $messages,
        provider => $provider,
    });

    $idv_model->update_document_check({
            document_id => $document->{id},
            status      => IDV_DOCUMENT_STATUS->{refuted},
            messages    => [uniq @$messages],
            provider    => $provider,
            photo       => $pictures,
            response_hash_destructuring({
                    response_body => $response_body,
                    request_body  => $request_body,
                    report        => $report,
                }
            )->%*,
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

    my ($client, $document, $provider, $messages, $report, $request_body, $response_body, $common_datadog_tags) =
        @{$args}{qw/client document provider messages report request_body response_body common_datadog_tags/};

    my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->binary_user_id);

    DataDog::DogStatsd::Helper::stats_inc(
        'event.identity_verification.failure',
        {
            tags => [@$common_datadog_tags, sprintf('message:%s', $messages->[0] // IDV_MESSAGES->{UNKNOWN}),],
        });

    $idv_model->update_document_check({
            document_id => $document->{id},
            status      => IDV_DOCUMENT_STATUS->{failed},
            messages    => $messages,
            provider    => $provider,
            response_hash_destructuring({
                    response_body => $response_body,
                    request_body  => $request_body,
                    report        => $report,
                }
            )->%*,
        });

    $log->infof('Identity verification for document %s via provider %s get failed due to %s', $document->{id}, $provider, $messages);
}

=head2 idv_pending

Pending Result Status, left the check hanging in the pending status.

=cut

async sub idv_pending {
    my ($args) = @_;

    my ($client, $document, $provider, $messages, $report, $request_body, $response_body) =
        @{$args}{qw/client document provider messages report request_body response_body/};

    my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->binary_user_id);

    $idv_model->update_document_check({
            document_id => $document->{id},
            status      => IDV_DOCUMENT_STATUS->{pending},
            messages    => $messages,
            provider    => $provider,
            response_hash_destructuring({
                    response_body => $response_body,
                    request_body  => $request_body,
                    report        => $report,
                }
            )->%*,
        });
}

=head2 idv_mismatch_lookback

To check if a name or DOB mismatch has been resolved.

=cut

async sub idv_mismatch_lookback {
    my ($args) = @_;

    my ($client, $document, $report, $messages) = @{$args}{qw/client document report messages/};

    my $rule_engine = BOM::Rules::Engine->new(
        client          => $client,
        residence       => $client->residence,
        stop_on_failure => 0
    );

    my $rules_result = $rule_engine->verify_action(
        'idv_mismatch_lookback',
        loginid  => $client->loginid,
        result   => $report,
        document => $document,
    );

    $messages = [grep { $_ ne 'NAME_MISMATCH' } $messages->@*] unless $rules_result->errors->{NameMismatch};
    $messages = [grep { $_ ne 'DOB_MISMATCH' } $messages->@*]  unless $rules_result->errors->{DobMismatch};

    unless ($rules_result->has_failure) {
        await idv_verified({$args->%*, messages => $messages});
    } else {
        $client->propagate_clear_status('poi_name_mismatch') unless $rules_result->errors->{NameMismatch};
        $client->propagate_clear_status('poi_dob_mismatch')  unless $rules_result->errors->{DobMismatch};
        await idv_refuted({$args->%*, messages => $messages, errors => $rules_result->errors});
    }

    return undef;
}

=head2 idv_callback

Callback Result Status, to set status as deferred in DB when calling IDV

=cut

async sub idv_callback {
    my ($args) = @_;

    my ($client, $document, $provider, $messages, $report, $request_body, $response_body) =
        @{$args}{qw/client document provider messages report request_body response_body/};
    my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->binary_user_id);

    $idv_model->update_document_check({
            document_id => $document->{id},
            status      => IDV_DOCUMENT_STATUS->{deferred},
            messages    => $messages,
            provider    => $provider,
            response_hash_destructuring({
                    response_body => $response_body,
                    request_body  => $request_body,
                    report        => $report,
                }
            )->%*,
        });
}

=head2 _messages_to_hashref

Given a list of error messages, map them into a hashref that is rule engine output equivalent.

=cut

sub _messages_to_hashref {
    return +{map { exists IDV_ERROR_MAPPING->{$_} ? (IDV_ERROR_MAPPING->{$_} => 1) : () } @_};
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
            push @messages, IDV_MESSAGES->{NAME_MISMATCH};
        }

        if (exists $errors->{UnderAge}) {
            push @messages, IDV_MESSAGES->{UNDERAGE};

        }

        if (exists $errors->{DobMismatch}) {
            push @messages, IDV_MESSAGES->{DOB_MISMATCH};
        }
    } else {
        push @messages, IDV_MESSAGES->{EXPIRED};
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

    unless (any { $_ eq IDV_MESSAGES->{EXPIRED} } $messages->@*) {
        if (any { $_ eq IDV_MESSAGES->{NAME_MISMATCH} } $messages->@*) {
            $client->propagate_status('poi_name_mismatch', 'system', "Client's name doesn't match with provided name by $provider");
            $clear_age_verification = 1;
        }

        if (any { $_ eq IDV_MESSAGES->{UNDERAGE} } $messages->@*) {
            BOM::Event::Actions::Common::handle_under_age_client($client, $provider);
            $clear_age_verification = 1;
            BOM::User::IdentityVerification::reset_to_zero_left_submissions($client->binary_user_id);    # no second attempts allowed
        }

        if (any { $_ eq IDV_MESSAGES->{DOB_MISMATCH} } $messages->@*) {
            $client->propagate_status('poi_dob_mismatch', 'system', "Client's DOB doesn't match with provided DOB by $provider");
            $clear_age_verification = 1;
        }

    } else {
        $clear_age_verification = 1;
    }

    $client->propagate_clear_status('age_verification') if $clear_age_verification;
    return undef;
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

    my ($response, $idv_retry_response, $decoded_response, $webhook_response, $login_id, $status, $report, $response_body, $request_body);

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

        # silently ignore invalid webhook requests
        if (!defined $webhook_response->{req_echo}) {
            DataDog::DogStatsd::Helper::stats_inc('event.identity_verification.invalid_webhook_callback');
            return;
        }

        $status         = $webhook_response->{status};
        $status_message = $webhook_response->{messages};
        $login_id       = $webhook_response->{req_echo}->{profile}->{id};
        $report         = $webhook_response->{report};
        $request_body   = $webhook_response->{request_body};
        $response_body  = $webhook_response->{response_body};

        await verify_process({
            id            => $login_id,
            status        => $status,
            messages      => $status_message,
            report        => $report        && ref($report)        ? $report        : {},
            request_body  => $request_body  && ref($request_body)  ? $request_body  : {},
            response_body => $response_body && ref($response_body) ? $response_body : {},
        });
    } catch ($e) {
        if (blessed($e) and $e->isa('Future::Exception')) {
            my ($payload) = $e->details;
            $response = $payload->content;

            $webhook_response = eval { decode_json_utf8 $response } // {};

            $status = IDV_DOCUMENT_STATUS->{failed};

            $status_message = $log->errorf(
                "Identity Verification Microservice responded an error to our request for passing the webhook response with code: %s, message: %s - %s",
                $webhook_response->{code} // IDV_MESSAGES->{UNKNOWN},
                $e->message, $webhook_response->{error} // IDV_MESSAGES->{UNKNOWN});
        } elsif ($e =~ /\bconnection refused\b/i) {

            # Update the status to failed as for it to not remain in perpetual 'pending' state
            $status         = IDV_DOCUMENT_STATUS->{failed};
            $status_message = IDV_MESSAGES->{CONNECTION_REFUSED};

        } else {
            $log->errorf('Unhandled IDV exception: %s', $e);
        }
    }

    unless ($status) {
        $status         = IDV_DOCUMENT_STATUS->{failed};
        $status_message = IDV_MESSAGES->{UNAVAILABLE_MICROSERVICE};
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

    my $final_status = DOCUMENT_UPLOAD_STATUS->{$status} // DOCUMENT_UPLOAD_STATUS->{uploaded};

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

=head2 response_hash_destructuring

This method takes the response hash from IDV and returns a json encoded hashref of:

=over 4

=item * C<response_body> - the body response received from the IDV provider

=item * C<request_body> - the request body sent to the IDV provider

=item * C<report> - the standarized IDV report

=item * C<expiration_date> - taken from the report if existing.

=back

Return a hashref with the described structure.

=cut

sub response_hash_destructuring {
    my ($hash) = @_;
    my ($response_body, $request_body, $report) = @{$hash}{qw/response_body request_body report/};
    my $expiration_date;

    if ($report && ref($report) eq 'HASH') {
        $expiration_date = $report->{expiry_date};
    }

    return {
        report          => $report        && ref($report)        ? encode_json_text($report)        : undef,
        request_body    => $request_body  && ref($request_body)  ? encode_json_text($request_body)  : undef,
        response_body   => $response_body && ref($response_body) ? encode_json_text($response_body) : undef,
        expiration_date => $expiration_date,
    };
}

1
