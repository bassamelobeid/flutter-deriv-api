package BOM::OAuth::O;

use Mojo::Base 'Mojolicious::Controller';
use Date::Utility;
use BOM::Platform::Client;
use BOM::Platform::User;
use BOM::Database::Model::OAuth;
use BOM::Platform::Context qw(localize);

sub __oauth_model {
    state $oauth_model = BOM::Database::Model::OAuth->new;
    return $oauth_model;
}

sub authorize {
    my $c = shift;

    my ($app_id, $state, $response_type) = map { $c->param($_) // undef } qw/ app_id state response_type /;

    # $response_type ||= 'code';    # default to Authorization Code
    $response_type = 'token';    # only support token

    $app_id or return $c->__bad_request('the request was missing app_id');

    my $oauth_model = __oauth_model();
    my $app         = $oauth_model->verify_app($app_id);
    unless ($app) {
        return $c->__bad_request('the request was missing valid app_id');
    }

    my @scopes          = @{$app->{scopes}};
    my $redirect_uri    = $app->{redirect_uri};
    my $redirect_handle = sub {
        my ($response_type, $error, $state) = @_;

        my $uri = Mojo::URL->new($redirect_uri);
        $uri .= '#error=' . $error;
        $uri .= '&state=' . $state if defined $state;
        return $uri;
    };

    ## check user is logined
    my $client = $c->__get_client;
    unless ($client) {
        # we need to redirect back to oauth/authorize after
        # login (with the original params)
        my $query = $c->url_with->query;
        $c->session('oauth_authorize_query' => $query);
        return $c->redirect_to('/oauth2/login');
    }

    my $loginid = $client->loginid;
    my $user    = BOM::Platform::User->new({email => $client->email}) or die "no user for email " . $client->email;

    ## confirm scopes
    my $is_all_approved = 0;
    if ($c->req->method eq 'POST' and ($c->csrf_token eq ($c->param('csrftoken') // ''))) {
        if ($c->param('confirm_scopes')) {
            ## approval on all loginids
            foreach my $c1 ($user->clients) {
                $is_all_approved = $oauth_model->confirm_scope($app_id, $c1->loginid);
            }
        } else {
            my $uri = $redirect_handle->($response_type, 'scope_denied', $state);
            return $c->redirect_to($uri);
        }
    }

    ## check if it's confirmed
    $is_all_approved ||= $oauth_model->is_scope_confirmed($app_id, $loginid);
    unless ($is_all_approved) {
        ## show scope confirms
        return $c->render(
            template => 'scope_confirms',
            layout   => 'default',

            app       => $app,
            client    => $client,
            scopes    => \@scopes,
            csrftoken => $c->csrf_token,
        );
    }

    my $uri = Mojo::URL->new($redirect_uri);

    ## create tokens for all loginids
    my $i = 1;
    my @accts;
    foreach my $c1 ($user->clients) {
        my ($access_token, $expires_in) = $oauth_model->store_access_token_only($app_id, $c1->loginid, @scopes);
        push @accts, 'acct' . $i . '=' . $c1->loginid . '&token' . $i . '=' . $access_token;
        $i++;
    }

    $uri .= '#' . join('&', @accts);
    $uri .= '&state=' . $state if defined $state;

    $c->redirect_to($uri);
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

sub login {
    my $c = shift;

    return $c->render(
        template => 'login',
        layout   => 'default',
        title    => localize('Login to Binary'),
    );
}

1;
