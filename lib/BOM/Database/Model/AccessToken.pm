package BOM::Database::Model::AccessToken;

use Moose;
use BOM::Database::AuthDB;
use Cache::RedisDB;
use String::Random ();

has 'dbh' => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_dbh {
    return BOM::Database::AuthDB::rose_db->dbh;
}

sub create_token {
    my ($self, $loginid, $display_name) = @_;

    my $token = $self->generate_unused_token();
    $self->dbh->do(
        "INSERT INTO auth.access_token (token, display_name, client_loginid) VALUES (?, ?, ?)",
        undef, $token, $display_name, $loginid
    );
    return $token;
}

sub get_loginid_by_token {
    my ($self, $token) = @_;

    ## try redis first
    if ( my $client_loginid = Cache::RedisDB->get("API_ACCESSTOKEN", $token) ) {
        return $client_loginid;
    }

    my ($client_loginid) = $self->dbh->selectrow_array(
        "SELECT client_loginid FROM auth.access_token WHERE token = ?", undef, $token
    );
    return unless $client_loginid;

    Cache::RedisDB->set("API_ACCESSTOKEN", $token, $client_loginid, 3600);

    return $client_loginid;
}

sub get_tokens_by_loginid {
    my ($self, $loginid) = @_;

    return $self->dbh->selectall_arrayref(
        "SELECT * FROM auth.access_token WHERE client_loginid = ?", { Slice => {} }, $loginid
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

    Cache::RedisDB->del("API_ACCESSTOKEN", $token);

    return $self->dbh->do(
        "DELETE FROM auth.access_token WHERE token = ?", undef, $token
    );
}

sub generate_unused_token {
    my ($self) = @_;

    my $sth = $self->dbh->prepare("SELECT 1 FROM auth.access_token WHERE token = ?");
    while (1) {
        my $token = generate_token();
        $sth->execute($token);
        my ($is_used) = $sth->fetchrow_array;
        return $token unless $is_used;
    }
}

sub generate_token {
    return String::Random::random_regex('[a-zA-Z0-9]{12}');
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;