package BOM::Event::Actions::Client::IdentityVerification;

use strict;
use warnings;
no indirect;

=head1 NAME

BOM::Event::Actions::Client::IdentityVerification

=head1 DESCRIPTION

Provides handlers for ID verification events 

=cut

use Brands::Countries;
use Crypt::OpenSSL::RSA;
use Data::UUID;
use Date::Utility;
use Digest::SHA qw( sha256_hex );
use Future::AsyncAwait;
use IO::Async::Loop;
use JSON::MaybeUTF8 qw( decode_json_utf8  encode_json_utf8 );
use List::Util qw( any uniq );
use Log::Any qw( $log );
use MIME::Base64 qw( decode_base64  encode_base64 );
use Scalar::Util qw( blessed );
use Syntax::Keyword::Try;
use Text::Trim;
use URL::Encode qw(url_encode);

use BOM::Config;
use BOM::Config::Runtime;
use BOM::Config::Services;
use BOM::Event::Services;
use BOM::Event::Services::Track;
use BOM::Event::Utility qw( exception_logged );
use BOM::Platform::Context qw( localize request );
use BOM::Platform::Utility;
use BOM::User::IdentityVerification;
use BOM::User::Client;
use BOM::Platform::Client::IdentityVerification;
use Brands::Countries;

use constant SELFISH_PROVIDERS => ['zaig'];    # List of providers who don't give us user personal data and just evaluate documents on their own.

use constant TRIGGER_MAP => {
    smile_identity => \&_trigger_smile_identity,
    zaig           => \&_trigger_zaig,
    microservice   => \&_trigger_through_microservice,
};

