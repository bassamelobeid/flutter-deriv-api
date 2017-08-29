package BOM::Test::Helper::Client;

use strict;
use warnings;

use Exporter qw( import );

our @EXPORT_OK = qw(create_client);

sub create_client {
    my $broker   = shift || 'CR';
    my $skipauth = shift;
    my $client   = Client::Account->register_and_return_new_client({
        broker_code      => $broker,
        client_password  => BOM::Platform::Password::hashpw('12345678'),
        salutation       => 'Ms',
        last_name        => 'Doe',
        first_name       => 'Jane' . time . '.' . int(rand 1000000000),
        email            => 'jane.doe' . time . '.' . int(rand 1000000000) . '@test.domain.nowhere',
        residence        => 'in',
        address_line_1   => '298b md rd',
        address_line_2   => '',
        address_city     => 'Place',
        address_postcode => '65432',
        address_state    => 'st',
        phone            => '+9145257468',
        secret_question  => 'What the f***?',
        secret_answer    => BOM::Platform::Client::Utility::encrypt_secret_answer('is that'),
        date_of_birth    => '1945-08-06',
    });
    if (!$skipauth && $broker =~ /(?:MF|MLT|MX)/) {
        $client->set_status('age_verification');
        $client->set_authentication('ID_DOCUMENT')->status('pass') if $broker eq 'MF';
        $client->save;
    }
    return $client;
}

1;
