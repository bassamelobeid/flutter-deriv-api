package BOM::OAuth::O;

use Mojo::Base 'Mojolicious::Controller';
use Date::Utility;
use BOM::Platform::Client;
use BOM::Database::Model::OAuth;

sub __oauth_model {
    state $oauth_model = BOM::Database::Model::OAuth->new;
    return $oauth_model;
}

sub authorize {
    my $c = shift;

    my ($client_id, $redirect_uri, $state) = map { $c->param($_) // undef } qw/ client_id redirect_uri state /;

    $client_id    or return $c->__bad_request('the request was missing client_id');
    $redirect_uri or return $c->__bad_request('the request was missing redirect_uri');

    ## The redirection endpoint URI MUST be an absolute URI
    my $uri = Mojo::URL->new($redirect_uri);
    $uri->host or return $c->__bad_request('invalid redirect_uri');

    my $oauth_model = __oauth_model();
    my $app_client  = $oauth_model->verify_client($client_id);
    unless ($app_client) {
        $uri->query->append('error' => 'invalid_client');
        $uri->query->append(state => $state) if defined $state;
        return $c->redirect_to($uri);
    }

    ## check user is logined
    my $client = $c->__get_client;
    unless ($client) {
        # we need to redirect back to oauth/authorize after
        # login (with the original params)
        my $query = $c->url_with->query;
        $c->session('oauth_authorize_query' => $query);
        return $c->redirect_to('/login');
    }

    my $loginid = $client->loginid;
    my $auth_code = $oauth_model->store_auth_code($client_id, $loginid);

    $uri->query->append(code => $auth_code);
    $uri->query->append(state => $state) if defined $state;

    $c->redirect_to($uri);
}

sub access_token {
    my $c = shift;

    my ($client_id, $client_secret, $grant_type, $auth_code, $refresh_token) =
        map { $c->param($_) // undef } qw/ client_id client_secret grant_type code refresh_token /;

    $client_id or return $c->__bad_request('the request was missing client_id');

    # grant_type=authorization_code, plus auth_code
    # grant_type=refresh_token, plus refresh_token
    (grep { $_ eq $grant_type } ('authorization_code', 'refresh_token'))
        or return $c->__bad_request('the request was missing valid grant_type');
    ($grant_type eq 'authorization_code' and not $auth_code)
        and return $c->__bad_request('the request was missing code');
    ($grant_type eq 'refresh_token' and not $refresh_token)
        and return $c->__bad_request('the request was missing refresh_token');

    my $oauth_model = __oauth_model();

    my $app_client = $oauth_model->verify_client($client_id);
    unless ($app_client and $app_client->{secret} eq $client_secret) {
        return $c->throw_error('invalid_client');
    }

    my $loginid;
    if ($grant_type eq 'refresh_token') {
        $loginid = $oauth_model->verify_refresh_token($client_id, $refresh_token);
    } else {
        ## authorization_code
        $loginid = $oauth_model->verify_auth_code($client_id, $auth_code);
    }
    if (!$loginid) {
        return $c->throw_error('invalid_grant');
    }

    my ($access_token, $refresh_token_new, $expires_in) = $oauth_model->store_access_token($client_id, $loginid);

    $c->render(
        json => {
            access_token  => $access_token,
            token_type    => 'Bearer',
            expires_in    => $expires_in,
            refresh_token => $refresh_token_new,
        });
}

sub __get_client {
    my $c = shift;

    my $request        = $c->stash('request');       # from before_dispatch
    my $session_cookie = $request->session_cookie;
    return unless $session_cookie and $session_cookie->token;

    my $client = BOM::Platform::Client->new({loginid => $session_cookie->loginid});
    return if $client->get_status('disabled');

    if ($client->get_self_exclusion and $client->get_self_exclusion->exclude_until) {
        my $limit_excludeuntil = $client->get_self_exclusion->exclude_until;
        if (Date::Utility->new->is_before(Date::Utility->new($limit_excludeuntil))) {
            return;
        }
    }

    return $client;
}

sub __bad_request {
    my ($c, $error) = @_;

    return $c->throw_error('invalid_request', $error);
}

1;
