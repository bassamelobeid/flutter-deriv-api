package BOM::Platform::Client::Utility;

use strict;
use warnings;

use Crypt::CBC;
use Encode::Detect::Detector;
use Encode;
use Crypt::NamedKeys;
use BOM::Database::DAO::Client;
use BOM::System::Config;
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
            'key'    => BOM::System::Config::aes_keys->{client_secret_answer}->{1},
            'cipher' => 'Blowfish',
            'iv'     => BOM::System::Config::aes_keys->{client_secret_iv}->{1},
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

1;
