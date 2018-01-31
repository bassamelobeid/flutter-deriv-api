package BOM::OAuth::OneAll;

use v5.10;
use Mojo::Base 'Mojolicious::Controller';
use WWW::OneAll;
use BOM::Platform::Config;
use BOM::Platform::Context qw(localize);
use BOM::Database::Model::UserConnect;
use BOM::Platform::User;
use BOM::Platform::Account::Virtual;
use Try::Tiny;
use URI::QueryParam;
use DataDog::DogStatsd::Helper qw(stats_inc);
use BOM::OAuth::Helper;

sub callback {
    my $c = shift;
    # Microsoft Edge and Internet Exporer browsers have a drawback
    # in carrying parameters through responses. Hence, we are retrieving the token
    # from the stash.
    # For optimization reason, the URI should be contructed afterwards
    # checking for presence of connection token in request parameters.
    my $connection_token = $c->param('connection_token') // $c->_get_provider_token() // '';
    my $redirect_uri = $c->req->url->path('/oauth2/authorize')->to_abs;
    # Redirect client to authorize subroutine if there is no connection token provided
    # or request came from Japan.
    return $c->redirect_to($redirect_uri)
        if $c->{stash}->{request}->{country_code} eq 'jp'
        or not $connection_token;

    my $brand_name = BOM::OAuth::Helper->extract_brand_from_params($c->stash('request')->params) // $c->stash('brand')->name;

    unless ($brand_name) {
        $c->session(error => 'Invalid brand name.');
        return $c->redirect_to($redirect_uri);
    }

    my $oneall = WWW::OneAll->new(
        subdomain   => 'binary',
        public_key  => BOM::Platform::Config::third_party->{"oneall"}->{public_key},
        private_key => BOM::Platform::Config::third_party->{"oneall"}->{private_key},
    );
    my $data = $oneall->connection($connection_token) or die $oneall->errstr;
    # redirect client to auth page when recieving bad status code from oneall
    # wrong pub/private keys might be a reason of bad status code
    my $status_code = $data->{response}->{request}->{status}->{code};
    if ($status_code != 200) {
        $c->session(error => localize('Failed to get user identity.'));
        stats_inc('login.oneall.connection_failure', {tags => ["brand:$brand_name", "status_code:$status_code"]});
        return $c->redirect_to($redirect_uri);
    }

    # retrieve user identity from provider data
    my $provider_data = $data->{response}->{result}->{data};
    my $user_connect  = BOM::Database::Model::UserConnect->new;
    my $user_id       = $user_connect->get_user_id_by_connect($provider_data);

    my $email = _get_email($provider_data);
    my $user  = try {
        BOM::Platform::User->new({email => $email})
    };
    # Registered users who have email/password based account are forbidden
    # from social signin. As only one login method
    # is allowed (either email/password or social login).
    if ($user and not $user->has_social_signup) {
        # Redirect client to login page if social signup flag is not found.
        # As the main purpose of this package is to serve
        # clients with social login only.
        $c->session('error', localize("Invalid login attempt. Please log in with your email and password instead."));
        return $c->redirect_to($redirect_uri);
    }
    # Create virtual client if user not found
    # consequently initialize user_id and link account to social login.
    if (not $user_id) {
        # create user based on email by fly if account does not exist yet
        $user = $c->__create_virtual_user($email, $brand_name) unless $user;
        # connect oneall provider data to user identity
        $user_connect->insert_connect($user->id, $provider_data);
        $user_id = $user->id;
        my $provider_name = $provider_data->{user}->{identity}->{provider};
        stats_inc('login.oneall.new_user_created', {tags => ["brand:$brand_name", "provider:$provider_name"]});
    }

    # login client to the system
    $c->session(_oneall_user_id => $user_id);
    return $c->redirect_to($redirect_uri);
}

# simple redirect since .html does not support POST from oneall
sub redirect {
    my $c                = shift;
    my $dir              = $c->param('dir') // '';
    my $connection_token = $c->param('connection_token') // $c->_get_provider_token() // '';

    return $c->redirect_to($dir . '?connection_token=' . $connection_token);
}

sub _get_provider_token {
    my $c = shift;

    my $request = URI->new($c->headers->{referer}[0]);

    return $request->query_param('provider_connection_token');
}

sub _get_email {
    my ($provider_data) = @_;

    # for Google
    my $emails = $provider_data->{user}->{identity}->{emails};
    return $emails->[0]->{value};    # or need check is_verified?
}

sub __create_virtual_user {
    my ($c, $email, $brand_name) = @_;

    my $acc = BOM::Platform::Account::Virtual::create_account({
            details => {
                email             => $email,
                client_password   => rand(999999),    # random password so you can't login without password
                has_social_signup => 1,
                brand_name        => $brand_name,
            },
        });
    die $acc->{error} if $acc->{error};

    return $acc->{user};
}

1;
