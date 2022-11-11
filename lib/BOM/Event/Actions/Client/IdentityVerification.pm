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

use BOM::Config::Services;
use BOM::Event::Services;
use BOM::Event::Services::Track;
use BOM::Event::Utility    qw( exception_logged );
use BOM::Platform::Context qw( localize request );
use BOM::Platform::Utility;
use BOM::User::IdentityVerification;
use BOM::User::Client;

use constant RESULT_STATUS => {
    pass     => \&idv_pass,
    verified => \&idv_verified,
    failed   => \&idv_failed,
    refuted  => \&idv_refuted,
    callback => \&idv_callback,
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

    my $provider = _get_provider($document->{issuing_country});

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

    my $provider = _get_provider($document->{issuing_country});

    return undef unless $provider;

    my @common_datadog_tags = (sprintf('provider:%s', $provider), sprintf('country:%s', $document->{issuing_country}));

    my @messages = ref $message eq 'ARRAY' ? $message->@* : ($message // ());

    @messages = uniq @messages;

    my $callback = RESULT_STATUS->{$status} // RESULT_STATUS->{failed};

    await $callback->({
        client              => $client,
        messages            => [@messages],
        document            => $document,
        provider            => $provider,
        response_hash       => $response_hash,
        common_datadog_tags => [@common_datadog_tags],
        errors              => _messages_to_hashref(@messages),
    });

    return 1;
}

=head2 idv_verified

Verified Result Status for IDV, when the document was cleared

=cut

async sub idv_verified {
    my ($args) = @_;

    my ($client, $messages, $document, $provider, $response_hash) = @{$args}{qw/client messages document provider response_hash/};
    my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->binary_user_id);

    $client->status->clear_poi_name_mismatch;

    if (any { $_ eq 'ADDRESS_VERIFIED' } @$messages) {
        $client->set_authentication('IDV', {status => 'pass'});
        $client->status->clear_unwelcome;
    }

    BOM::Event::Actions::Common::set_age_verification($client, $provider);

    $idv_model->update_document_check({
        document_id     => $document->{id},
        status          => 'verified',
        provider        => $provider,
        report          => encode_json_text($response_hash->{report} // {}),
        expiration_date => $response_hash->{report}->{expiry_date},
        request_body    => encode_json_text($response_hash->{request_body}  // {}),
        response_body   => encode_json_text($response_hash->{response_body} // {}),
    });
}

=head2 idv_refuted

Refuted Result Status for IDV, when the document was rejected 

=cut

async sub idv_refuted {
    my ($args) = @_;

    my ($client, $document, $provider, $messages, $response_hash, $errors) = @{$args}{qw/client document provider messages response_hash errors/};
    my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->binary_user_id);

    push $messages->@*,
        _apply_side_effects({
            client   => $client,
            errors   => $errors,
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
    });

    await BOM::Event::Services::Track::track_event(
        event      => 'identity_verification_rejected',
        loginid    => $client->loginid,
        properties => {
            authentication_url => request->brand->authentication_url,
            live_chat_url      => request->brand->live_chat_url,
            title              => localize('We were unable to verify your document details'),
        },
    );
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

=head2 _apply_side_effects

Given a hashref of possible validaiton errors, applies the side effects required.

It takes the following arguments as hashref:

=over 4

=item C<client> - the L<BOM::User::Client> instance.

=item C<errors> - the hashref with validations errors to process.

=item C<provider> - the name of the IDV provider.

=back

Returns a list of possible error messages.

=cut

sub _apply_side_effects {
    my $args = shift;
    my ($client, $errors, $provider) = @{$args}{qw/client errors provider/};

    my @messages;

    unless (exists $errors->{Expired}) {
        if (exists $errors->{NameMismatch}) {
            push @messages, "NAME_MISMATCH";

            $client->status->setnx('poi_name_mismatch', 'system', "Client's name doesn't match with provided name by $provider");
        }

        if (exists $errors->{UnderAge}) {
            push @messages, 'UNDERAGE';

            BOM::Event::Actions::Common::handle_under_age_client($client, $provider);
            $client->status->clear_age_verification;
        }

        if (exists $errors->{DobMismatch}) {
            push @messages, 'DOB_MISMATCH';

            $client->status->clear_age_verification;
        }

        BOM::User::IdentityVerification::reset_to_zero_left_submissions($client->binary_user_id);    # no second attempts allowed
    } else {
        push @messages, 'EXPIRED';

        $client->status->clear_age_verification;
    }

    return @messages;
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
        },
        profile => {
            login_id   => $client->loginid,
            first_name => $client->first_name,
            last_name  => $client->last_name,
            birthdate  => $client->date_of_birth,
        },
        address => {
            line_1    => $client->address_line_1,
            line_2    => $client->address_line_2,
            postcode  => $client->address_postcode,
            residence => $client->residence,
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
    my ($issuing_country) = @_;

    my $country_configs = Brands::Countries->new();
    my $idv_config      = $country_configs->get_idv_config($issuing_country);

    return undef unless BOM::Platform::Utility::has_idv(
        country  => $issuing_country,
        provider => $idv_config->{provider});

    return $idv_config->{provider};
}

1