use constant RESULT_STATUS => {
    pass   => 'pass',
    verify => 'verified',
    fail   => 'failed',
    reject => 'refuted',
    n_a    => 'unavailable',
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

Returns undef.

=cut

async sub verify_identity {
    my $args = shift;

    my ($loginid) = @{$args}{qw/loginid/};

    my $client = BOM::User::Client->new({loginid => $loginid})
        or die 'Could not instantiate client for login ID: ' . $loginid;

    my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->binary_user_id);

    die sprintf("No submissions left, IDV request has ignored for loginid: %s", $client->loginid) unless $idv_model->submissions_left($client);

    my $document = $idv_model->get_standby_document();

    die 'No standby document found.' unless $document;

    my $provider = _get_provider($client, $document);

    return undef if $provider eq 'onfido';

    die $log->errorf('Could not trigger IDV, the function for provider %s not found.', $provider) unless exists TRIGGER_MAP->{$provider};

    try {
        $log->debugf('Start triggering identity verification service (via %s) for document %s associated by loginID %s',
            $provider, $document->{id}, $loginid);

        $idv_model->incr_submissions();

        my @result = await TRIGGER_MAP->{_is_microservice_available($provider) ? 'microservice' : $provider}(
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

        my ($status, $response_hash, $message) = @result;

        my $provider_request_body  = $response_hash->{request_body}  // {};
        my $provider_response_body = $response_hash->{response_body} // {};

        my $transformed_resp = BOM::Platform::Client::IdentityVerification::transform_response($provider, $provider_response_body) // $response_hash;

        # Some of providers like Zaig and IDV microservice might return an array of messages.
        my @messages = ref $message eq 'ARRAY' ? $message->@* : ($message);

        my $refuted_document_handler = sub {
            my ($errors) = @_;

            push @messages,
                _apply_side_effects({
                    client   => $client,
                    errors   => $errors,
                    provider => $provider,
                });
            @messages = uniq @messages;

            $idv_model->update_document_check({
                document_id     => $document->{id},
                status          => 'refuted',
                expiration_date => $transformed_resp->{expiration_date},
                messages        => \@messages,
                provider        => $provider,
                request_body    => encode_json_utf8($provider_request_body),
                response_body   => encode_json_utf8($provider_response_body),
            });

            BOM::Event::Services::Track::track_event(
                event      => 'identity_verification_rejected',
                loginid    => $client->loginid,
                properties => {
                    authentication_url => request->brand->authentication_url,
                    live_chat_url      => request->brand->live_chat_url,
                    title              => localize('We were unable to verify your document details'),
                },
            );
        };

        my $verified_document_handler = sub {
            $client->status->clear_poi_name_mismatch;

            BOM::Event::Actions::Common::set_age_verification($client, $provider);

            $idv_model->update_document_check({
                document_id     => $document->{id},
                status          => 'verified',
                provider        => $provider,
                expiration_date => $transformed_resp->{expiration_date},
                request_body    => encode_json_utf8($provider_request_body),
                response_body   => encode_json_utf8($provider_response_body),
            });
        };

        my $rule_engine_handler = sub {
            my $rule_engine = BOM::Rules::Engine->new(
                client          => $client,
                residence       => $client->residence,
                stop_on_failure => 0
            );

            my $rules_result = $rule_engine->verify_action(
                'identity_verification',
                loginid  => $client->loginid,
                result   => $transformed_resp,
                document => $document,
            );

            unless ($rules_result->has_failure) {
                $verified_document_handler->();
            } else {
                $refuted_document_handler->($rules_result->errors);
            }
        };

        if ($status eq RESULT_STATUS->{pass}) {
            $rule_engine_handler->();
        } elsif ($status eq RESULT_STATUS->{verify}) {
            if (any { $provider eq $_ } SELFISH_PROVIDERS->@*) {
                $verified_document_handler->();
            } else {
                $rule_engine_handler->();
            }
        } elsif ($status eq RESULT_STATUS->{reject}) {
            $refuted_document_handler->(_messages_to_hashref(@messages));
        } else {
            $idv_model->update_document_check({
                document_id   => $document->{id},
                status        => 'failed',
                messages      => \@messages,
                provider      => $provider,
                request_body  => encode_json_utf8($provider_request_body),
                response_body => encode_json_utf8($provider_response_body),
            });

            $log->debugf('Identity verification for document %s via provider %s get failed due to %s', $document->{id}, $provider, \@messages);
        }
    } catch ($e) {
        $log->errorf('An error occurred while triggering IDV for document %s associated by client %s via provider %s due to %s',
            $document->{id}, $loginid, $provider, $e);

        exception_logged();

        die $e;    # Keeps event in the queue.
    }

    return 1;
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

=head2 _trigger_through_microservice

Triggers given provider through IDV microservice.

=over 4

=item * C<client> - the client instance

=item * C<docuemnt> - the standby document

=item * C<before_request_hook> - a annonymous subroutine that going to be called right before sending requests and accept the request body.

=item * C<provider> - The provider name

=back

Returns an array includes (status, request + response, status message).

=cut

async sub _trigger_through_microservice {
    my ($client, $document, $before_request_hook) = @_;

    my $config = BOM::Config::Services->config('identity_verification');

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
        }};

    my $response         = undef;
    my $decoded_response = undef;

    my $status         = undef;
    my $status_message = [];

    $before_request_hook->($req_body);

    my $url = "$api_base_url/v1/idv";

    try {
        $response = (await _http()->POST($url, $req_body, (content_type => 'application/json')))->content;

        $decoded_response = eval { decode_json_utf8 $response } // {};

        $status         = $decoded_response->{status};
        $status_message = $decoded_response->{messages};
    } catch ($e) {
        if (blessed($e) and $e->isa('Future::Exception')) {
            my ($payload) = $e->details;
            $response = $payload->content;

            $decoded_response = eval { decode_json_utf8 $response } // {};

            $status = RESULT_STATUS->{fail};

            $status_message = $log->errorf(
                "Identity Verification Microservice responded an error to our request for verify document %s with code: %s, message: %s - %s",
                $document->{id}, $decoded_response->{code} // 'UNKNOWN',
                $e->message, $decoded_response->{error} // 'UNKNOWN'
            );
        }
    }

    unless ($status) {
        $status         = RESULT_STATUS->{fail};
        $status_message = 'UNAVAILABLE_MICROSERVICE';
    }

    return ($status, $decoded_response, $status_message);
}

