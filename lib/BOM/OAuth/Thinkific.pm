package BOM::OAuth::Thinkific;

use strict;
use warnings;
use Mojo::Base 'Mojolicious::Controller';
use Format::Util::Strings qw( defang );
use JSON::MaybeXS;
use Encode qw(encode);
use JSON::WebToken;
use BOM::User::Client;
use BOM::Database::Model::OAuth;
use BOM::Config;
use Syntax::Keyword::Try;
use Log::Any qw($log);

=head2 create

Handles the creation of a Thinkific SSO URI for a given app and token.

Expects the following parameters:

=over

=item * C<app_id> - The ID of the app.

=item * C< token1> - The token.

=back

If the app and token are valid, constructs a Thinkific SSO URI and redirects the user to it. Otherwise, throws an error.

=cut

sub create {
    my $c = shift;

    my $app_id = defang($c->param('app_id'));
    my $token  = defang($c->param('token1'));

    try {
        my $app     = BOM::Database::Model::OAuth->new()->verify_app($app_id);
        my $loginid = BOM::Database::Model::OAuth->new()->get_token_details($token)->{loginid};
        my $error_message;

        if (!$loginid) {
            $error_message = 'The request was missing a valid loginId';
            $log->error($error_message);
            $c->throw_error('invalid_request', 'The request was missing a valid loginId');
        } elsif (!$app) {
            $error_message = 'The request was missing a valid app_id';
            $log->error($error_message);
            $c->throw_error('invalid_request', 'The request was missing a valid app_id');
        } else {
            my $client = BOM::User::Client->new({
                loginid      => $loginid,
                db_operation => 'replica',
            });

            my $uri = _thinkific_uri_constructor($c, $app, $client);
            $c->redirect_to($uri);
        }
    } catch {
        my $brand_uri = Mojo::URL->new($c->stash('brand')->default_url);
        $c->redirect_to($brand_uri);
    };
}

=head2 _thinkific_uri_constructor

Constructs the Thinkific SSO URI with the given client and app.   

Returns a Mojo::URL object with the Thinkific SSO URI.

=cut

sub _thinkific_uri_constructor {
    my ($c, $app, $client) = @_;
    my $thinkific_configs = BOM::Config::thinkific_config();

    my $uri     = Mojo::URL->new($thinkific_configs->{thinkific_redirect_uri});
    my $payload = _thinkific_sso_params($client);

    my $thinkific_jwt = encode_jwt $payload, $thinkific_configs->{thinkific_api_key};

    return $uri->query(jwt => $thinkific_jwt);

}

=head2 _thinkific_sso_params

Constructs the payload for the Thinkific SSO URI with the given client.

Returns a hashref containing the following keys:
- first_name: The first name of the client.
- last_name: The last name of the client.
- email: The email address of the client's user.
- iat: The current Unix timestamp.
- external_id: The binary user ID of the client.

=cut

sub _thinkific_sso_params {
    my ($client) = @_;

    return {
        first_name  => $client->first_name || 'Deriv',
        last_name   => $client->last_name  || 'Trader',
        email       => $client->user->email,
        iat         => time,
        external_id => $client->binary_user_id,
    };
}

1;
