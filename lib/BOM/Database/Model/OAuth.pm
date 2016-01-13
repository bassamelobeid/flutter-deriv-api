package BOM::Database::Model::OAuth;

use Moose;
use Date::Utility;
use String::Random ();
use BOM::Database::AuthDB;

has 'dbh' => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_dbh {
    return BOM::Database::AuthDB::rose_db->dbh;
}

## client
sub verify_client {
    my ($self, $client_id) = @_;

    return $self->dbh->selectrow_hashref("
        SELECT id, secret FROM oauth.clients WHERE id = ? AND active
    ", undef, $client_id);
}

sub confirm_scope {
    my ($self, $client_id, $loginid, @scopes) = @_;

    my $dbh           = $self->dbh;
    my $get_scope_sth = $dbh->prepare("SELECT id FROM oauth.scopes WHERE scope = ?");
    my $insert_sth    = $dbh->prepare("
       INSERT INTO oauth.user_scope_confirm (client_id, loginid, scope_id) VALUES (?, ?, ?)
    ");

    foreach my $scope (@scopes) {
        $get_scope_sth->execute($scope);
        my ($scope_id) = $get_scope_sth->fetchrow_array;
        next unless $scope_id;
        $insert_sth->execute($client_id, $loginid, $scope_id);
    }

    return 1;
}

sub is_scope_confirmed {
    my ($self, $client_id, $loginid, @scopes) = @_;

    my $dbh = $self->dbh;
    my $sth = $dbh->prepare("
        SELECT 1 FROM oauth.user_scope_confirm JOIN oauth.scopes ON user_scope_confirm.scope_id=scopes.id
        WHERE client_id = ? AND loginid = ? AND scopes.scope = ?
    ");

    foreach my $scope (@scopes) {
        $sth->execute($client_id, $loginid, $scope);
        my ($is_approved) = $sth->fetchrow_array;
        return 0 unless $is_approved;
    }

    return 1;
}

## store auth code
sub store_auth_code {
    my ($self, $client_id, $loginid, @scopes) = @_;

    my $dbh          = $self->dbh;
    my $auth_code    = String::Random::random_regex('[a-zA-Z0-9]{32}');
    my $expires_time = Date::Utility->new({epoch => (Date::Utility->new->epoch + 600)})->datetime_yyyymmdd_hhmmss;    # 10 minutes max
    $dbh->do("INSERT INTO oauth.auth_code (auth_code, client_id, loginid, expires, verified) VALUES (?, ?, ?, ?, false)",
        undef, $auth_code, $client_id, $loginid, $expires_time);

    my $get_scope_sth    = $dbh->prepare("SELECT id FROM oauth.scopes WHERE scope = ?");
    my $insert_scope_sth = $dbh->prepare("INSERT INTO oauth.auth_code_scope (auth_code, scope_id) VALUES (?, ?)");
    foreach my $scope (@scopes) {
        $get_scope_sth->execute($scope);
        my ($scope_id) = $get_scope_sth->fetchrow_array;
        next unless $scope_id;
        $insert_scope_sth->execute($auth_code, $scope_id);
    }

    return $auth_code;
}

## validate auth code
sub verify_auth_code {
    my ($self, $client_id, $auth_code) = @_;

    my $dbh = $self->dbh;

    my $auth_row = $dbh->selectrow_hashref("
        SELECT * FROM oauth.auth_code WHERE auth_code = ? AND client_id = ? AND NOT verified
    ", undef, $auth_code, $client_id);

    return unless $auth_row;
    return unless Date::Utility->new->is_before(Date::Utility->new($auth_row->{expires}));

    # set verified to avoid code-reuse
    $dbh->do("UPDATE oauth.auth_code SET verified=true WHERE auth_code = ?", undef, $auth_code);

    return $auth_row->{loginid};
}

sub get_scope_ids_by_auth_code {
    my ($self, $auth_code) = @_;

    my @scope_ids;
    my $sth = $self->dbh->prepare("SELECT scope_id FROM oauth.auth_code_scope WHERE auth_code = ?");
    $sth->execute($auth_code);
    while (my ($sid) = $sth->fetchrow_array) {
        push @scope_ids, $sid;
    }
    return @scope_ids;
}

## store access token
sub store_access_token {
    my ($self, $client_id, $loginid, @scope_ids) = @_;

    my $dbh           = $self->dbh;
    my $expires_in    = 3600;
    my $access_token  = 'a1-' . String::Random::random_regex('[a-zA-Z0-9]{29}');
    my $refresh_token = 'r1-' . String::Random::random_regex('[a-zA-Z0-9]{29}');

    my $expires_time = Date::Utility->new({epoch => (Date::Utility->new->epoch + $expires_in)})->datetime_yyyymmdd_hhmmss;    # 10 minutes max
    $dbh->do("INSERT INTO oauth.access_token (access_token, client_id, loginid, expires) VALUES (?, ?, ?, ?)",
        undef, $access_token, $client_id, $loginid, $expires_time);

    $dbh->do("INSERT INTO oauth.refresh_token (refresh_token, client_id, loginid) VALUES (?, ?, ?)", undef, $refresh_token, $client_id, $loginid);

    foreach my $related ('access_token', 'refresh_token') {
        my $insert_sth = $dbh->prepare("INSERT INTO oauth.${related}_scope ($related, scope_id) VALUES (?, ?)");
        foreach my $scope_id (@scope_ids) {
            $insert_sth->execute($related eq 'access_token' ? $access_token : $refresh_token, $scope_id);
        }
    }

    return ($access_token, $refresh_token, $expires_in);
}

sub get_loginid_by_access_token {
    my ($self, $token) = @_;

    return $self->dbh->selectrow_array(
        "UPDATE oauth.access_token SET last_used=NOW() WHERE access_token = ? AND expires > NOW() RETURNING loginid", undef, $token
    );
}

sub verify_refresh_token {
    my ($self, $client_id, $refresh_token) = @_;

    my $dbh = $self->dbh;

    my ($loginid) = $dbh->selectrow_array("
        SELECT loginid FROM oauth.refresh_token WHERE refresh_token = ? AND client_id = ? AND NOT revoked
    ", undef, $refresh_token, $client_id);
    return unless $loginid;

    # set revoked to avoid code-reuse
    $dbh->do("UPDATE oauth.refresh_token SET revoked=true WHERE refresh_token = ?", undef, $refresh_token);

    return $loginid;
}

sub get_scope_ids_by_refresh_token {
    my ($self, $refresh_token) = @_;

    my @scope_ids;
    my $sth = $self->dbh->prepare("SELECT scope_id FROM oauth.refresh_token_scope WHERE refresh_token = ?");
    $sth->execute($refresh_token);
    while (my ($sid) = $sth->fetchrow_array) {
        push @scope_ids, $sid;
    }
    return @scope_ids;
}

sub is_name_taken {
    my ($self, $user_id, $name) = @_;

    return $self->dbh->selectrow_array("SELECT 1 FROM oauth.clients WHERE binary_user_id = ? AND name = ?", undef, $user_id, $name);
}

sub create_client {
    my ($self, $app) = @_;

    my $id     = $app->{id}     || 'id-' . String::Random::random_regex('[a-zA-Z0-9]{29}');
    my $secret = $app->{secret} || String::Random::random_regex('[a-zA-Z0-9]{32}');

    my $sth = $self->dbh->prepare("
        INSERT INTO oauth.clients
            (id, secret, name, homepage, github, appstore, googleplay, binary_user_id)
        VALUES
            (? ,?, ?, ?, ?, ?, ?, ?)
    ");
    $sth->execute(
        $id, $secret, $app->{name},
        $app->{homepage}   || '',
        $app->{github}     || '',
        $app->{appstore}   || '',
        $app->{googleplay} || '',
        $app->{user_id});

    return {
        client_id     => $id,
        client_secret => $secret,
        name          => $app->{name},
        active        => 1,
    };
}

sub get_client {
    my ($self, $user_id, $client_id) = @_;

    return $self->dbh->selectrow_hashref("
        SELECT id as client_id, secret as client_secret, name, active FROM oauth.clients WHERE id = ? AND binary_user_id = ?
    ", undef, $client_id, $user_id);
}

sub get_clients_by_user_id {
    my ($self, $user_id) = @_;

    return $self->dbh->selectall_arrayref("
        SELECT
            id as client_id, secret as client_secret, name, active
        FROM oauth.clients WHERE binary_user_id = ? ORDER BY name
    ", {Slice => {}}, $user_id);
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
