package BOM::OAuth::OneAll;

use v5.10;
use Mojo::Base 'Mojolicious::Controller';
use WWW::OneAll;

sub callback {
    my $c = shift;

    my $connection_token = $c->param('connection_token') // '';
    unless ($connection_token) {
        return $c->redirect_to('/authorize');
    }

    my $oneall = WWW::OneAll->new(
        subdomain   => 'binary',
        public_key  => '48a20118-629b-4020-83fe-38af46e27b06',
        private_key => '1970bcf0-a7ec-48f5-b9bc-737eb74146a4',
    );
    my $data = $oneall->connection($connection_token) or die $oneall->errstr;

    $c->render(text => Dumper(\$data)); use Data::Dumper; # DEBUG
}

1;
