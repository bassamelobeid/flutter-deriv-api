package BOM::Backoffice::Auth0;
use warnings;
use strict;
use Mojo::UserAgent;
use JSON::MaybeXS;
use BOM::Platform::Runtime;
use BOM::Platform::Config;
use BOM::Platform::AuditLog;
use BOM::Platform::RedisReplicated;

sub user_by_access_token {
    my $access_token = shift;

    return unless $access_token;

    my $ua              = Mojo::UserAgent->new;
    my $default_headers = {
        'authorization' => 'Bearer ' . $access_token,
    };
    my $tx = $ua->get(BOM::Platform::Config::third_party->{auth0}->{api_uri} . "/userinfo" => $default_headers);
    my $error = $tx->error;
    if ($error) {
        return;
    }
    return JSON::MaybeXS->new->decode($tx->success->body);
}

sub login {
    my $access_token = shift;

    my $user = BOM::Backoffice::Auth0::user_by_access_token($access_token);
    if ($user) {
        $user->{token} = $access_token;
        BOM::Platform::RedisReplicated::redis_write->set("BINARYBOLOGIN::" . $user->{nickname},
            Encode::encode_utf8(JSON::MaybeXS->new->encode($user)));
        BOM::Platform::RedisReplicated::redis_write->expire("BINARYBOLOGIN::" . $user->{nickname}, 24 * 3600);

        return $user;
    }
    return;
}

sub from_cookie {
    my $staff = BOM::Backoffice::Cookie::get_staff();

    my $user;
    if ($staff and $user = BOM::Platform::RedisReplicated::redis_read->get("BINARYBOLOGIN::" . $staff)) {
        return JSON::MaybeXS->new->decode(Encode::decode_utf8($user));
    }
    return;
}

sub logout {
    my $staff = BOM::Backoffice::Cookie::get_staff();

    if ($staff and BOM::Platform::RedisReplicated::redis_write->del("BINARYBOLOGIN::" . $staff)) {
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

    my $cache = BOM::Platform::RedisReplicated::redis_read->get("BINARYBOLOGIN::" . $staff);
    my $user;
    if ($cache and $user = JSON::MaybeXS->new->decode(Encode::decode_utf8($cache)) and $user->{token} = $auth_token) {
        BOM::Platform::RedisReplicated::redis_write->expire("BINARYBOLOGIN::" . $staff, 24 * 3600);
        if (not $groups or not BOM::Platform::Config::on_production()) {
            return 1;
        }
        foreach my $g (@{$user->{groups}}) {
            if (grep { /^$g$/ } @{$groups}) {
                BOM::Platform::AuditLog::log('successful request for ' . join(',', @{$groups}), '', $staff);
                return 1;
            }
        }
    }
    BOM::Platform::AuditLog::log('failed request for ' . join(',', @{$groups}), '', $staff);
    return;
}

1;
