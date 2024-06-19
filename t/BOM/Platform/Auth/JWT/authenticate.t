#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::Exception;
use Test::Warnings;
use Path::Tiny;
use FindBin         qw($Bin);
use JSON::MaybeUTF8 qw(decode_json_utf8);

use Crypt::JWT qw(encode_jwt decode_jwt);

use BOM::Platform::Auth::JWT;

my $config_mock = Test::MockModule->new('BOM::Config');
$config_mock->mock('third_party', {});

subtest 'When issuer details are missing' => sub {
    throws_ok {
        BOM::Platform::Auth::JWT->new()->validate(token => 'valid_token')
    }
    qr/Missing issuer details to validate the token/, 'Throws error when authentication keys are missing';
};

my $mock_issuer_details = {
    cloudflared => {
        issuer         => 'https://dummy.com',
        keys_path      => '/path/to/keys',
        application_id => ['dsasadsaa'],
    }};

$config_mock->mock('third_party', $mock_issuer_details);

subtest 'logout url format' => sub {
    is(BOM::Platform::Auth::JWT->new()->logout_url(), 'https://dummy.com/cdn-cgi/access/logout', 'correct format for logout url');
};

my $auth_jwt_mock = Test::MockModule->new('BOM::Platform::Auth::JWT');
$auth_jwt_mock->mock('load_keys', sub { undef });

subtest 'When keys are missing' => sub {
    throws_ok {
        BOM::Platform::Auth::JWT->new()->validate(token => 'valid_token')
    }
    qr/Missing authentication keys/, 'Throws error when authentication keys are missing';
};

subtest 'When token is invalid' => sub {
    my $file = path("$Bin/files/jwt.keys");
    $auth_jwt_mock->mock('load_keys', sub { decode_json_utf8($file->slurp_utf8); });

    throws_ok {
        BOM::Platform::Auth::JWT->new()->validate(token => 'invalid_token')
    }
    qr/JWT: invalid token format/, 'Throws error on invalid token';
};

