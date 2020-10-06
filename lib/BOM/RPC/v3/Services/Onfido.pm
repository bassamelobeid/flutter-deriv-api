package BOM::RPC::v3::Services::Onfido;

=head1 NAME

BOM::RPC::v3::Services::Onfido - helpers for Onfido service

=head1 DESCRIPTION

This module contains the helpers for dealing with Onfido service.

=cut

use strict;
use warnings;

use utf8;

no indirect;

use DataDog::DogStatsd::Helper qw(stats_timing);
use IO::Async::Loop;
use JSON::MaybeUTF8 qw(encode_json_utf8 decode_json_utf8);
use Locale::Codes::Country qw(country_code2code);
use Time::HiRes;
use List::Util qw(all any);

use BOM::Platform::Context qw(localize);
use BOM::RPC::v3::Services;
use BOM::RPC::v3::Utility;
use BOM::Config::Onfido;

use constant ONFIDO_APPLICANT_KEY_PREFIX    => 'ONFIDO::APPLICANT::ID::';
use constant ONFIDO_ADDRESS_REQUIRED_FIELDS => qw(address_postcode residence);

my ($loop, $services);

=head2 onfido_service_token

Returns the Onfido WebService token for the client.

=over 4

=item * C<client> - The client to generate a service token for

=item * C<referrer> - URL of the web page where the Web SDK will be used

=back

=cut

sub onfido_service_token {
    my ($client, $referrer) = @_;

    return Future->done({
            error => BOM::RPC::v3::Utility::create_error({
                    code              => 'ServiceUnavailable',
                    message_to_client => localize('The requested service is unavailable at the moment.'),
                })}) if (BOM::Config::Runtime->instance->app_config->system->suspend->onfido);

    $loop //= IO::Async::Loop->new;
    $loop->add($services = BOM::RPC::v3::Services->new) unless $services;

    my $onfido  = $services->onfido();
    my $country = uc($client->place_of_birth || $client->residence);
    my $loginid = $client->loginid;

    return Future->done({
            error => BOM::RPC::v3::Utility::create_error({
                    code              => 'MissingPersonalDetails',
                    message_to_client => localize('Update your personal details.'),
                    details           => {
                        place_of_birth => "is missing and it is required",
                        residence      => "is missing and it is required",
                    },
                })}) unless $country;

    my $is_country_supported = BOM::Config::Onfido::is_country_supported($country);

    return Future->done({
            error => BOM::RPC::v3::Utility::create_error({
                    code              => 'UnsupportedCountry',
                    message_to_client => localize('Country "[_1]" is not supported by Onfido.', $country),
                })}) unless $is_country_supported;

    return _get_onfido_applicant($client, $onfido)->then(
        sub {
            my $applicant = shift;
            return Future->done({
                    error => BOM::RPC::v3::Utility::create_error({
                            code              => 'ApplicantError',
                            message_to_client => localize('Cannot create applicant for [_1].', $loginid),
                        })}) unless $applicant;

            $onfido->sdk_token(
                applicant_id => $applicant->id,
                referrer     => $referrer,
            )->then(
                sub {
                    my $response = shift;

                    return Future->done({
                            error => BOM::RPC::v3::Utility::create_error({
                                    code              => 'TokenGeneratingError',
                                    message_to_client => localize('Cannot generate token for [_1].', $loginid),
                                })}) unless exists $response->{token};

                    return Future->done({token => $response->{token}});
                });
        }
    )->else(
        sub {
            # We just care about http failures

            my ($response) = grep { (ref $_ // '') =~ /HTTP::Response/ } @_;
            my $validation_error = _get_onfido_validation_error($response);

            return Future->done({error => BOM::RPC::v3::Utility::create_error($validation_error)})
                if $validation_error;

            return Future->done({
                    error => BOM::RPC::v3::Utility::create_error({
                            code              => 'ApplicantError',
                            message_to_client => localize('Cannot create applicant for [_1].', $loginid),
                        })});
        });
}

=head2 _get_onfido_validation_error

Parses the Onfido response when status code 422 happens.

Note the tricky onfido response structure for validations errors:

{"error":{"type":"validation_error","message":"There was a validation error on this request","fields":{"addresses":[{"postcode":["invalid postcode"]}]}}}

Detecting the following errors:

=over 4

=item * C<InvalidPostalCode>, when there is a `postcode` error in at least one of the addresses

=back

It takes the following argument:

=over 4

=item * C<response> - C<Http::Response> the http response from Onfido

=back

Returns the { code, message_to_client } hashref for the `create_error` method 
when a validation error is detected, C<undef> otherwise.

=cut    

sub _get_onfido_validation_error {
    my $response = shift;
    return undef unless $response;
    return undef unless (ref $response // '') eq 'HTTP::Response';
    return undef unless $response->code == 422;

    my $json      = decode_json_utf8($response->content);
    my $addresses = $json->{error}{fields}{addresses} // [];

    return +{
        code              => 'InvalidPostalCode',
        message_to_client => localize('Your postal code is invalid.'),
        }
        if any { defined $_->{postcode} } $addresses->@*;

    return undef;
}

=head2 _get_onfido_applicant

Gets the existing applicant otherwise creates a new one on Onfido.

=over 4

=item * C<client> - the client to get the Onfido applicant for

=item * C<onfido> - C<WebService::Async::Onfido> object instance

=back

=cut

sub _get_onfido_applicant {
    my ($client, $onfido) = @_;

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;
    # accessing applicant_data from onfido_applicant table
    my $applicant_data = $dbic->run(
        fixup => sub {
            my $sth = $_->selectrow_hashref('select * from users.get_onfido_applicant(?::BIGINT)', undef, $client->user_id);
        });
    my $applicant_id = $applicant_data->{id};

    if ($applicant_id) {
        return $onfido->applicant_get(applicant_id => $applicant_id);
    }

    return $onfido->applicant_create(%{_client_onfido_details($client)})->then(
        sub {
            my $applicant = shift;

            # saving data into onfido_applicant table
            $dbic->run(
                fixup => sub {
                    $_->do(
                        'select users.add_onfido_applicant(?::TEXT,?::TIMESTAMP,?::TEXT,?::BIGINT)',
                        undef,            $applicant->id, Date::Utility->new($applicant->created_at)->datetime_yyyymmdd_hhmmss,
                        $applicant->href, $client->user_id
                    );
                });

            return Future->done($applicant);
        });
}

=head2 _client_onfido_details

Generate the list of client personal details needed for Onfido API.

=over 4

=item * C<client> - the client to generate the details for

=back

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

1;
