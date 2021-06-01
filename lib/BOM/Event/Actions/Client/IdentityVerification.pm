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
use Digest::SHA qw( sha256_hex );
use Future::AsyncAwait;
use IO::Async::Loop;
use JSON::MaybeUTF8 qw( decode_json_utf8  encode_json_utf8 );
use Log::Any qw( $log );
use MIME::Base64 qw( decode_base64  encode_base64 );
use Syntax::Keyword::Try;

use BOM::Event::Services;
use BOM::Event::Utility qw( exception_logged );
use BOM::Platform::Context qw( request );
use BOM::User::Client;

use constant TRIGGER_MAP => {
    smile_identity => \&_trigger_smile_identity,
};

use constant RESULT_STATUS => {
    pass => 'pass',
    fail => 'fail',
    n_a  => 'unavailable',
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
    # test_result is for QA testing and will remove in next changes
    my ($test_result, $loginid) = @{$args}{qw/test_result loginid/};

    my $client = BOM::User::Client->new({loginid => $loginid})
        or die 'Could not instantiate client for login ID: ' . $loginid;

    return undef
        if $client->status->allow_document_upload
        or $client->status->age_verification;

    my $provider = _get_provider($client);

    die "Could not perform triggering, the function for provider $provider not found."
        unless exists TRIGGER_MAP->{$provider};

    try {
        $log->debugf('Start triggering identity verification service (%s) for loginID %s', $provider, $loginid);
        my $result = await TRIGGER_MAP->{$provider}($client, $test_result) // undef;

        if ($result eq RESULT_STATUS->{n_a}) {
            # Identity verification status in unknown
            warn 'Identity is unknown.';
            return undef;
        }

        my ($status, $payload) = $result;

        $payload = $payload;    # for pass the strict unused variable checker

        if ($status eq RESULT_STATUS->{pass}) {
            # Identity has been verified, perform required steps
            warn 'Identity is verified.';
        }

        if ($status eq RESULT_STATUS->{fail}) {
            # Identity has not verified
            warn 'Identity is not verified.';
        }
    } catch ($e) {
        $log->errorf('An error occurred while triggering IDV provider due to %s', $e);

        exception_logged();

        die $e;    # Keeps event in the queue.
    }

    return undef;
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
    my ($client, $test_result) = @_;

    my %verification_status_map = (
        'Verified'           => 'pass',
        'Not Verified'       => 'fail',
        'Issuer Unavailable' => 'unavailable',
        'N/A'                => 'unavailable',
    );

    my $config = BOM::Config::third_party()->{smile_identity};

    my $api_base_url = $config->{api_url}    // '';
    my $api_key      = $config->{api_key}    // '';
    my $partner_id   = $config->{partner_id} // '';

    my $ts = time;

    my $residence = uc 'ke';
    my $id_number = '0000000' . $test_result;    # FIXME: get id number from db
    my $id_type   = 'NATIONAL_ID';               # FIXME: get id type from db

    my $job_type = 5;                            # based on Smile Identity documentation
    my $job_id   = Data::UUID->new->create_str();

    my $req_body = {
        partner_id     => "$partner_id",
        sec_key        => _generate_smile_identity_secret_key($api_key, $partner_id, $ts),
        timestamp      => $ts,
        country        => $residence,
        id_type        => $id_type,
        id_number      => $id_number,
        first_name     => _extract_data($client, 'first_name'),
        last_name      => _extract_data($client, 'last_name'),
        partner_params => {
            job_type => $job_type,
            job_id   => $job_id,
            #user_id  => encode_base64(join '-', $id_number, $id_type, $residence),
            user_id => encode_base64($client->loginid),    # the danger of loginid exposure to third-party services
        },

        #dob            => _extract_data($client, 'date_of_birth'), // required format is YYYY-MM-DD | it is optional field so we ignore it for now.
        #phone_number   => _extract_data($client, 'phone_number'), // It's optional field, we ignore it
    };

    my $res = undef;

    _http()->POST("$api_base_url/id_verification", encode_json_utf8($req_body), (content_type => 'application/json'))->on_fail(
        sub {
            my ($err, undef, $payload) = @_;
            my $resp = eval { decode_json_utf8 $payload->content } // {};

            $log->errorf(
                "SmileIdentity respond an error to our request with code: %s, message: %s - %s",
                $resp->{code} // 'UNKNOWN',
                $err, $resp->{error} // 'UNKNOWN'
            );

            return RESULT_STATUS->{fail};

        }
    )->on_done(
        sub {
            $res = eval { decode_json_utf8 shift->content };

            unless ($res) {
                $log->errorf("SmileIdentity response is not a valid JSON.");

                return RESULT_STATUS->{fail};
            }
        })->get;

    my $verify_status = $res->{Actions}->{Verify_ID_Number} // 'unavailable';

    return RESULT_STATUS->{n_a} unless exists $verification_status_map{$verify_status};
    return RESULT_STATUS->{n_a} if $verification_status_map{$verify_status} eq 'unavailable';

    my $personal_info_returned = $res->{Actions}->{Return_Personal_Info} eq 'Returned';

    my $payload = undef;
    $payload = _transform_smile_identity_response($res) if $personal_info_returned;

    if ($verification_status_map{$verify_status} eq 'pass') {
        return (RESULT_STATUS->{pass}, $payload);
    }

    if ($verification_status_map{$verify_status} eq 'fail') {
        return (RESULT_STATUS->{fail}, $payload);
    }

    return undef;
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
    my $client = shift;

    my $residence = $client->residence;    # FIXME: should replace with document issuer country

    my $country_configs = Brands::Countries->new();

    return 'onfido' unless $country_configs->is_idv_supported($residence);
    return $country_configs->get_idv_config($residence)->{provider};
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

    return 'dummy' unless BOM::Config::on_production() and $api_key;

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
    my %data = shift->%*;

    $data{date_of_birth} = delete $data{DOB};

    return \%data;
}

=head2 _extract_data

Extracter subroutine, manages client's properties extraction

=cut

sub _extract_data {
    my ($client, $property) = @_;

    my $func = "_extract_$property";

    try {
        return __PACKAGE__->can($func)->($client) // '';
    } catch ($e) {
        $log->errorf('An error occurred while extracting %s from client %s data.', $property, $client->loginid)
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
