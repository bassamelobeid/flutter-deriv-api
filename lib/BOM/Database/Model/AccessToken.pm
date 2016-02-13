package BOM::Database::Model::AccessToken;

use Moose;
use BOM::Database::AuthDB;

has 'dbh' => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_dbh {
    return BOM::Database::AuthDB::rose_db->dbh;
}

sub create_token {
    my ($self, $loginid, $display_name, @scopes) = @_;

    my $dbh = $self->dbh;
    my ($token) = $dbh->selectrow_array("SELECT auth.create_token(15, ?, ?)", undef, $loginid, $display_name);

    ## insert scope as well
    if (@scopes) {
        my $get_scope_sth    = $dbh->prepare("SELECT id FROM auth.scopes WHERE scope = ?");
        my $insert_scope_sth = $dbh->prepare("INSERT INTO auth.access_token_scope (access_token, scope_id) VALUES (?, ?)");
        foreach my $scope (@scopes) {
            $get_scope_sth->execute($scope);
            my ($scope_id) = $get_scope_sth->fetchrow_array;
            next unless $scope_id;
            $insert_scope_sth->execute($token, $scope_id);
        }
    }

    return $token;
}

sub get_loginid_by_token {
    my ($self, $token) = @_;

    return $self->dbh->selectrow_array(
        "UPDATE auth.access_token SET last_used=NOW() WHERE token = ? RETURNING client_loginid", undef, $token
    );
}

sub get_scopes_by_access_token {
    my ($self, $access_token) = @_;

    my @scopes;
    my $sth = $self->dbh->prepare("
        SELECT scope FROM auth.access_token_scope
        JOIN auth.scopes ON scopes.id=access_token_scope.scope_id
        WHERE access_token = ?
    ");
    $sth->execute($access_token);
    while (my ($scope) = $sth->fetchrow_array) {
        push @scopes, $scope;
    }

    ## backwards compatibility
    if (scalar(@scopes) == 0) {
        @scopes = ('read', 'trade', 'admin', 'payments');
    }

    return @scopes;
}

sub get_tokens_by_loginid {
    my ($self, $loginid) = @_;

    return $self->dbh->selectall_arrayref("
        SELECT
            token, display_name, last_used::timestamp(0)
        FROM auth.access_token WHERE client_loginid = ? ORDER BY display_name
    ", { Slice => {} }, $loginid);
}

sub get_token_count_by_loginid {
    my ($self, $loginid) = @_;

    return $self->dbh->selectrow_array(
        "SELECT COUNT(*) FROM auth.access_token WHERE client_loginid = ?", undef, $loginid
    );
}

sub is_name_taken {
    my ($self, $loginid, $display_name) = @_;

    return $self->dbh->selectrow_array(
        "SELECT 1 FROM auth.access_token WHERE client_loginid = ? AND display_name = ?", undef, $loginid, $display_name
    );
}

sub remove_by_loginid {
    my ($self, $client_loginid) = @_;

    return $self->dbh->do(
        "DELETE FROM auth.access_token WHERE client_loginid = ?", undef, $client_loginid
    );
}

sub remove_by_token {
    my ($self, $token) = @_;

    return $self->dbh->do(
        "DELETE FROM auth.access_token WHERE token = ?", undef, $token
    );
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
