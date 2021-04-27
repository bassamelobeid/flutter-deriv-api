package BOM::OAuth::RestAPI;

use strict;
use warnings;
no indirect;

=head1 NAME

BOM::OAuth::RestAPI - JSON Rest API for application and user authentication

=head1 DESCRIPTION

Implementation based on the following spec: https://wikijs.deriv.cloud/en/Backend/architecture/proposal/bom_oauth_rest_api

=cut

use Mojo::Base 'Mojolicious::Controller';
use Digest::SHA qw(hmac_sha256_hex);
use JSON::MaybeXS;
use JSON::WebToken;
use Format::Util::Strings qw(defang);

# Challenge takes 10 minutes (600 seconds amirite) to expire.
use constant CHALLENGE_TIMEOUT => 600;

# JWT takes 10 minutes (600 seconds amirite) to expire.
use constant JWT_TIMEOUT => 600;

=head2 verify

This endpoint generates a challenge for the application's authentication attempt

It takes the following JSON payload:

=over 4

=item * C<app_id> the numeric application id being authenticated

=back

It renders a JSON with the following structure:

=over 4

=item * C<challange> a challenge string for this authentication attempt

=item * C<expire> an expiration timestamp for this authentication attempt

=back

=cut

sub verify {
    my $c      = shift;
    my $app_id = defang($c->req->json->{app_id}) or return $c->_unauthorized;
    my $expire = time + CHALLENGE_TIMEOUT;
    my $model  = BOM::Database::Model::OAuth->new();

    return $c->_unauthorized unless $model->is_official_app($app_id);

    $c->render(
        json => {
            challenge => $c->_challenge($app_id, $expire),
            expire    => $expire,
        },
        status => 200
    );
}

=head2 authorize

This endpoint authorizes those requests that send a valid solution for the challenge.

It takes a JSON payload as:

=over 4

=item * C<solution> the string that solves the challenge

=item * C<app_id> the application id being authenticated

=item * C<expire> the expiration timestamp of the authentication attempt

=back

It renders a JSON with the following structure:

=over 4

=item * C<token> a JWT that authorizes the application

=back

=cut

sub authorize {
    my $c = shift;

    my $app_id = defang($c->req->json->{app_id}) or return $c->_unauthorized;
    my $expire = defang($c->req->json->{expire}) or return $c->_unauthorized;

    return $c->_unauthorized if time > $expire;

    my $model = BOM::Database::Model::OAuth->new();

    return $c->_unauthorized unless $model->verify_app($app_id);
    return $c->_unauthorized unless $model->is_official_app($app_id);

    my $solution  = defang($c->req->json->{solution});
    my $tokens    = $model->get_app_tokens($app_id);
    my $challenge = $c->_challenge($app_id, $expire);

    for my $token ($tokens->@*) {
        my $expected = hmac_sha256_hex($challenge, $token);

        if ($expected eq $solution) {
            return $c->render(
                json   => {token => $c->_jwt_token($app_id)},
                status => 200,
            );
        }
    }

    return $c->_unauthorized;
}

=head2 _jwt_token

Computes a JWT token for the given application.

It takes the following arguments:

=over 4

=item * C<$app_id> the given application id

=back

Returns a valid expirable JWT.

=cut

sub _jwt_token {
    my ($c, $app_id) = @_;

    my $claims = {
        app => $app_id,
        sub => 'auth',
        exp => time + JWT_TIMEOUT,
    };

    return encode_jwt $claims, $c->_secret();
}

=head2 _challenge

Computes an HMAC challenge.

It takes the following arguments:

=over 4

=item C<$app_id> the numeric application id for this challenge

=item C<$expire> the expiration timestamp for this challenge

=back

Returns a sha256 hex string.

=cut

sub _challenge {
    my ($c, $app_id, $expire) = @_;
    my $payload = join ',', $app_id, $expire;
    return hmac_sha256_hex($payload, $c->_secret());
}

=head2 _unauthorized

Helper that renders a generic 401 http status response.

=cut

sub _unauthorized {
    my $c = shift;
    return $c->render(
        json   => undef,
        status => 401,
    );
}

=head2 _secret 

Helper that retrieves the current secret for hmac signing.

=cut

sub _secret {
    my $c = shift;

    return $c->app->secrets->@[0] // 'dummy';
}

1
