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

## store auth code
sub store_auth_code {
    my ($self, $client_id, $loginid) = @_;

    my $dbh          = $self->dbh;
    my $auth_code    = String::Random::random_regex('[a-zA-Z0-9]{32}');
    my $expires_time = Date::Utility->new({epoch => (Date::Utility->new->epoch + 600)})->datetime_yyyymmdd_hhmmss;    # 10 minutes max
    $dbh->do("INSERT INTO oauth.auth_code (auth_code, client_id, loginid, expires, verified) VALUES (?, ?, ?, ?, false)",
        undef, $auth_code, $client_id, $loginid, $expires_time);

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

## store access token
sub store_access_token {
    my ($self, $client_id, $loginid) = @_;

    my $dbh           = $self->dbh;
    my $expires_in    = 3600;
    my $access_token  = 'a1-' . String::Random::random_regex('[a-zA-Z0-9]{29}');
    my $refresh_token = 'r1-' . String::Random::random_regex('[a-zA-Z0-9]{29}');

    my $expires_time = Date::Utility->new({epoch => (Date::Utility->new->epoch + $expires_in)})->datetime_yyyymmdd_hhmmss;    # 10 minutes max
    $dbh->do("INSERT INTO oauth.access_token (access_token, client_id, loginid, expires) VALUES (?, ?, ?, ?)",
        undef, $access_token, $client_id, $loginid, $expires_time);

    $dbh->do("INSERT INTO oauth.refresh_token (refresh_token, client_id, loginid) VALUES (?, ?, ?)", undef, $refresh_token, $client_id, $loginid);

    return ($access_token, $refresh_token, $expires_in);
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

sub is_name_taken {
    my ($self, $user_id, $name) = @_;

    return $self->dbh->selectrow_array("SELECT 1 FROM oauth.clients WHERE binary_user_id = ? AND name = ?", undef, $user_id, $name);
}

sub create_client {
    my ($self, $app) = @_;

    my $id     = $app->{id}     || 'id-' . String::Random::random_regex('[a-zA-Z0-9]{29}');
    my $secret = $app->{secret} || 'sr-' . String::Random::random_regex('[a-zA-Z0-9]{29}');

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
    my ($self, $client_id) = @_;

    return $self->dbh->selectrow_hashref("
        SELECT id as client_id, secret as client_secret, name, active FROM oauth.clients WHERE id = ?
    ", undef, $client_id);
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
