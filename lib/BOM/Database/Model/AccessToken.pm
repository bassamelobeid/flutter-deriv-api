package BOM::Database::Model::AccessToken;

use Moose;
use BOM::Database::AuthDB;
use BOM::System::Chronicle;

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

    ## try redis first
    if ( my $client_loginid = BOM::System::Chronicle->_redis_read->get('API_ACCESSTOKEN::' . $token) ) {
        return $client_loginid;
    }

    my ($client_loginid) = $self->dbh->selectrow_array(
        "SELECT client_loginid FROM auth.access_token WHERE token = ?", undef, $token
    );
    return unless $client_loginid;

    BOM::System::Chronicle->_redis_write->set('API_ACCESSTOKEN::' . $token, $client_loginid);
    BOM::System::Chronicle->_redis_write->expire('API_ACCESSTOKEN::' . $token, 3600);

    return $client_loginid;
}

sub get_tokens_by_loginid {
    my ($self, $loginid) = @_;

    return $self->dbh->selectall_arrayref(
        "SELECT * FROM auth.access_token WHERE client_loginid = ? ORDER BY display_name", { Slice => {} }, $loginid
    );
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

sub update_last_used_by_token {
    my ($self, $token) = @_;

    return $self->dbh->do(
        "UPDATE auth.access_token SET last_used=NOW() WHERE token = ?", undef, $token
    );
}

sub remove_by_token {
    my ($self, $token) = @_;

    BOM::System::Chronicle->_redis_write->del('API_ACCESSTOKEN::' . $token);

    return $self->dbh->do(
        "DELETE FROM auth.access_token WHERE token = ?", undef, $token
    );
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;