subtest 'When token is valid and keys are present' => sub {
    # Mock decode_jwt
    my $crypt_jwt_mock = Test::MockModule->new('Crypt::JWT');
    $crypt_jwt_mock->mock('decode_jwt', sub { return ({header => 1}, {data => 1}); });

    my $rsaPriv = <<'EOF';
-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQCoVm/Sl5r+Ofky
jioRSZK26GW6WyjyfWKddsSi13/NOtCn0rRErSF/u3QrgGMpWFqKohqbi1VVC+SZ
h4F5ivUyac7/Q33t0wHP/t+a/K/SGAdoF1DmZHm7ctOUejy2NETv4bNmYazqMxzK
PsdtehsM9Almmo3LomOWINVfFbydYkN63EYGWqZOPUTV+vZEKxkut4M49IMh50bW
6nP1GtpKGwgPN5585wqJtwBop55UjeuQBTz+Y5q4tJe/fuGWTSHqxK0lveplBfI5
SRWSNciSG827+97S/suItPgb87FgbOk5BwKeKYp2iPM0/oa1UNow+H5CRIkTfZQK
iz1HfAjZAgMBAAECggEBAJSYcG9KSpQdor8gxTurYWo6LQpazAN58SIkpCFG71a/
k06BbYWt+oMhesOnumDV0F7OB4TEctf2/p0UA5PBuP3+bq3f6vqTp+buCn5qjd18
PpWA93XYvahdDS3k1VDVRQEnj9BRamz2H3TcA/i8r8I4bU/4IDDgMN5mL1OXAX8+
vt7j3YZdwsEBQk4MDrnfwQPadjDzFBxvNsDCv7DTtSNE2KY5u058DQcIimzH/ouQ
ip7qIYKGKxA2C3jIN399ngZY5QhTWGqArU/pq9WXtDkyTQ9OL23y6LVfgQSrpSKW
zjknlaShu4CcWR5r+4p+zxOf1s2sShVaB1t8Eer/xs0CgYEA0qaOkT174vRG3E/6
7gU3lgOgoT6L3pVHuu7wfrIEoxycPa5/mZVG54SgvQUofGUYEGjR0lavUAjClw9t
OzcODHX8RAxkuDntAFntBxgRM+IzAy8QzeRl/cbhgVjBTAhBcxg+3VySv5GdxFyr
QaIo8Oy/PPI1L4EFKZHmicBd3tsCgYEAzJPqCDKqaJH9TAGfzt6b4aNt9fpirEcd
pAF1bCedFfQmUZM0LG3rMtOAIhjEXgADt5GB8ZNK3BQl8BJyMmKs57oKmbVcODER
CtPqjECXXsxH+az9nzxatPvcb7imFW8OlWslwr4IIRKdEjzEYs4syQJz7k2ktqOp
YI5/UfYnw1sCgYApNaZMaZ/T3YADV646ZFDkix8gjFDmoYOf4WCxGHhpxI4YTwvt
atOtNTgQ4nJyK4DSrP7nTEgNuzj+PmlbHUElVOueEGKf280utWj2a1HqOYVLSSjb
bqQ5SnARUuC11COhtYuO2K5oxb78jDiApY2m3FnpPWUEPxRYdo+IQVbb4wKBgCZ9
JajJL3phDRDBtXlMNHOtNcDzjKDw+Eik5Zylj05UEumCEmzReVCkrhS8KCWvRwPA
Ynw6w/jH6aNTNRz5p6IpRFlK38DKqnQpDpW4iUISmPAGdekBh+dJA14ZlVWvAUVn
VUFgU1M1l0uZFzGnrJFc3sbU4Mpj3DgIVzfqYezFAoGBALEQD4oCaZfEv77H9c4S
U6xzPe8UcLgdukek5vifLCkT2+6eccTZZjgQRb1plsXbaPHQRJTZcnUmWp9+98gS
8c1vm2YFafgdkSk9Qd1oU2Fv1aOQy4VovOFzJ3CcR+2r7cbRfcpLGnintHtp9yek
02p+d5g4OChfFNDhDtnIqjvY
-----END PRIVATE KEY-----
EOF

    my $rsa = Crypt::PK::RSA->new(\$rsaPriv);

    my $payload = {
        sub            => 'qa72.regentmarkets.com',
        country        => 'in',
        email          => 'qa72@regentmarkets.com',
        identity_nonce => '21ssa1sa',
        iss            => 'iss-string',
        aud            => 'aud-string',
        custom         => {
            name  => 'qa72',
            email => 'qa72@regentmarkets.com',
        },
    };

    my %encoded_data = (
        key     => $rsa,
        alg     => 'RS256',
        payload => $payload,
    );

    my $token = encode_jwt(%encoded_data);

    throws_ok {
        BOM::Platform::Auth::JWT->new()->validate(token => $token)
    }
    qr/JWS: kid_keys lookup failed/, 'Throws error when exp claim is missing';

    $encoded_data{extra_headers} = {kid => "key1"};
    $token = encode_jwt(%encoded_data);
    throws_ok {
        BOM::Platform::Auth::JWT->new()->validate(token => $token)
    }
    qr/JWT: exp claim required but missing/, 'Throws error on invalid token';

    $encoded_data{relative_exp} = 10000;
    $token = encode_jwt(%encoded_data);

    throws_ok {
        BOM::Platform::Auth::JWT->new()->validate(token => $token)
    }
    qr/JWT: nbf claim required but missing/, 'Throws error when nbf claim is missing';

    $encoded_data{relative_nbf} = 0;
    $token = encode_jwt(%encoded_data);

    throws_ok {
        BOM::Platform::Auth::JWT->new()->validate(token => $token)
    }
    qr/JWT: iat claim required but missing/, 'Throws error when iat claim is missing';

    $encoded_data{auto_iat} = 1;
    $token = encode_jwt(%encoded_data);
    throws_ok {
        BOM::Platform::Auth::JWT->new()->validate(token => $token)
    }
    qr/JWT: iss claim scalar check failed/, 'Throws error when iss claim is missing';

    $encoded_data{payload}{iss} = $mock_issuer_details->{cloudflared}{issuer};
    $token = encode_jwt(%encoded_data);
    throws_ok {
        BOM::Platform::Auth::JWT->new()->validate(token => $token)
    }
    qr/JWT: aud claim code check failed/, 'Throws error when iss claim is missing';

    $encoded_data{payload}{aud} = $mock_issuer_details->{cloudflared}{application_id};
    $token = encode_jwt(%encoded_data);

    my $details = BOM::Platform::Auth::JWT->new()->validate(token => $token);

    is_deeply(
        $details,
        {
            'country' => 'in',
            'details' => {
                'email' => 'qa72@regentmarkets.com',
                'name'  => 'qa72'
            },
            'email'          => 'qa72@regentmarkets.com',
            'expiry'         => $details->{expiry},
            'id'             => 'qa72.regentmarkets.com',
            'identity_nonce' => '21ssa1sa',
            'issuer'         => 'https://dummy.com',
            'name'           => 'qa72'
        },
        'Returns user details when token and keys are valid'
    );
};

done_testing();
