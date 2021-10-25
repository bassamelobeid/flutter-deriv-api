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
use List::Util qw( any );
use Log::Any qw( $log );
use MIME::Base64 qw( decode_base64  encode_base64 );
use Scalar::Util qw( blessed );
use Syntax::Keyword::Try;
use Text::Trim;

use BOM::Event::Services;
use BOM::Event::Services::Track;
use BOM::Event::Utility qw( exception_logged );
use BOM::Platform::Context qw( localize request );
use BOM::User::IdentityVerification;
use BOM::User::Client;

use Brands::Countries;

use constant TRIGGER_MAP => {
    smile_identity => \&_trigger_smile_identity,
};

use constant TRANSFORMER_MAP => {
    smile_identity => \&_transform_smile_identity_response,
};

use constant RESULT_STATUS => {
    pass   => 'verified',
    fail   => 'failed',
    reject => 'refuted',
    n_a    => 'unavailable',
};

my $loop = IO::Async::Loop->new;
$loop->add(my $services = BOM::Event::Services->new);

{

    sub _http {
        return $services->http();
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

    die "Could not perform triggering, the function for provider $provider not found."
        unless exists TRIGGER_MAP->{$provider};

    try {
        $log->debugf('Start triggering identity verification service (%s) for loginID %s', $provider, $loginid);

        $idv_model->incr_submissions();

        my @result = await TRIGGER_MAP->{$provider}(
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

        my $transformed_resp = $response_hash;
        $transformed_resp = TRANSFORMER_MAP->{$provider}($response_hash) if exists TRANSFORMER_MAP->{$provider};

        if ($status eq RESULT_STATUS->{pass}) {

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
                $client->status->clear_poi_name_mismatch;

                BOM::Event::Actions::Common::set_age_verification($client, $provider);

                $idv_model->update_document_check({
                    document_id     => $document->{id},
                    status          => $status,
                    provider        => $provider,
                    expiration_date => $transformed_resp->{expiration_date},
                    response_body   => encode_json_utf8 $response_hash
                });

            } else {
                my @messages = ();

                if (not exists $rules_result->errors->{Expired}) {
                    if (exists $rules_result->errors->{NameMismatch}) {
                        push @messages, "NAME_MISMATCH";

                        $client->status->setnx('poi_name_mismatch', 'system', "Client's name doesn't match with provided name by $provider");
                    }

                    if (exists $rules_result->errors->{UnderAge}) {
                        push @messages, 'UNDERAGE';

                        BOM::Event::Actions::Common::handle_under_age_client($client, $provider, $transformed_resp->{date_of_birth});
                        $client->status->clear_age_verification;
                    }

                    if (exists $rules_result->errors->{DobMismatch}) {
                        push @messages, 'DOB_MISMATCH';

                        $client->status->clear_age_verification;
                    }

                    BOM::User::IdentityVerification::reset_to_zero_left_submissions($client->binary_user_id);    # no second attempts allowed
                } else {
                    push @messages, 'EXPIRED';

                    $client->status->clear_age_verification;
                }

                $idv_model->update_document_check({
                    document_id     => $document->{id},
                    status          => 'refuted',
                    expiration_date => $transformed_resp->{expiration_date},
                    messages        => \@messages,
                    provider        => $provider,
                    response_body   => encode_json_utf8 $response_hash,
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
            }
        } else {
            $idv_model->update_document_check({
                document_id   => $document->{id},
                status        => 'failed',
                messages      => [$message],
                provider      => $provider,
                response_body => encode_json_utf8 $response_hash
            });

            $log->errorf('Identity verification by provider %s get failed due to %s', $provider, $message);
        }
    } catch ($e) {
        $log->errorf('An error occurred while triggering IDV provider due to %s', $e);

        exception_logged();

        die $e;    # Keeps event in the queue.
    }

    return 1;
}

=head2 _trigger_smile_identity

Triggers Smile Identity to verify identity of clients
placed in the (Ghana, Kenya, South Africa, Nigeria).

=over 4

=item * C<client> - the client instance

=back

Returns bool.

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

    my $dob = eval { Date::Utility->new(_extract_data($client, 'date_of_birth'))->date_yyyymmdd };

    my $req_body = encode_json_utf8 {
        partner_id     => "$partner_id",
        sec_key        => _generate_smile_identity_secret_key($api_key, $partner_id, $ts),
        timestamp      => $ts,
        country        => $country,
        id_type        => $id_type,
        id_number      => $id_number,
        first_name     => _extract_data($client, 'first_name'),
        last_name      => _extract_data($client, 'last_name'),
        dob            => Date::Utility->new(_extract_data($client, 'date_of_birth'))->date_yyyymmdd,
        partner_params => {
            job_type => $job_type,
            job_id   => $job_id,
            user_id  => trim(encode_base64($client->loginid)),
        },

        $dob ? (dob => $dob) : undef,
    };

    my $response         = undef;
    my $decoded_response = undef;
    my $status           = undef;
    my $status_message   = '';

    $before_request_hook->($req_body);

    my $url = "$api_base_url/id_verification";

    $log->tracef("SmileIdentitiy verify: POST %s %s", $url, $req_body);

    try {
        $response = (await _http()->POST($url, $req_body, (content_type => 'application/json')))->content;

        $decoded_response = eval { decode_json_utf8 $response };

        ($status, $status_message) = _handle_smile_identity_response($client, $decoded_response);
    } catch ($e) {
        if (blessed($e) and $e->isa('Future::Exception')) {
            my ($payload) = $e->details;
            $response = $payload->content;

            $decoded_response = eval { decode_json_utf8 $response } // {};

            $status         = RESULT_STATUS->{fail};
            $status_message = sprintf(
                "SmileIdentity respond an error to our request with code: %s, message: %s - %s",
                $decoded_response->{code} // 'UNKNOWN',
                $e->message, $decoded_response->{error} // 'UNKNOWN'
            );

            $status_message = $log->error($status_message);
        }
    }

    return ($status, $decoded_response, $status_message);
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
        'Verified'           => 'pass',
        'Not Verified'       => 'fail',
        'Issuer Unavailable' => 'unavailable',
        'N/A'                => 'unavailable',
    );

    my ($status, $status_message);

    unless ($response_hash) {
        $status         = RESULT_STATUS->{fail};
        $status_message = $log->errorf("SmileIdentity response is not a valid JSON.");
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
        if ($verification_status_map{$verify_status} eq 'pass') {
            if ($personal_info_returned) {
                $status = RESULT_STATUS->{pass};
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

    return 'onfido' unless $country_configs->is_idv_supported($document->{issuing_country});
    return $country_configs->get_idv_config($document->{issuing_country})->{provider};
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

=head2 _transform_smile_identity_response

The SmileID API's response transformator, it would make 
the results consistent for parent handler subroutine.

=cut

sub _transform_smile_identity_response {
    my ($response) = @_;

    my $expiration_date = undef;
    $expiration_date = eval { Date::Utility->new($response->{ExpirationDate}) } if $response->{ExpirationDate};

    return {
        full_name       => $response->{FullName},
        date_of_birth   => $response->{DOB},
        expiration_date => $expiration_date,
    };
}

=head2 _extract_data

Extracter subroutine, manages client's properties extraction

=cut

sub _extract_data {
    my ($client, $property) = @_;

    my $func = "_extract_$property";

    try {
        return __PACKAGE__->can($func)->($client) if __PACKAGE__->can($func);
        return $client->{$property} // $client->$property() // '';
    } catch ($e) {
        $log->errorf('An error occurred while extracting %s from client %s data.', $property, $client->loginid);
    }

    return '';
}

sub _extract_first_name {
    my $client = shift;

    return $client->{first_name} if $client->{first_name};

    my @names = split(/\s+/, $client->{name} // '');
    return $names[0];
}

sub _extract_last_name {
    my $client = shift;

    return $client->{last_name} if $client->{last_name};

    my @names = split(/\s+/, $client->{name} // '');

    return $names[-1] unless scalar @names < 2;
}

1
