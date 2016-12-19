package BOM::OAuth::OneAll;

use v5.10;
use Mojo::Base 'Mojolicious::Controller';
use WWW::OneAll;
use BOM::System::Config;
use BOM::Platform::Context qw(localize);
use BOM::Database::Model::UserConnect;

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
        $c->session(_oneall_error => localize('User is not connected.'));
        return $c->redirect_to($redirect_uri);
    }

    ## login him in
    $c->session(_oneall_user_id => $user_id);
    return $c->redirect_to($redirect_uri);
}

1;
