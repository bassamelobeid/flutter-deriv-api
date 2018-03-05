package BOM::Platform::Client::Utility;

use strict;
use warnings;

use Crypt::CBC;
use Crypt::NamedKeys;
use Encode;
use Encode::Detect::Detector;
use DataDog::DogStatsd::Helper qw(stats_inc);

use Webservice::GAMSTOP;
use Brands;

use BOM::Platform::Config;
use BOM::Platform::Email qw(send_email);
use BOM::Platform::Context qw(request);

sub encrypt_secret_answer {
    my $secret_answer = shift;
    return Crypt::NamedKeys->new(keyname => 'client_secret_answer')->encrypt_payload(data => $secret_answer);
}

sub decrypt_secret_answer {
    my $secret_answer = shift;
    if ($secret_answer =~ /^\w+\*.*\./) {    # new AES format
        return Crypt::NamedKeys->new(keyname => 'client_secret_answer')->decrypt_payload(value => $secret_answer);
    } elsif ($secret_answer =~ s/^::ecp::(\S+)$/$1/) {    # legacy blowfish
        my $cipher = Crypt::CBC->new({
            'key'    => BOM::Platform::Config::aes_keys->{client_secret_answer}->{1},
            'cipher' => 'Blowfish',
            'iv'     => BOM::Platform::Config::aes_keys->{client_secret_iv}->{1},
            'header' => 'randomiv',
        });

        $secret_answer = $cipher->decrypt_hex($secret_answer);

        if (Encode::Detect::Detector::detect($secret_answer) eq 'UTF-8') {
            return Encode::decode('UTF-8', $secret_answer);
        } else {
            return $secret_answer;
        }
    } else {
        return $secret_answer;
    }
}

sub set_gamstop_self_exclusion {
    my $client = shift;

    # gamstop is only applicable for UK residence
    return undef unless $client->residence eq 'gb';

    my $gamstop_config = BOM::Platform::Config::third_party->{gamstop};

    my $landing_company_config = $gamstop_config->{config}->{$client->landing_company_short};
    # don't request if we don't have gamstop key per landing company
    return undef unless $landing_company_config;

    my $gamstop_response;
    try {
        my $instance = Webservice::GAMSTOP->new(api_url => $gamstop_config->{api_uri} api_key => $landing_company_config->{api_key});

        $gamstop_response = $instance->get_exclusion_for(
            first_name    => $client->first_name,
            last_name     => $client->last_name,
            email         => $self->email,
            date_of_birth => $client->date_of_birth,
            postcode      => $client->postcode,
        );
    }
    catch {
        stats_inc('GAMSTOP_CONNECT_FAILURE') if $_ =~ /^Error/;
    };

    return undef unless $gamstop_response;

    return undef if (not $client->get_self_exclusion_until_date and $gamstop_response->is_excluded);

    try {
        my $excluded_date = $client->set_exclusion->exclude_until(Date::Utility->new(DateTime->now()->add(months => 6)->ymd));
        $client->save();

        my $email_address = Brands->new(name => request()->brand)->emails('compliance');

        send_email({
                from    => $email_address,
                to      => $email_address,
                subject => 'Client ' . $client->loginid . ' self excluded based on GAMSTOP response',
                message => [
                          "Client "
                        . $client->loginid
                        . " has been self excluded based on GASMSTOP response.\n\n"
                        . "Excluded from website until: $excluded_date"
                ],
            });
    };

    return undef;
}

1;
