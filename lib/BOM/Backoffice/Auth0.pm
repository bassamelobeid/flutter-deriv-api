package BOM::Backoffice::Auth0;

use warnings;
use strict;

use Mojo::UserAgent;
use JSON::MaybeUTF8 qw(:v1);
use List::Util      qw(any first);

use BOM::Config::Runtime;
use BOM::Config;
use BOM::User::AuditLog;
use BOM::Config::Redis;
use BOM::Backoffice::Utility;
use BOM::Backoffice::Auth;
use BOM::Backoffice::Request qw(request);

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

=head2 login

Validates the access token provided by Auth0

Returns staff details on success and undef on failure

=cut

sub login {
    my $access_token = shift;

    return BOM::Backoffice::Auth::login() if is_disabled();

    my $user = BOM::Backoffice::Auth0::user_by_access_token($access_token);
    if ($user) {
        $user->{token} = $access_token;

        BOM::Config::Redis::redis_replicated_write()->set("BINARYBOLOGIN::" . $access_token, encode_json_utf8($user), 'EX', 7 * 24 * 3600);

        return $user;
    }
    return undef;
}

=head2 logout

Log out the staff by removing the access token

=cut

sub logout {
    return BOM::Backoffice::Auth::logout() if is_disabled();

    my $staff = get_staff();

    if ($staff and BOM::Config::Redis::redis_replicated_write()->del("BINARYBOLOGIN::" . $staff->{token})) {
        print 'you are logged out.';
    }
    print 'no login found.';
    return;
}

=head2 has_authorisation

Validates the staff authorization as per the group staff is assigned to

=cut

sub has_authorisation {
    my $groups = shift;

    return BOM::Backoffice::Auth::has_authorisation($groups) if is_disabled();

    my $staff = get_staff();

    my $staffname = $staff->{nickname};
    if ($staff) {
        if (not $groups or not BOM::Config::on_production()) {
            return 1;
        }
        foreach my $g (@{$staff->{groups}}) {
            if (first { /^$g$/ } @{$groups}) {
                BOM::User::AuditLog::log('successful request for ' . join(',', @{$groups}), '', $staffname);
                return 1;
            }
        }
    }
    BOM::User::AuditLog::log('failed request for ' . join(',', @{$groups}), '', $staffname);
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
    return BOM::Backoffice::Auth::check_staff() if is_disabled();

    my $auth_token = BOM::Backoffice::Cookie::get_auth_token();

    return undef unless $auth_token;

    my $cache = BOM::Config::Redis::redis_replicated_read()->get("BINARYBOLOGIN::" . $auth_token);

    return undef unless $cache;

    my $staff = decode_json_utf8($cache);

    die 'Something wrong, token does not match Redis' unless $staff->{token} eq $auth_token;

    return $staff;
}

=head2 get_staffname

Gets the current logged in staff, if there isn't one, returns C<undef>.

=cut

sub get_staffname {
    return BOM::Backoffice::Auth::get_staffname() if is_disabled();

    my $staff = get_staff();

    return $staff ? $staff->{nickname} : undef;
}

=head2 get_staff

Check if a staff is logged in, redirect to the login page otherwise.

=cut

sub get_staff {
    return BOM::Backoffice::Auth::get_staff() if is_disabled();

    BOM::Backoffice::Utility::redirect_login() unless my $staff = check_staff();
    return $staff;
}

=head2 has_write_access

Check if the staff has write access

=cut

sub has_write_access {
    return BOM::Backoffice::Auth::has_write_access() if is_disabled();

    my $staff = get_staff();

    my $staffname = $staff->{nickname};
    if ($staff) {
        if (not BOM::Config::on_production()) {
            return 1;
        }
        foreach my $group (@{$staff->{groups}}) {
            if (any { $_ eq $group } BOM::Backoffice::Utility::write_access_groups()) {
                BOM::User::AuditLog::log("successful write access requested by $staffname");
                return 1;
            }
        }
    }
    BOM::User::AuditLog::log("unauthorized write access requested by $staffname");
    return 0;
}

=head2 is_disabled

Check if the Auth0 is disabled or enabled based on app config

=cut

sub is_disabled {
    return BOM::Config::Runtime->instance->app_config->get('system.backoffice.disable_auth0_login');
}

1;
