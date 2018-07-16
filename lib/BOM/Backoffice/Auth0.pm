package BOM::Backoffice::Auth0;
use warnings;
use strict;
use Mojo::UserAgent;
use JSON::MaybeUTF8 qw(:v1);
use BOM::Config::Runtime;
use BOM::Config;
use BOM::User::AuditLog;
use BOM::Config::RedisReplicated;

sub exchange_code_for_token {
    my $code = shift;

    return undef unless $code;

    my $ua  = Mojo::UserAgent->new;
    my $url = BOM::Config::third_party()->{auth0}->{api_uri} . "/oauth/token";
    my $tx  = $ua->post(
        $url => form => {
            client_id     => BOM::Config::third_party()->{auth0}->{client_id},
            client_secret => BOM::Config::third_party()->{auth0}->{client_secret},
            redirect_uri  => BOM::Backoffice::Request::request()->url_for('backoffice/second_step_auth.cgi'),
            code          => $code,
            grant_type    => 'authorization_code',
        });
    return undef if $tx->error;
    return $tx->result->json->{access_token};
}

sub user_by_access_token {
    my $access_token = shift;

    return undef unless $access_token;

    my $ua              = Mojo::UserAgent->new;
    my $default_headers = {
        'authorization' => 'Bearer ' . $access_token,
    };
    my $tx = $ua->get(BOM::Config::third_party()->{auth0}->{api_uri} . "/userinfo" => $default_headers);
    return undef if $tx->error;
    return $tx->result->json;
}

sub login {
    my $access_token = shift;

    my $user = BOM::Backoffice::Auth0::user_by_access_token($access_token);
    if ($user) {
        $user->{token} = $access_token;
        BOM::Config::RedisReplicated::redis_write()->set("BINARYBOLOGIN::" . $user->{nickname}, encode_json_utf8($user));
        BOM::Config::RedisReplicated::redis_write()->expire("BINARYBOLOGIN::" . $user->{nickname}, 24 * 3600);

        return $user;
    }
    return;
}

sub from_cookie {
    my $staff = BOM::Backoffice::Cookie::get_staff();

    my $user;
    if ($staff and $user = BOM::Config::RedisReplicated::redis_read()->get("BINARYBOLOGIN::" . $staff)) {
        return decode_json_utf8($user);
    }
    return;
}

sub logout {
    my $staff = BOM::Backoffice::Cookie::get_staff();

    if ($staff and BOM::Config::RedisReplicated::redis_write()->del("BINARYBOLOGIN::" . $staff)) {
        print 'you are logged out.';
    }
    print 'no login found.';
    return;
}

sub has_authorisation {
    my $groups     = shift;
    my $staff      = BOM::Backoffice::Cookie::get_staff();
    my $auth_token = BOM::Backoffice::Cookie::get_auth_token();
    return unless ($staff and $auth_token);

    my $cache = BOM::Config::RedisReplicated::redis_read()->get("BINARYBOLOGIN::" . $staff);
    my $user;
    if ($cache and $user = decode_json_utf8($cache) and $user->{token} = $auth_token) {
        BOM::Config::RedisReplicated::redis_write()->expire("BINARYBOLOGIN::" . $staff, 24 * 3600);
        if (not $groups or not BOM::Config::on_production()) {
            return 1;
        }
        foreach my $g (@{$user->{groups}}) {
            if (grep { /^$g$/ } @{$groups}) {
                BOM::User::AuditLog::log('successful request for ' . join(',', @{$groups}), '', $staff);
                return 1;
            }
        }
    }
    BOM::User::AuditLog::log('failed request for ' . join(',', @{$groups}), '', $staff);
    return;
}

1;
