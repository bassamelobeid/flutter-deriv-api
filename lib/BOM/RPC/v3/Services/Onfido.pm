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
use List::Util qw(all);

use BOM::Config::RedisReplicated;
use BOM::Platform::Context qw(localize);
use BOM::RPC::v3::Services;
use BOM::RPC::v3::Utility;

use constant ONFIDO_APPLICANT_KEY_PREFIX        => 'ONFIDO::APPLICANT::ID::';
use constant ONFIDO_SUPPORTED_COUNTRIES_KEY     => 'ONFIDO_SUPPORTED_COUNTRIES';
use constant ONFIDO_SUPPORTED_COUNTRIES_TIMEOUT => $ENV{ONFIDO_SUPPORTED_COUNTRIES_TIMEOUT} // 7 * 86400;    # 1 week
use constant ONFIDO_ADDRESS_REQUIRED_FIELDS     => qw(address_postcode residence);

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
    my $country = uc($client->place_of_birth // $client->residence);
    my $loginid = $client->loginid;

    return _is_supported_country_onfido($country, $onfido)->then(
        sub {
            my $is_supported = shift;

            return Future->done({
                    error => BOM::RPC::v3::Utility::create_error({
                            code              => 'UnsupportedCountry',
                            message_to_client => localize('Country "[_1]" is not supported by Onfido.', $country),
                        })}) unless $is_supported;

            _get_onfido_applicant($client, $onfido)->then(
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
                });
        });
}

=head2 _is_supported_country_onfido

Check if the passed country is supported by Onfido.

=over 4

=item * C<country> - two letter country code to check for Onfido support

=item * C<onfido> - C<WebService::Async::Onfido> object instance

=back

=cut

sub _is_supported_country_onfido {
    my ($country, $onfido) = @_;

    my $countries_list = BOM::Config::RedisReplicated::redis_events()->get(ONFIDO_SUPPORTED_COUNTRIES_KEY);
    if ($countries_list) {
        $countries_list = decode_json_utf8($countries_list);
        return Future->done($countries_list->{uc $country} // 0);
    } else {
        return $onfido->countries_list()->then(
            sub {
                $countries_list = shift;
                if ($countries_list) {
                    BOM::Config::RedisReplicated::redis_events_write()->set(
                        ONFIDO_SUPPORTED_COUNTRIES_KEY() => encode_json_utf8($countries_list),
                        EX                               => ONFIDO_SUPPORTED_COUNTRIES_TIMEOUT,
                    );
                    return Future->done($countries_list->{uc $country} // 0);
                }
            });
    }
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

    my $dbic = $client->db->dbic;
    # accessing applicant_data from onfido_applicant table
    my $applicant_data = $dbic->run(
        fixup => sub {
            my $sth = $_->selectrow_hashref('select * from betonmarkets.get_user_onfido_applicant(?::BIGINT)', undef, $client->user_id);
        });
    my $applicant_id = $applicant_data->{id};
    if ($applicant_id) {
        return $onfido->applicant_get(applicant_id => $applicant_id);
    }

    my $start = Time::HiRes::time();
    return $onfido->applicant_create(%{_client_onfido_details($client)})->then(
        sub {
            my $applicant = shift;
            my $elapsed   = Time::HiRes::time() - $start;

            # saving data into onfido_applicant table
            $dbic->run(
                fixup => sub {
                    $_->do(
                        'select betonmarkets.set_onfido_applicant(?::TEXT,?::TIMESTAMP,?::TEXT,?::BIGINT)',
                        undef, $applicant->id, Date::Utility->new($applicant->created_at)->datetime_yyyymmdd_hhmmss,
                        $applicant->href, $client->user_id
                    );
                });

            $applicant
                ? DataDog::DogStatsd::Helper::stats_timing("event.document_upload.onfido.applicant_create.done.elapsed",   $elapsed)
                : DataDog::DogStatsd::Helper::stats_timing("event.document_upload.onfido.applicant_create.failed.elapsed", $elapsed);
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

1;
