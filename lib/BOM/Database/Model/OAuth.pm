package BOM::Database::Model::OAuth;

use Moose;
use Date::Utility;
use Data::UUID;
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

    my $dbh = $self->dbh;
    return $dbh->selectrow_hashref("SELECT * FROM oauth.clients WHERE id = ? AND active", undef, $client_id);
}

## store auth code
sub store_auth_code {
    my ($self, $client_id, $loginid) = @_;

    my $dbh = $self->dbh;

    my $auth_code = Data::UUID->new()->create_str();

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
        SELECT * FROM oauth.auth_code WHERE auth_code = ? AND client_id = ?
    ", undef, $auth_code, $client_id);

    return unless $auth_row;
    return if $auth_row->{verified};
    return unless Date::Utility->new->is_before(Date::Utility->new($auth_row->{expires}));

    $dbh->do("UPDATE oauth.auth_code SET verified=true WHERE auth_code = ?", undef, $auth_code);

    return $auth_row->{loginid};
}

## store access token
sub store_access_token {
    my ($self, $client_id, $loginid) = @_;

    my $dbh           = $self->dbh;
    my $expires_in    = 3600;
    my $access_token  = Data::UUID->new()->create_str();
    my $refresh_token = Data::UUID->new()->create_str();

    my $expires_time = Date::Utility->new({epoch => (Date::Utility->new->epoch + $expires_in)})->datetime_yyyymmdd_hhmmss;    # 10 minutes max
    $dbh->do("INSERT INTO oauth.access_token (access_token, refresh_token, client_id, loginid, expires) VALUES (?, ?, ?, ?, ?)",
        undef, $access_token, $refresh_token, $client_id, $loginid, $expires_time);

    $dbh->do("INSERT INTO oauth.refresh_token (refresh_token, client_id, loginid) VALUES (?, ?, ?)", undef, $refresh_token, $client_id, $loginid);

    return ($access_token, $refresh_token, $expires_in);
}

sub verify_refresh_token {
    my ($self, $client_id, $refresh_token) = @_;

    my $dbh = $self->dbh;

    my $refresh_token_row = $dbh->selectrow_hashref("
        SELECT * FROM oauth.refresh_token WHERE refresh_token = ? AND client_id = ?
    ", undef, $refresh_token, $client_id);

    return unless $refresh_token_row;
    return if $refresh_token_row->{revoked};

    $dbh->do("UPDATE oauth.refresh_token SET revoked=true WHERE refresh_token = ?", undef, $refresh_token);

    return $refresh_token_row->{loginid};
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
