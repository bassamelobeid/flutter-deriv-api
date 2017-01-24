package BOM::OAuth::OneAll;

use v5.10;
use Mojo::Base 'Mojolicious::Controller';
use WWW::OneAll;
use BOM::System::Config;
use BOM::Platform::Context qw(localize);
use BOM::Database::Model::UserConnect;
use BOM::Platform::User;
use BOM::Platform::Account::Virtual;

sub callback {
    my $c = shift;

    my $redirect_uri = $c->req->url->path('/oauth2/authorize')->to_abs;

    my $connection_token = $c->param('connection_token') // '';
    unless ($connection_token) {
        return $c->redirect_to($redirect_uri);
    }

    my $oneall = WWW::OneAll->new(
        subdomain   => 'binary',
        public_key  => BOM::System::Config::third_party->{oneall}->{public_key},
        private_key => BOM::System::Config::third_party->{oneall}->{private_key},
    );
    my $data = $oneall->connection($connection_token) or die $oneall->errstr;

    if ($data->{response}->{result}->{status}->{code} != 200) {
        $c->session(_oneall_error => localize('Failed to get user identity.'));
        return $c->redirect_to($redirect_uri);
    }

    my $provider_data = $data->{response}->{result}->{data};
    my $user_connect  = BOM::Database::Model::UserConnect->new;
    my $user_id       = $user_connect->get_user_id_by_connect($provider_data);

    unless ($user_id) {
        my $email = __get_email($provider_data);
        my $user  = try {
            BOM::Platform::User->new({email => $email})
        };
        unless ($user) {
            # create user based on email by fly
            $user = $c->__create_virtual_user($email);
        }
        # connect it
        $user_connect->insert_connect($user->id, $provider_data);
        $user_id = $user->id;
    }

    ## login him in
    $c->session(_oneall_user_id => $user_id);
    return $c->redirect_to($redirect_uri);
}

# simple redirect since .html does not support POST from oneall
sub redirect {
    my $c = shift;

    my $dir = $c->param('dir') || 'https://www.binary.com/en/user/security/connections.html';
    my $connection_token = $c->param('connection_token') // '';

    return $c->redirect_to($dir . '?connection_token=' . $connection_token);
}

sub __get_email {
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
                client_password => $$ . rand(),
            },
        });
    die $acc->{error} if $acc->{error};

    return $acc->{user};
}

1;