=head2 _trigger_smile_identity

Triggers Smile Identity to verify identity of clients
placed in the (Ghana, Kenya, South Africa, Nigeria).

=over 4

=item * C<client> - the client instance

=item * C<docuemnt> - the standby document

=item * C<before_request_hook> - a annonymous subroutine that going to be called right before sending requests and accept the request body.

=back

Returns an array includes (status, json decoded response, status message).

=cut

async sub _trigger_smile_identity {
    my ($client, $document, $before_request_hook) = @_;

    my $config = BOM::Config::third_party()->{smile_identity};

    my $api_base_url = $config->{api_url}    // '';
    my $api_key      = $config->{api_key}    // '';
    my $partner_id   = $config->{partner_id} // '';

    my $ts = time;

    my $country   = uc $document->{issuing_country};
    my $id_number = $document->{document_number};
    my $id_type   = uc $document->{document_type};

    my $job_type = 5;                               # based on Smile Identity documentation
    my $job_id   = Data::UUID->new->create_str();

    my $dob = eval { Date::Utility->new($client->date_of_birth)->date_yyyymmdd };

    my $req_body_object = {
        partner_id     => "$partner_id",
        sec_key        => _generate_smile_identity_secret_key($api_key, $partner_id, $ts),
        timestamp      => $ts,
        country        => $country,
        id_type        => $id_type,
        id_number      => $id_number,
        first_name     => $client->first_name,
        last_name      => $client->last_name,
        dob            => $dob,
        partner_params => {
            job_type => $job_type,
            job_id   => $job_id,
            user_id  => trim(encode_base64($client->loginid)),
        },
    };
    my $req_body = encode_json_utf8 $req_body_object;

    my $response         = undef;
    my $decoded_response = undef;
    my $status           = undef;
    my $status_message   = '';

    $before_request_hook->($req_body);

    my $url = "$api_base_url/id_verification";

    $log->tracef("SmileIdentitiy verify: POST %s %s", $url, $req_body);

    try {
        $response = (await _http()->POST($url, $req_body, (content_type => 'application/json')))->content;

        $decoded_response = _shrink_smile_identity(eval { decode_json_utf8 $response });

        ($status, $status_message) = _handle_smile_identity_response($client, $decoded_response);
    } catch ($e) {
        if (blessed($e) and $e->isa('Future::Exception')) {
            my ($payload) = $e->details;
            $response = $payload->content;

            $decoded_response = eval { decode_json_utf8 $response } // {};

            $status         = RESULT_STATUS->{fail};
            $status_message = sprintf(
                "SmileIdentity responded an error to our request for verify document %s with code: %s, message: %s - %s",
                $document->{id}, $decoded_response->{code} // 'UNKNOWN',
                $e->message, $decoded_response->{error} // 'UNKNOWN'
            );

            $status_message = $log->error($status_message);
        }
    }

    my $request_summary = {
        request_body  => $req_body_object,
        response_body => $decoded_response,
    };

    return ($status, $request_summary, $status_message);
}

=head2 _shrink_smile_identity

Slices the hashref response from smile identity, it will wipe out everything but the required fields
to process the IDV.

=cut

sub _shrink_smile_identity {
    my ($decoded_response) = @_;

    return +{%$decoded_response{qw/ResultCode Actions ExpirationDate DOB FullName SmileJobID/}};
}

=head2 _trigger_zaig

Triggers Zaig to verify identity of clients
who provide documents issued in Brazil.

=over 4

=item * C<client> - the client instance

=item * C<docuemnt> - the standby document

=item * C<before_request_hook> - a annonymous subroutine that going to be called right before sending requests and accept the request body.

