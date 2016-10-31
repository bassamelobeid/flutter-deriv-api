package BOM::Backoffice::Auth0;
use warnings;
use strict;
use Mojo::UserAgent;
use JSON;
use BOM::Platform::Runtime;
use BOM::System::Config;
use BOM::System::AuditLog;
use BOM::System::RedisReplicated;

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

    my $user = BOM::Backoffice::Auth0::user_by_access_token($access_token);
    if ($user) {
        $user->{token} = $access_token;
        BOM::System::RedisReplicated::redis_write->set("BINARYBOLOGIN::" . $user->{nickname}, JSON->new->utf8->encode($user));
        BOM::System::RedisReplicated::redis_write->expire("BINARYBOLOGIN::" . $user->{nickname}, 24 * 3600);

        return $user;
    }
    return;
}

sub from_cookie {
    my $staff = BOM::Backoffice::Cookie::get_staff();

    my $user;
    if ($staff and $user = BOM::System::RedisReplicated::redis_read->get("BINARYBOLOGIN::" . $staff)) {
        return JSON->new->utf8->decode($user);
    }
    return;
}

sub logout {
    my $staff = BOM::Backoffice::Cookie::get_staff();

    if ($staff and BOM::System::RedisReplicated::redis_write->del("BINARYBOLOGIN::" . $staff)) {
        print 'you are logged out.';
    }
    print 'no login found.';
    return;
}

sub can_access {
    my $groups = shift;

    if (BOM::Backoffice::Auth0::has_authorisation($groups)) {
        return 1;
    }
    print "login again";
    exit 0;
}

sub has_authorisation {
    my $groups     = shift;
    my $staff      = BOM::Backoffice::Cookie::get_staff();
    my $auth_token = BOM::Backoffice::Cookie::get_auth_token();
    return unless ($staff and $auth_token);

    my $cache = BOM::System::RedisReplicated::redis_read->get("BINARYBOLOGIN::" . $staff);
    my $user;
    if ($cache and $user = JSON->new->utf8->decode($cache) and $user->{token} = $auth_token) {
        BOM::System::RedisReplicated::redis_write->expire("BINARYBOLOGIN::" . $staff, 24 * 3600);
        if (not $groups or not BOM::System::Config::on_production()) {
            return 1;
        }
        foreach my $g (@{$user->{groups}}) {
            if (grep { /^$g$/ } @{$groups}) {
                BOM::System::AuditLog::log('successful request for ' . join(',', @{$groups}), '', $staff);
                return 1;
            }
        }
    }
    BOM::System::AuditLog::log('failed request for ' . join(',', @{$groups}), '', $staff);
    return;
}

1;
