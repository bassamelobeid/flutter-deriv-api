package BOM::API::Payment::Client;

## no critic (RequireUseStrict,RequireUseWarnings)

use Moo;
with 'BOM::API::Payment::Role::Plack';

use Data::Dumper;

sub client_GET {
    my $c      = shift;
    my $client = $c->user;

    my $r = {
        loginid               => $client->loginid,
        email                 => $client->email,
        first_name            => $client->first_name,
        last_name             => $client->last_name,
        salutation            => $client->salutation,
        address_line_1        => $client->address_line_1,
        address_line_2        => $client->address_line_2,
        address_city          => $client->address_city,
        address_state         => $client->address_state,
        address_postcode      => $client->address_postcode,
        country               => $client->residence,
        phone                 => $client->phone,
        date_joined           => $client->date_joined,
        restricted_ip_address => $client->restricted_ip_address,
        gender                => $client->gender,
    };
    return $r;
}

no Moo;

1;
