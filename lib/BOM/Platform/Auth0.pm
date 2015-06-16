package BOM::Platform::Auth0;
use warnings;
use strict;
use Mojo::UserAgent;
use JSON;
use Cache::RedisDB;
use BOM::Platform::Context;
use BOM::Platform::Runtime;
use BOM::System::Config;
use Carp;
use BOM::System::AuditLog;

sub user_by_access_token {
    my $access_token = shift;

    return unless $access_token;

    my $ua              = Mojo::UserAgent->new;
    my $default_headers = {
        'authorization' => 'Bearer ' . $access_token,
    };
    my $tx = $ua->get(BOM::System::Config::third_party->{auth0}->{api_uri} . "/userinfo" => $default_headers);
    my ($error, $code) = $tx->error;
    if ($error) {
        return;
    }
    return JSON->new->decode($tx->success->body);
}

sub login {
    my $access_token = shift;

    my $user = BOM::Platform::Auth0::user_by_access_token($access_token);
    if ($user) {
        $user->{token} = $access_token;
        Cache::RedisDB->set("BINARYBOLOGIN", $user->{nickname}, JSON->new->utf8->encode($user), 24 * 3600);
        return $user;
    }
    return;
}

sub from_cookie {
    my $cookie = shift || BOM::Platform::Context::request()->bo_cookie;
    if ($cookie and my $user = Cache::RedisDB->get("BINARYBOLOGIN", $cookie->clerk)) {
        return JSON->new->utf8->decode($user);
    }
    return;
}

sub loggout {
    my $cookie = BOM::Platform::Context::request()->bo_cookie;
    if ($cookie and my $user = Cache::RedisDB->del("BINARYBOLOGIN", $cookie->clerk)) {
        print 'you are logged out.';
    }
    print 'no login found.';
    return;
}

sub can_access {
    my $groups = shift;

    if (BOM::Platform::Auth0::has_authorisation($groups)) {
        return 1;
    }
    print "login again";
    exit 0;
}

sub has_authorisation {
    my $groups = shift;

    my $cookie = BOM::Platform::Context::request()->bo_cookie;
    my $cache = Cache::RedisDB->get("BINARYBOLOGIN", $cookie->clerk);
    my $user;
    if ($cookie and $cache and $user = JSON->new->utf8->decode($cache) and $user->{token} = $cookie->token) {
        Cache::RedisDB->redis->execute('expire', "BINARYBOLOGIN::" . $cookie->clerk => 24 * 3600);
        if (not $groups or not BOM::Platform::Runtime->instance->app_config->system->on_production) {
            return 1;
        }
        foreach my $g (@{$user->{groups}}) {
            if (grep { /^$g$/ } @{$groups}) {
                BOM::System::AuditLog::log('successful request for ' . join(',', @{$groups}), '', $cookie->clerk);
                return 1;
            }
        }
    }
    BOM::System::AuditLog::log('failed request for ' . join(',', @{$groups}), '', $cookie->clerk);
    return;
}
1;
