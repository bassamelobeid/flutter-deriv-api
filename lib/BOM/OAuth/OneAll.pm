package BOM::OAuth::OneAll;

use v5.10;
use Mojo::Base 'Mojolicious::Controller';
use WWW::OneAll;
use BOM::Platform::Context qw(localize);
use BOM::Database::Model::UserConnect;

sub callback {
    my $c = shift;

    my $redirect_uri = $c->req->url->to_string; # redirect to /authorize
    my $connection_token = $c->param('connection_token') // '';
    unless ($connection_token) {
        return $c->redirect_to($redirect_uri);
    }

    my $oneall = WWW::OneAll->new(
        subdomain   => 'binary',
        public_key  => '48a20118-629b-4020-83fe-38af46e27b06',
        private_key => '1970bcf0-a7ec-48f5-b9bc-737eb74146a4',
    );
    my $data = $oneall->connection($connection_token) or die $oneall->errstr;

    if ($data->{response}->{request}->{status} != 200) {
        $c->session(__oneall_error => localize('Failed to get user identity.'));
        return $c->redirect_to( $redirect_uri );
    }

    my $provider_data = $data->{response}->{result}->{data};
    my $user_connect  = BOM::Database::Model::UserConnect->new;
    my $user_id       = $user_connect->get_user_id_by_connect($provider_data);

    unless ($user_id) {
        $c->session(__oneall_error => localize('User is not connected.'));
        return $c->redirect_to( $redirect_uri );
    }

    ## login him in
    $c->session(__oneall_user_id => $user_id);
    return $c->redirect_to( $redirect_uri );
}

1;
