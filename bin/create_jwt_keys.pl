#!/usr/bin/env perl

use strict;
use warnings;

use Path::Tiny;
use Crypt::JWT qw(encode_jwt decode_jwt);
use Crypt::OpenSSL::RSA;
use Crypt::OpenSSL::Bignum;
use MIME::Base64    qw(encode_base64url);
use JSON::MaybeUTF8 qw(encode_json_text);

use BOM::Platform::Auth::JWT;

use constant {
    KEY_KID         => 'kid1',
    PUBLIC_KEY_PATH => '/etc/rmg/jwt/test_public.pem',
};

sub get_certificate {
    my $path = path(PUBLIC_KEY_PATH);

    return $path->slurp_utf8;
}

my $rsa_public_key = get_certificate();

sub generate_jwk_params {
    my $rsa_pub = Crypt::OpenSSL::RSA->new_public_key($rsa_public_key);

    my ($modulus, $exponent) = $rsa_pub->get_key_parameters();

    $modulus  = encode_base64url($modulus->to_bin());
    $exponent = encode_base64url($exponent->to_bin());

    return {
        modulus  => $modulus,
        exponent => $exponent
    };
}

my $key_structure = {
    keys => [{
            "kid" => KEY_KID,
            "kty" => "RSA",
            "alg" => "RS256",
            "use" => "sig",
            "e"   => generate_jwk_params()->{exponent},
            "n"   => generate_jwk_params()->{modulus},
        }
    ],
    public_cert => {
        "kid"  => KEY_KID,
        "cert" => $rsa_public_key
    },
    public_certs => [{
            "kid"  => KEY_KID,
            "cert" => $rsa_public_key
        },
    ],
};

path(BOM::Platform::Auth::JWT::issuer_details()->{keys_path})->spew_utf8(encode_json_text($key_structure));
