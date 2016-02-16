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

sub __parse_array {
    my ($array_string) = @_;
    return $array_string if ref($array_string) eq 'ARRAY';
    return [] unless $array_string;
    return BOM::Database::AuthDB::rose_db->parse_array($array_string);
}

my @token_scopes = ('read', 'trade', 'payments', 'admin');
sub __filter_valid_scopes {
    my (@s) = @_;

    my @vs;
    foreach my $s (@s) {
        push @vs, $s if grep { $_ eq $s } @token_scopes;
    }

    return @vs;
}

sub create_token {
    my ($self, $loginid, $display_name, @scopes) = @_;

    @scopes = __filter_valid_scopes(@scopes);

    my $dbh = $self->dbh;
    my ($token) = $dbh->selectrow_array("SELECT auth.create_token(15, ?, ?, ?)", undef, $loginid, $display_name, \@scopes);

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

    my $sth = $self->dbh->prepare("
        SELECT scopes FROM auth.access_token
        WHERE token = ?
    ");
    $sth->execute($access_token);
    my $scopes = $sth->fetchrow_array;
    $scopes = __parse_array($scopes);
    return @$scopes;
}

sub get_tokens_by_loginid {
    my ($self, $loginid) = @_;

    my @tokens;
    my $sth = $self->dbh->prepare("
        SELECT
            token, display_name, scopes, last_used::timestamp(0)
        FROM auth.access_token WHERE client_loginid = ? ORDER BY display_name
    ");
    $sth->execute($loginid);
    while (my $r = $sth->fetchrow_hashref) {
        $r->{scopes} = __parse_array($r->{scopes});
        push @tokens, $r;
    }

    return wantarray ? @tokens : \@tokens;
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