=back

Returns an array of status, decoded response and status message.

=cut

async sub _trigger_zaig {
    my ($client, $document, $before_request_hook) = @_;

    my $config = BOM::Config::third_party()->{zaig};

    my $api_base_url = $config->{api_url}       // '';
    my $api_key      = $config->{api_key}       // '';
    my $prefix       = $config->{api_id_prefix} // '';

    my $document_number     = $document->{document_number};
    my $encoded_document_id = trim(encode_base64($document->{id}));

    my $response         = undef;
    my $decoded_response = undef;

    my $status         = undef;
    my $status_message = undef;
    my $prefixed_id    = $prefix . $encoded_document_id;

    my $submit_req_body_object = {
        id                => $prefixed_id,
        registration_id   => trim(encode_base64($client->loginid)),
        document_number   => $document_number,
        registration_date => Date::Utility->new->datetime_iso8601,
        name              => join(' ', $client->first_name, $client->last_name),
        birthdate         => Date::Utility->new($client->date_of_birth)->date_yyyymmdd,
    };
    my $submit_req_body = encode_json_utf8 $submit_req_body_object;

    $before_request_hook->($submit_req_body);

    my $submit_url              = "$api_base_url/natural_person?analyze=true";
    my $url_encoded_document_id = url_encode($prefixed_id);
    my $detail_url              = "$api_base_url/natural_person/$url_encoded_document_id";

    $log->tracef("Zaig verify: POST %s %s", $submit_url, $submit_req_body);

    try {
        # Make the POST request, we are not interested in the response just yet.
        await _http()->POST(
            $submit_url,
            $submit_req_body,
            (
                content_type => 'application/json',
                headers      => {
                    Authorization => $api_key,
                }));
    } catch ($e) {
        if (blessed($e) and $e->isa('Future::Exception')) {
            my ($payload) = $e->details;

            # If status code 400 then the cpf sent was invalid
            if ($payload->code == 400) {
                $status_message = 'DOCUMENT_REJECTED';
                $status         = RESULT_STATUS->{fail};
                BOM::User::IdentityVerification::reset_to_zero_left_submissions($client->binary_user_id);

                return ($status, $decoded_response, $status_message);
            }

            # Conflict 429 status code means the document id was requested before,
            # we can proceed with the check regardless.

            unless ($payload->code == 429) {
                $response = $payload->content;

                $decoded_response = eval { decode_json_utf8 $response } // {};

                $status_message = sprintf(
                    "Zaig respond an error to our request with title: %s, description: %s",
                    $decoded_response->{title}       // 'UNKNOWN',
                    $decoded_response->{description} // 'UNKNOWN'
                );
                $status = RESULT_STATUS->{fail};

                return ($status, $decoded_response, $status_message);
            }
        }
    }

    try {
        # Make a GET response to pull the actual data
        $response = (
            await _http()->GET(
                $detail_url,
                (
                    content_type => 'application/json',
                    headers      => {
                        Authorization => $api_key,
                    })))->content;

        $decoded_response = _shrink_zaig_response(eval { decode_json_utf8 $response });

        #inject data from the client itself (zaig does not provide this)
        $decoded_response->{name}      = join(' ', $client->first_name, $client->last_name);
        $decoded_response->{birthdate} = Date::Utility->new($client->date_of_birth)->date_yyyymmdd;
        ($status, $status_message) = _handle_zaig_response($client, $decoded_response);
    } catch ($e) {
        $status = RESULT_STATUS->{fail};
        if (blessed($e) and $e->isa('Future::Exception')) {
            my ($payload) = $e->details;
            $response = $payload->content;

            $decoded_response = eval { decode_json_utf8 $response } // {};

            $status_message = sprintf(
                "Zaig respond an error to our request with title: %s, description: %s",
                $decoded_response->{title}       // 'UNKNOWN',
                $decoded_response->{description} // 'UNKNOWN'
            );
        } else {
            $status_message = 'An unknown error happened.';
        }
    }

    my $request_summary = {
        request_body  => $submit_req_body_object,
        response_body => $decoded_response,
    };

    return ($status, $request_summary, $status_message);
}

