package BOM::User::Client::Desk;

=head1 NAME

BOM::User::Client::Desk

=head1 DESCRIPTION

This is a wrapper around WWW::Desk - Desk.com API.

=head1 SYNOPSIS

    my $api = BOM::User::Client::Desk->new({
            api_key      => '...',

            secret_key   => '...',
            token        => '...',

            token_secret => '...',
            desk_url     => '...'
    });

    $api->upload({
            loginid          => '...',
            first_name       => '...',
            last_name        => '...',
            salutation       => '...',
            email            => '...',
            phone            => '...',
            residence        => '...',
            address_line_1   => '...',
            address_line_2   => '...',
            address_city     => '...',
            address_postcode => '...',
    });

=cut

use 5.10.1;
use strict;
use warnings;

use Moose;
use WWW::Desk;
use WWW::Desk::Auth::oAuth::SingleAccessToken;
use Locale::SubCountry;

## VERSION

has 'api_key' => (
    is       => 'rw',
    isa      => 'Str',
    required => 1
);

has 'secret_key' => (
    is       => 'rw',
    isa      => 'Str',
    required => 1
);

has 'token' => (
    is       => 'rw',
    isa      => 'Str',
    required => 1
);

has 'token_secret' => (
    is       => 'rw',
    isa      => 'Str',
    required => 1
);

has 'desk_url' => (
    is       => 'rw',
    isa      => 'Str',
    required => 1
);

has 'desk_client' => (
    is      => 'ro',
    isa     => 'WWW::Desk::Auth::oAuth::SingleAccessToken',
    lazy    => 1,
    default => sub {
        my ($self) = @_;
        my $desk = WWW::Desk::Auth::oAuth::SingleAccessToken->new(
            desk_url     => $self->desk_url,
            api_key      => $self->api_key,
            secret_key   => $self->secret_key,
            token        => $self->token,
            token_secret => $self->token_secret
        );
        return $desk;
    });

=head2 upload

Upload customer information to desk.com. If the email address already exists
there, only update the customer information with the login ID.

=cut

sub upload {
    my ($self, $customer_info) = @_;

    my $country = Locale::SubCountry->new($customer_info->{residence})->country;
    my $full_address =
        join(", ", grep { defined $_ } ($customer_info->{address_line_1}, $customer_info->{address_line_2}, $customer_info->{address_postcode}));

    my $data = {
        external_id => $customer_info->{loginid},
        first_name  => $customer_info->{first_name},
        last_name   => $customer_info->{last_name},
        language    => $customer_info->{language},

        emails => [{
                type  => "work",
                value => $customer_info->{email}}
        ],

        addresses => [{
                type  => "work",
                value => $full_address
            }
        ],

        custom_fields => {
            loginid => $customer_info->{loginid},
            country => $country
        }};

    my $desk_urls = {
        'create' => {
            'url_fragment' => '/customers',
            'method'       => 'POST'
        },
        'search' => {
            'url_fragment' => '/customers/search',
            'method'       => 'GET'
        },
        'update' => {
            'url_fragment' => '/customers/',
            'method'       => 'PATCH'
        },
    };

    my $desk = $self->desk_client;

    my $response = $desk->call($desk_urls->{'create'}->{'url_fragment'}, $desk_urls->{'create'}->{'method'}, $data);

    my $error = $response->{'message'};

    if ($error) {

        if ($response->{'code'} == 422) {

            # check if email address already exists on desk.com and if so,
            # append the new login ID to the desk.com account

            my $tx = $desk->call($desk_urls->{'search'}->{'url_fragment'}, $desk_urls->{'search'}->{'method'}, {'email' => $customer_info->{email}});

            my $tx_data = $tx->{'data'};

            my $total_entries = $tx_data->{'total_entries'};

            if ($total_entries) {

                my $desk_id          = $tx_data->{_embedded}->{entries}->[0]->{id};
                my $existing_loginid = $tx_data->{_embedded}->{entries}->[0]->{custom_fields}->{loginid};

                $existing_loginid .=
                    $existing_loginid
                    ? ', ' . $customer_info->{loginid}
                    : $customer_info->{loginid};

                my $update_tx = $desk->call(
                    $desk_urls->{'update'}->{'url_fragment'} . $desk_id,
                    $desk_urls->{'update'}->{'method'},
                    {custom_fields => {loginid => $existing_loginid}});

                my $update_tx_code = $update_tx->{'code'};
                die 'Caught error ' . $update_tx_code
                    unless $update_tx->{'code'} =~ /^2/;
            }
        } else {
            die 'Caught error code ' . $response->{'code'}
                unless $response->{'code'} =~ /^2/;
        }
    }
    return undef;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
