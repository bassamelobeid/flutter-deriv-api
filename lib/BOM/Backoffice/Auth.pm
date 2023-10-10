package BOM::Backoffice::Auth;

use warnings;
use strict;

no indirect;

use JSON::MaybeUTF8 qw(:v1);
use List::Util      qw(any first);
use Syntax::Keyword::Try;
use Sys::Hostname;
use Crypt::JWT qw(encode_jwt decode_jwt);
use Email::Address::XS;

use BOM::Config;
use BOM::Config::Redis;
use BOM::Backoffice::Cookie;
use BOM::User::AuditLog;
use BOM::Platform::Auth::JWT;
use BOM::Backoffice::Utility;
use BOM::Backoffice::Request qw(request);

use constant BACKOFFICE_LOGIN_KEY_PREFIX => 'DERIVBOLOGIN::';

=head2 login

Validates the JWT token

Returns staff details on success and undef on failure

=cut

sub login {
    try {
        my $token = get_authorization_token();

        my $staff = BOM::Platform::Auth::JWT->new()->validate(token => $token);
        if ($staff) {
            $staff->{token}    = $token;
            $staff->{nickname} = get_staff_nickname($staff);

            BOM::Config::Redis::redis_replicated_write()->set(BACKOFFICE_LOGIN_KEY_PREFIX . $token, encode_json_utf8($staff), 'EX', 24 * 3600);

            return $staff;
        }
    } catch ($e) {
        warn "Invalid authentication (JWT) token. Error: $e";
    }

    return undef;
}

=head2 logout

Log out the staff by removing the access token

=cut

sub logout {
    my $staff = get_staff();

    if ($staff and BOM::Config::Redis::redis_replicated_write()->del(BACKOFFICE_LOGIN_KEY_PREFIX . $staff->{token})) {
        return 1;
    }

    return 0;
}

=head2 has_authorisation

Validates the staff authorization as per the group staff is assigned to

=cut

sub has_authorisation {
    my $groups = shift;
    my $staff  = get_staff();

    if ($staff) {
        if (not $groups or not BOM::Config::on_production()) {
            return 1;
        }
        foreach my $g (@{$staff->{details}{group}}) {
            if (first { /^$g$/ } @{$groups}) {
                BOM::User::AuditLog::log('successful request for ' . join(',', @{$groups}), '', $staff->{name});
                return 1;
            }
        }
    }
    BOM::User::AuditLog::log('failed request for ' . join(',', @{$groups}), '', $staff->{name});
    return 0;
}

=head2 has_quants_write_access

Check if the staff is part of QuantsWrite group

=cut

sub has_quants_write_access {
    return has_authorisation(['QuantsWrite']);
}

=head2 check_staff

Will get the logged in staff info from the Redis server or return C<undef>.

=cut

sub check_staff {
    my $auth_token = BOM::Backoffice::Cookie::get_auth_token();

    return undef unless $auth_token;

    my $cache = BOM::Config::Redis::redis_replicated_read()->get(BACKOFFICE_LOGIN_KEY_PREFIX . $auth_token);

    return undef unless $cache;

    my $staff = decode_json_utf8($cache);

    die 'Something wrong, token does not match Redis' unless $staff->{token} eq $auth_token;

    return $staff;
}

=head2 get_staffname

Gets the current logged in staff, if there isn't one, returns C<undef>.

=cut

sub get_staffname {
    my $staff = get_staff();

    return $staff ? $staff->{nickname} : undef;
}

=head2 get_staff

Returns the staff details if it is logged in

=cut

sub get_staff {
    return check_staff();
}

=head2 has_write_access

Check if the staff has write access

Sample schema of $staff we expect
{
        'issuer'         => 'https://derivcom.cloudflareaccess.com',
        'id'             => 'he200958-5b36-4368-2057-4842f23d7fd0',
        'identity_nonce' => 'rejq7GVraGnLUtqy',
        'details'        => {
            'email'             => 'test_name@regentmarkets.com',
            'backofficeauth0ID' => '',
            'group'             => [],
            'name'              => 'test name'
        },
        'country' => 'AE',
        'name'    => 'test name',
        'expiry'  => 1695803758,
        'email'   => 'test_name@regentmarkets.com'
    };

=cut

sub has_write_access {
    my $staff = get_staff();

    my $staffname = $staff->{nickname};
    if ($staff) {
        if (not BOM::Config::on_production()) {
            return 1;
        }
        foreach my $group (@{$staff->{details}{group}}) {
            if (any { $_ eq $group } BOM::Backoffice::Utility::write_access_groups()) {
                BOM::User::AuditLog::log("successful write access requested by $staffname");
                return 1;
            }
        }
    }
    BOM::User::AuditLog::log("unauthorized write access requested by $staffname");
    return 0;
}

=head2 get_authorization_token

Return the authorization token from the HTTP header else from cookie

=cut

sub get_authorization_token {
    if (BOM::Config::on_qa()) {
        return test_authorization_token();
    } else {
        return $ENV{HTTP_CF_ACCESS_JWT_ASSERTION} // request()->cookies->{CF_Authorization} // '';
    }
}

=head2 logout_url

Return the authentication logout url

=cut

sub logout_url {
    if (BOM::Config::on_qa()) {
        return request()->url_for('backoffice/logout.cgi');
    } else {
        return BOM::Platform::Auth::JWT->new()->logout_url();
    }
}

=head2 test_authorization_token

Create a JWT token and return the payload for the same JWT token

=cut

sub test_authorization_token {
    if (BOM::Config::on_qa()) {
        my ($name, $domain, $extension) = split(/\./, Sys::Hostname::hostname);

        my $issuer_details = BOM::Config::third_party()->{cloudflared};

        my $rsa = Crypt::PK::RSA->new($issuer_details->{private_key_path});

        my %encoded_data = (
            alg           => 'RS256',
            auto_iat      => 1,
            extra_headers => {
                alg => 'RS256',
                kid => "kid1"
            },
            key     => $rsa,
            type    => 'app',
            payload => {
                aud     => [$issuer_details->{application_id}[0]],
                country => 'in',
                custom  => {
                    group => ['General', 'Marketing', 'CS',],
                    name  => $name,
                    email => "$name\@$domain.$extension",
                },
                email          => "$name\@$domain.$extension",
                identity_nonce => generate_nonce(),
                iss            => $issuer_details->{issuer},
                sub            => "$name.$domain.$extension",
            },
            relative_exp => 86400,
            relative_nbf => 0,
        );

        return encode_jwt(%encoded_data);
    } else {
        die 'Invalid access: it is only allowed on the test environment.';
    }
}

=head2 generate_nonce

Returns a random characters string for the JWT token

=cut

sub generate_nonce {
    my @chars = ("A" .. "Z", "a" .. "z");
    my $nonce;
    $nonce .= $chars[rand @chars] for 1 .. 16;
    return $nonce;
}

=head2 get_staff_nickname

Returns a nickname from either the email id or staff name in token details.

=cut

sub get_staff_nickname {
    my $staff = shift;

    if ($staff) {
        return Email::Address::XS->parse($staff->{email})->user() if $staff->{email};

        return lc($staff->{name}) if $staff->{name};
    }

    return undef;
}

1;