=head2 _shrink_zaig_response

Reduces the hashref gotten from Zaig. Lefts only the needed fields for processing.

=cut

sub _shrink_zaig_response {
    my ($decoded_response) = @_;

    return +{%$decoded_response{qw/analysis_status analysis_status_events name birthdate natural_person_key/}};
}

=head2 _handle_smile_identity_response

Handle the response of smile_identity api

=over 4

=item * C<$response_hash> - A hashref of response

=back

Returns an array contains status and message.

=cut

sub _handle_smile_identity_response {
    my ($client, $response_hash) = @_;

    if ($response_hash->{ResultCode}) {
        my @foul_codes = (
            1022,    # No match
            1013,    # Invalid ID
        );
        BOM::User::IdentityVerification::reset_to_zero_left_submissions($client->binary_user_id)
            if any { $_ == $response_hash->{ResultCode} } @foul_codes;
    }

    my %verification_status_map = (
        'Verified'           => 'verify',
        'Not Verified'       => 'fail',
        'Issuer Unavailable' => 'unavailable',
        'N/A'                => 'unavailable',
    );

    my ($status, $status_message);

    unless ($response_hash) {
        $status         = RESULT_STATUS->{fail};
        $status_message = $log->errorf("SmileIdentity responded to our request for verify document associated by client %s with an invalid JSON.",
            $client->loginid);
        return ($status, $status_message);
    } else {
        my $verify_status = $response_hash->{Actions}->{Verify_ID_Number} // 'unavailable';

        unless (exists $verification_status_map{$verify_status}) {
            $status         = RESULT_STATUS->{n_a};
            $status_message = 'EMPTY_STATUS';
            return ($status, $status_message);
        }

        if ($verification_status_map{$verify_status} eq 'unavailable') {
            $status         = RESULT_STATUS->{n_a};
            $status_message = $verify_status eq 'N/A' ? 'UNAVAILABLE_STATUS' : 'UNAVAILABLE_ISSUER';
            return ($status, $status_message);
        }

        my $personal_info_returned = $response_hash->{Actions}->{Return_Personal_Info} eq 'Returned';
        if ($verification_status_map{$verify_status} eq 'verify') {
            if ($personal_info_returned) {
                $status = RESULT_STATUS->{verify};
            } else {
                $status         = RESULT_STATUS->{n_a};
                $status_message = 'INFORMATION_LACK';
            }

            return ($status, $status_message);
        }

        if ($verification_status_map{$verify_status} eq 'fail') {
            $status         = RESULT_STATUS->{reject};
            $status_message = 'DOCUMENT_REJECTED';
            return ($status, $status_message);
        }
    }
}

=head2 _handle_zaig_response

Process the Zaig payload returned, generating a status a status message couple.

Keep in mind, due to regulations, Zaig cannot bring personal info of the client, instead they
will let us know whether they were matches or not, we need to extract this output and adjust 

=cut

