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

sub callback {
    my $c = shift;

    # Microsoft Edge and Internet Exporer browsers implementation has a drawback
    # in carrying parameters through responses. Hence, we are retrieving the token
    # from the stash.
    # For optimization reason, the URI should be contructed afterwards
    # if there is no token in request parameters found.
    my $connection_token = $c->param('connection_token')
        // URI->new($c->{stash}->{request}->{mojo_request}->{content}->{headers}->{headers}->{referer}[0])->query_param('provider_connection_token')
        // '';

    my $redirect_uri = $c->req->url->path('/oauth2/authorize')->to_abs;
    # redirect client to authorize subroutine if there is no connection token provided
    return $c->redirect_to($redirect_uri) unless $connection_token;

    my $oneall = WWW::OneAll->new(
        subdomain   => 'binary',
        public_key  => BOM::Platform::Config::third_party->{oneall}->{public_key},
        private_key => BOM::Platform::Config::third_party->{oneall}->{private_key},
    );
    my $data = $oneall->connection($connection_token) or die $oneall->errstr;
    # redirect client to auth page when recieving bad status code from oneall
    # wrong pub/private keys might be a reason of bad status code
    my $status_code = $data->{response}->{request}->{status}->{code};
    if ($status_code != 200) {
        $c->session(_oneall_error => localize('Failed to get user identity. Social signin service is currently unavailable.'));
        return $c->redirect_to($redirect_uri);
    }

    # retrieve user identity from provider data
    my $provider_data = $data->{response}->{result}->{data};
    my $user_connect  = BOM::Database::Model::UserConnect->new;
    my $user_id       = $user_connect->get_user_id_by_connect($provider_data);

    # Create virtual client if user not found
    # consequently initialize user_id and link account to social login.
    # Prevent clients in Japan create new account via social signin feature.
    # TODO deny Japan IP
    unless ($user_id) {
        my $email = _get_email($provider_data);
        my $user  = try {
            BOM::Platform::User->new({email => $email})
        };
        # create user based on email by fly unless already exists
        $user = $c->__create_virtual_user($email) unless $user;
        # connect oneall provider data to user identity
        $user_connect->insert_connect($user->id, $provider_data);
        $user_id = $user->id;
    }

    # login client to the system
    $c->session(_oneall_user_id => $user_id);
    return $c->redirect_to($redirect_uri);
}

# simple redirect since .html does not support POST from oneall
sub redirect {
    my $c                = shift;
    my $dir              = $c->param('dir') // '';
    my $connection_token = $c->param('connection_token')
        // URI->new($c->{stash}->{request}->{mojo_request}->{content}->{headers}->{headers}->{referer}[0])->query_param('provider_connection_token')
        // '';

    return $c->redirect_to($dir . '?connection_token=' . $connection_token);
}

sub _get_email {
    my ($provider_data) = @_;

    # for Google
    my $emails = $provider_data->{user}->{identity}->{emails};
    return $emails->[0]->{value};    # or need check is_verified?
}

sub __create_virtual_user {
    my ($c, $email) = @_;

    my $acc = BOM::Platform::Account::Virtual::create_account({
            details => {
                email           => $email,
                client_password => rand(999999),    # random password so you can't login without password
            },
        });
    die $acc->{error} if $acc->{error};

    # set social_signup flag
    $acc->{client}->set_status('social_signup', 'system', '1');
    $acc->{client}->save;

    return $acc->{user};
}

1;
