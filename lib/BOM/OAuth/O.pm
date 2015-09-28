package BOM::OAuth::C;

use Mojo::Base 'Mojolicious::Controller';

use BOM::Platform::Client;
use Date::Utility;
use Data::UUID;

sub authorize {
    my $c = shift;

    my ($client_id, $redirect_uri, $scope, $state) = map { $c->param($_) // undef } qw/ client_id redirect_uri scope state /;

    my $response_type = 'code';                             # only support code
    my @scopes = $scope ? split(/[\s\,\+]/, $scope) : ();

    $client_id or return $c->__bad_request('the request was missing client_id');

    my $uri = Mojo::URL->new($redirect_uri);
    my ($status, $error_or_application) = $c->__verify_client($client_id, @scopes);
    if (!$status) {
        $error_or_application ||= 'server_error';
        $uri->query->append(error => $error_or_application);
        $uri->query->append(state => $state) if defined($state);
        return $c->redirect_to($uri);
    }

    ## check user is logined
    my $client = $c->__get_client;
    if (! $client) {
        # we need to redirect back to the /oauth/authorize route after
        # login (with the original params)
        my $uri = join('?', $c->url_for('current'), $c->url_with->query);
        $c->flash('redirect_after_login' => $uri);
        return $c->redirect_to('https://www.binary.com/login?redirect_uri=oauth');
    }

    my $loginid = $client->loginid;

    ## confirm scopes (FIXME, csrf_token)
    my $is_all_approved = 0;
    if ($c->req->method eq 'POST' and $c->param('confirm_scopes')) {
        $c->__confirm_scope($client_id, $loginid, @scopes);
        $is_all_approved = 1;
    }

    ## check if it's confirmed
    $is_all_approved ||= $c->__is_scope_confirmed($client_id, $loginid, @scopes);
    unless ($is_all_approved) {
        ## show scope confirms
        return $self->render(
            template => 'scope_confirms',
            layout   => $self->layout,

            application => $error_or_application,
            client => $client,
            scopes => \@scopes,

        );
    }

    ## everything is good
    my $expires_in = 3600; # default to 1 hour expires
    my $auth_code = Data::UUID->new()->create_str();

    $c->__store_auth_code($client_id, $loginid, $auth_code, $expires_in, @scopes);
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
    my $client = $dbh->selectrow_hashref("SELECT * FROM auth.oauth_client WHERE id = ? AND active", undef, $client_id);
    return (0, 'unauthorized_client') unless $client;

    foreach my $rqd_scope (@scopes) {
        my $scope = $dbh->selectrow_hashref("
            SELECT cs.allowed FROM auth.oauth_client_scope cs ON auth.oauth_scope s ON cs.scope_id=s.id
            WHERE cs.client_id = ? AND s.scope = ?
        ", undef, $client_id, $rqd_scope);
        $scope            or return (0, 'invalid_scope');
        $scope->{allowed} or return (0, 'access_denied');
    }

    return (1, $client);
}

sub __is_scope_confirmed {
    my ($client_id, $loginid, @scopes) = @_;

    my $dbh = $c->rose_db->dbh;
    my $sth = $dbh->prepare("
        SELECT 1 FROM auth.oauth_scope_confirms JOIN auth.oauth_scope ON oauth_scope_confirms.scope_id=scope.id
        WHERE client_id = ? AND loginid = ? AND scope.scope = ?
    ");

    foreach my $scope (@scopes) {
        $sth->execute($client_id, $loginid, $scope);
        my ($is_approved) = $sth->fetchrow_array;
        return 0 unless $is_approved;
    }

    return 1;
}

sub __confirm_scope {
    my ($client_id, $loginid, @scopes) = @_;

    my $dbh = $c->rose_db->dbh;
    my $get_scope_sth = $dbh->prepare("SELECT id FROM auth.oauth_scope WHERE scope = ?");
    my $insert_sth = $dbh->prepare("
       INSERT INTO auth.oauth_scope_confirms (client_id, loginid, scope_id) VALUES (?, ?, ?)
    ");

    foreach my $scope (@scopes) {
        $get_scope_sth->execute($scope);
        my ($scope_id) = $get_scope_sth->fetchrow_array;
        next unless $scope_id;
        $insert_sth->execute($client_id, $loginid, $scope_id);
    }

    return 1;
}

sub __store_auth_code {
    my ($client_id, $loginid, $auth_code, $expires_in, @scopes) = @_;

    my $dbh = $c->rose_db->dbh;
    my $get_scope_sth = $dbh->prepare("SELECT id FROM auth.oauth_scope WHERE scope = ?");


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