sub _handle_zaig_response {
    my ($client, $response_hash) = @_;

    my %verification_status_map = (
        automatically_approved => 'verify',
        automatically_reproved => 'reject',
        in_manual_analysis     => 'n_a',
        manually_approved      => 'verify',
        manually_reproved      => 'reject',
        pending                => 'n_a',
        not_analysed           => 'n_a',
    );

    my ($status, $status_message);

    unless ($response_hash) {
        $status         = RESULT_STATUS->{fail};
        $status_message = $log->errorf("Zaig response is not a valid JSON.");
    } else {
        my $verify_status = $response_hash->{analysis_status} // 'not_analysed';

        unless (exists $verification_status_map{$verify_status}) {
            $status         = RESULT_STATUS->{n_a};
            $status_message = 'UNAVAILABLE_STATUS';
            return ($status, $status_message);
        }

        my $result_key = $verification_status_map{$verify_status};
        $status         = RESULT_STATUS->{$result_key};
        $status_message = 'EMPTY_STATUS';

        if ($result_key eq 'verify') {
            return (RESULT_STATUS->{verify}, undef);
        } elsif ($result_key eq 'reject') {
            # Zaig should've performed the verification itself so we just need to grab the results
            # and push the statuses.

            # The IDV framework would expect an arrayref when dealing with errors instead of single
            # string message.

            my $statuses               = [];
            my $analysis_status_events = $response_hash->{analysis_status_events} // [];
            my $last_event             = shift $analysis_status_events->@*;
            my $results                = $last_event->{analysis_output}->{basic_data} // {};
            my $reason                 = $last_event->{analysis_output}->{reason}     // '';

            my $name_result      = $results->{name}->{description}      // '';
            my $birthdate_result = $results->{birthdate}->{description} // '';

            push $statuses->@*, 'NAME_MISMATCH'     if $name_result eq 'name_mismatch';
            push $statuses->@*, 'DOB_MISMATCH'      if $birthdate_result eq 'birthdate_mismatch';
            push $statuses->@*, 'DOCUMENT_REJECTED' if $reason eq 'document_not_found';
            push $statuses->@*, 'UNDERAGE'          if $reason =~ /underage/;
            push $statuses->@*, 'DECEASED'          if $reason eq 'deceased_person';

            if (scalar $statuses->@*) {
                BOM::User::IdentityVerification::reset_to_zero_left_submissions($client->binary_user_id);
                return (RESULT_STATUS->{reject}, $statuses);
            }
        }
    }
    return ($status, $status_message);
}

=head2 _get_provider

Find IDV service provider based on 
client's document issuer country.

=over 4

=item * C<client> - the client instance

=back

Returns string.

=cut

sub _get_provider {
    my ($client, $document) = @_;

    my $country_configs = Brands::Countries->new();
    my $country         = $document->{issuing_country};
    my $idv_config      = $country_configs->get_idv_config($country);
    return 'onfido' unless BOM::Platform::Utility::has_idv(
        country  => $country,
        provider => $idv_config->{provider});
    return $idv_config->{provider};
}

=head2 _generate_smile_identity_secret_key

Generate a secret key based on SmileIdentity instructions

=over 4

=item * C<$api_key> - a base64 encoded token provided by SmileID

=item * C<$partner_id> - a 4-digit number provided by SmileID

=item * C<$timestamp> - The current timestamp

=back

Returns token.

=cut

sub _generate_smile_identity_secret_key {
    my ($api_key, $partner_id, $timestamp) = @_;

    return 'dummy' unless BOM::Config::on_production() or $api_key;

    $partner_id = 0 + $partner_id;

    my $payload         = join ':', $partner_id, $timestamp;
    my $hash            = sha256_hex($payload);
    my $decoded_api_key = decode_base64($api_key);
    my $rsa_pub         = Crypt::OpenSSL::RSA->new_public_key($decoded_api_key);
    $rsa_pub->use_pkcs1_padding();

    my $encrypted = $rsa_pub->encrypt($hash);
    my $base64    = encode_base64($encrypted, '');

    return join '|', $base64, $hash;
}

=head2 _is_microservice_available

Checks several parameters whether the microservice is up and eligible to process the request or not

=over 4

=item * C<provider> - The provider name that microservice should handle

=back

Returns bool

=cut

sub _is_microservice_available {
    my ($provider) = @_;

    my $enabled = BOM::Config::Services->is_enabled('identity_verification');

    my $app_cfg = BOM::Config::Runtime->instance->app_config;
    $app_cfg->check_for_update;

    my $provider_supported = any { $_ eq $provider } $app_cfg->system->suspend->idv_legacy_providers->@*;

    return $enabled && $provider_supported;
}

1
