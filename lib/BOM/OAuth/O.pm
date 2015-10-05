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
    if (!$client) {
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
            client      => $client,
            scopes      => \@scopes,

        );
    }

    ## everything is good
    my $expires_in = 600;
    my $auth_code  = Data::UUID->new()->create_str();

    $c->__store_auth_code($client_id, $loginid, $auth_code, $expires_in, $redirect_uri, @scopes);

    $uri->query->append(code => $auth_code);
    $uri->query->append(state => $state) if defined($state);

    $c->redirect_to($uri);
}

sub access_token {
    my $c = shift;

    my ($client_id, $client_secret, $grant_type, $auth_code, $redirect_uri, $refresh_token) =
        map { $self->param($_) // undef } qw/ client_id client_secret grant_type code redirect_uri refresh_token /;

    $client_id or return $c->__bad_request('the request was missing client_id');

    # grant_type=authorization_code, plus auth_code
    # grant_type=refresh_token, plus refresh_token
    (grep { $_ eq $grant_type } ('authorization_code', 'refresh_token'))
        or return $c->__bad_request('the request was missing valid grant_type');
    ($grant_type eq 'authorization_code' and not $auth_code)
        or return $c->__bad_request('the request was missing code');
    ($grant_type eq 'refresh_token' and not $auth_code)
        or return $c->__bad_request('the request was missing refresh_token');

    my $uri = Mojo::URL->new($redirect_uri);
    my ($status, $error_or_application) = $c->__verify_client($client_id);
    if ($status and $error_or_application->{client_secret} ne $client_secret) {
        $status               = 0;
        $error_or_application = 'unauthorized_client';
    }
    if (!$status) {
        $error_or_application ||= 'server_error';
        $uri->query->append(error => $error_or_application);
        return $c->redirect_to($uri);
    }

    my $loginid;
    my @scope_ids;
    if ($grant_type eq 'refresh_token') {
        # TODO
    } else {
        ## authorization_code
        ($status, $error, $loginid, @scope_ids) = $c->__verify_auth_code($error_or_application, $auth_code, $redirect_uri);
    }

    if (!$status) {
        return $c->__bad_request($error);    # FIXME
    }

    ## everything is good
    my $expires_in    = 3600;
    my $access_token  = Data::UUID->new()->create_str();
    my $refresh_token = Data::UUID->new()->create_str();

    $c->__store_access_token($client_id, $loginid, $access_token, $refresh_token, $expires_in, @scope_ids);
    $c->render(
        json => {
            access_token  => $access_token,
            token_type    => 'Bearer',
            expires_in    => $expires_in,
            refresh_token => $refresh_token,
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

    my $dbh           = $c->rose_db->dbh;
    my $get_scope_sth = $dbh->prepare("SELECT id FROM auth.oauth_scope WHERE scope = ?");
    my $insert_sth    = $dbh->prepare("
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
    my ($client_id, $loginid, $auth_code, $expires_in, $redirect_uri, @scopes) = @_;

    my $dbh = $c->rose_db->dbh;

    my $expires_time = Date::Utility->new({epoch => (Date::Utility->new->epoch + $expires_in)})->datetime_yyyymmdd_hhmmss;    # 10 minutes max
    $dbh->do("INSERT INTO auth.oauth_auth_code (auth_code, client_id, loginid, expires, redirect_uri, verified) VALUES (?, ?, ?, ?, ?, false)",
        undef, $auth_code, $client_id, $loginid, $expires_time, $redirect_uri);

    my $get_scope_sth    = $dbh->prepare("SELECT id FROM auth.oauth_scope WHERE scope = ?");
    my $insert_scope_sth = $dbh->prepare("INSERT INTO auth.oauth_auth_code_scope (auth_code, scope_id) VALUES (?, ?)");
    foreach my $scope (@scopes) {
        $get_scope_sth->execute($scope);
        my ($scope_id) = $get_scope_sth->fetchrow_array;
        next unless $scope_id;
        $insert_scope_sth->execute($auth_code, $scope_id);
    }

    return;
}

sub __verify_auth_code {
    my ($c, $application, $auth_code, $redirect_uri) = @_;

    my $dbh = $c->rose_db->dbh;

    my $auth_row = $dbh->selectrow_hashref("
        SELECT * FROM auth.oauth_auth_code WHERE auth_code = ? AND client_id = ?
    ", undef, $auth_code, $application->{id});

    return (0, 'invalid_grant') unless $auth_row;
    return (0, 'invalid_grant') if $auth_row->{verified};
    return (0, 'invalid_grant') if $auth_row->{redirect_uri} ne $redirect_uri;
    return (0, 'invalid_grant') unless Date::Utility->new->is_before(Date::Utility->new($auth_row->{expires}));

    $dbh->do("UPDATE auth.oauth_auth_code SET verified=true WHERE auth_code = ?", undef, $auth_code);

    my @scope_ids;
    my $sth = $dbh->prepare("SELECT scope_id FROM auth.oauth_auth_code_scope WHERE auth_code = ?");
    $sth->execute($auth_code);
    while (my ($sid) = $sth->fetchrow_array) {
        push @scope_ids;
    }

    return (1, undef, $auth_row->{loginid}, @scope_ids);
}

sub __store_access_token {
    my ($c, $client_id, $loginid, $access_token, $refresh_token, $expires_in, @scope_ids) = @_;

    my $dbh = $c->rose_db->dbh;

    my $expires_time = Date::Utility->new({epoch => (Date::Utility->new->epoch + $expires_in)})->datetime_yyyymmdd_hhmmss;    # 10 minutes max
    $dbh->do("INSERT INTO auth.oauth2_access_token (access_token, refresh_token, client_id, loginid, expires) VALUES (?, ?, ?, ?, ?)",
        undef, $access_token, $refresh_token, $client_id, $loginid, $expires_time);

    $dbh->do("INSERT INTO auth.oauth2_access_token (access_token, refresh_token, client_id, loginid, expires) VALUES (?, ?, ?, ?, ?)",
        undef, $access_token, $refresh_token, $client_id, $loginid, $expires_time);

    $dbh->do("INSERT INTO auth.oauth2_refresh_token (access_token, refresh_token, client_id, loginid) VALUES (?, ?, ?, ?, ?)",
        undef, $access_token, $refresh_token, $client_id, $loginid);

    foreach my $related ('access_token', 'refresh_token') {
        my $insert_sth = $dbh->prepare("INSERT INTO auth.oauth2_${related}_scope ($related, scope_id) VALUES (?, ?)");
        foreach my $scope_id (@scope_ids) {
            $insert_sth->execute($related eq 'access_token' ? $access_token : $refresh_token, $scope_id);
        }
    }
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
