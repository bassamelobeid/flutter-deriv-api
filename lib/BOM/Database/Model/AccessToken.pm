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
my %available_scopes = map { $_ => 1 } @token_scopes;
sub __filter_valid_scopes {
    my $s = shift;
    return [grep { $available_scopes{$_} } @$s];
}

sub create_token {
    my ($self, $loginid, $display_name, $scopes, $ip) = @_;

    $scopes = __filter_valid_scopes($scopes);

    my $dbh = $self->dbh;
    my ($token) = $dbh->selectrow_array("SELECT auth.create_token(15, ?, ?, ?, ?)", undef, $loginid, $display_name, $scopes, $ip);

    return $token;
}

sub get_token_details {
    my ($self, $token) = @_;

    my $details = $self->dbh->selectrow_hashref(<<'SQL', undef, $token);
SELECT loginid, creation_time, scopes, display_name, last_used, valid_for_ip
  FROM auth.get_token_details($1)
SQL
    $details->{scopes} = __parse_array($details->{scopes});

    return $details;
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
            token, display_name, scopes, last_used::timestamp(0), valid_for_ip
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
    my ($self, $token, $loginid) = @_;

    return $self->dbh->do(
        "DELETE FROM auth.access_token WHERE token = ? and client_loginid = ?", undef, $token, $loginid
    );
}

sub get_all_tokens_by_loginid {
    my ($self, $loginid) = @_;

    my @tokens;
    my $sth = $self->dbh->prepare('
        SELECT
            access_token
        FROM
            oauth.access_token
        WHERE
            loginid = $1
        UNION
        SELECT
            token
        FROM
            auth.access_token
        WHERE
            client_loginid = $1;
    ');
    $sth->execute($loginid);
    while (my $r = $sth->fetchrow_arrayref) {
        push @tokens, $r->[0];
    }

    return wantarray ? @tokens : \@tokens;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
