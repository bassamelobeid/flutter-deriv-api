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
    my ($self, $loginid, $display_name) = @_;

    return $self->dbh->selectrow_array("SELECT auth.create_token(15, ?, ?)", undef, $loginid, $display_name);
}

sub get_loginid_by_token {
    my ($self, $token) = @_;

    return $self->dbh->selectrow_array(
        "UPDATE auth.access_token SET last_used=NOW() WHERE token = ? RETURNING client_loginid", undef, $token
    );
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

sub remove_by_token {
    my ($self, $token) = @_;

    return $self->dbh->do(
        "DELETE FROM auth.access_token WHERE token = ?", undef, $token
    );
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;