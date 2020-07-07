package BOM::OAuth::SingleSignOn;

use strict;
use warnings;

no indirect;

use Mojo::Base 'Mojolicious::Controller';
use Mojo::Parameters;

use URI;
use Format::Util::Strings qw( defang );
use Digest::SHA qw(hmac_sha256_hex);
use Encode qw(encode);
use Log::Any qw($log);

use BOM::User::Client;
use BOM::Database::Model::OAuth;

# Developer disclaimer: we needed this fast

sub authorize {
    my $c = shift;

    my $service  = defang($c->stash('service'));
    my $auth_url = $c->req->url->path('/oauth2/authorize')->to_abs;

    my $app_id = defang($c->param('app_id'));
    my $app    = BOM::Database::Model::OAuth->new()->verify_app($app_id);

    if ($app && $app->{name} eq $service) {

        my %info = _verify_sso_request($c, $app);
        $c->session(%info);

        $auth_url->query(app_id => $app->{id});
        $c->redirect_to($auth_url);

    } else {
        my $brand_uri = Mojo::URL->new($c->stash('brand')->default_url);
        $c->redirect_to($brand_uri);
    }
}

sub create {
    my $c = shift;

    my $service = defang($c->stash('service'));
    my $app_id  = defang($c->param('app_id'));

    my $app = BOM::Database::Model::OAuth->new()->verify_app($app_id);

    if ($app && $app->{name} eq $service) {

        my $uri = Mojo::URL->new($app->{verification_uri});
        my %params = _sso_params($c, $app);
        $uri->query(%params);

        $c->redirect_to($uri);
    }
}

sub _verify_sso_request {
    my ($c, $app) = @_;

    my ($payload, $sig) = map { defang($c->param($_)) // undef } qw/ sso sig /;

    if (hmac_sha256_hex($payload, $app->{secret}) eq $sig) {

        # Discourse sends the params as base64 URL encoded string
        if ($app->{name} eq 'discourse') {
            my $discourse_data = Mojo::Parameters->new()->parse(MIME::Base64::decode_base64($payload))->to_hash();
            return ('_sso_nonce' => $discourse_data->{nonce});
        }

    } else {
        $log->debugf("Can't verify %s sso request check the application secret", $app->{name});
    }

}

sub _sso_params {
    my ($c, $app) = @_;

    my $nonce   = defang($c->param('nonce'));
    my $loginid = defang($c->param('acct1'));

    my $client = BOM::User::Client->new({
        loginid      => $loginid,
        db_operation => 'replica'
    });

    if ($app->{name} eq 'discourse') {

        my $discourse_params = {
            nonce                    => $nonce,
            email                    => $client->user->email,
            external_id              => $client->binary_user_id,
            username                 => $client->loginid,
            name                     => $client->first_name . ' ' . $client->last_name,
            avatar_url               => '',
            bio                      => '',
            admin                    => 0,
            moderator                => 0,
            suppress_welcome_message => 0
        };

        my $payload = URI->new('', 'http');
        $payload->query_form(%$discourse_params);
        $payload = $payload->query;

        $payload = MIME::Base64::encode_base64(encode('UTF-8', $payload), '');
        my $sig = hmac_sha256_hex($payload, $app->{secret});

        return (
            sso => $payload,
            sig => $sig
        );
    }
}

1;
