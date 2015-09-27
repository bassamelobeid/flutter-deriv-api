package BOM::OAuth::C;

use Mojo::Base 'Mojolicious::Controller';

use BOM::Platform::Client;
use Date::Utility;

sub authorize {
    my $c = shift;

    my ($client_id, $redirect_uri, $scope, $state) = map { $c->param($_) // undef } qw/ client_id redirect_uri scope state /;

    my $response_type = 'code';                             # only support code
    my @scopes = $scope ? split(/[\s\,\+]/, $scope) : ();

    $client_id or return $c->__bad_request('the request was missing client_id');

    my $uri = Mojo::URL->new($redirect_uri);
    my ($status, $error) = $c->__verify_client($client_id, @scopes);
    if (!$status) {
        $error ||= 'server_error';
        $uri->query->append(error => $error);
        $uri->query->append(state => $state) if defined($state);
        return $c->redirect_to($uri);
    }

    ## check user is logined
    my $client = $c->__get_client;
    if (!$client) {
        # we need to redirect back to the /oauth/authorize route after
        # login (with the original params)
        my $uri = join('?', $c->url_for('current'), $c->url_with->query);
        $c->flash('redirect_after_login' => $uri);
        $c->redirect_to('https://www.binary.com/login?redirect_uri=oauth');
    }

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

sub __verify_client {
    my ($c, $client_id, @scopes) = @_;

    my $dbh = $c->rose_db->dbh;
    my $client = $dbh->selectrow_hashref("SELECT secret FROM auth.oauth2_client WHERE id = ? AND active", undef, $client_id);
    return (0, 'unauthorized_client') unless $client;

    foreach my $rqd_scope (@scopes) {
        my $scope = $dbh->selectrow_hashref("
            SELECT cs.allowed FROM auth.oauth2_client_scope cs ON auth.oauth2_scope s ON cs.scope_id=s.id
            WHERE cs.client_id = ? AND s.scope = ?
        ", undef, $client_id, $rqd_scope);
        $scope            or return (0, 'invalid_scope');
        $scope->{allowed} or return (0, 'access_denied');
    }

    return (1);
}

sub __bad_request {
    my ($c, $error) = @_;

    return $c->render(
        status => 400,
        json   => {
            error             => 'invalid_request',
            error_description => $error,
            error_uri         => '',
        });
}

1;
