package BOM::Database::Model::AccessToken;

use Moose;
use BOM::Database::AuthDB;

has 'dbic' => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_dbic {
    return BOM::Database::AuthDB::rose_db()->dbic;
}

sub __parse_array {
    my ($array_string) = @_;
    return $array_string if ref($array_string) eq 'ARRAY';
    return [] unless $array_string;
    return BOM::Database::AuthDB::rose_db()->parse_array($array_string);
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

    my $dbic = $self->dbic;
    my ($token) =
        $dbic->run(ping => sub { $_->selectrow_array("SELECT auth.create_token(15, ?, ?, ?, ?)", undef, $loginid, $display_name, $scopes, $ip) });

    return $token;
}

sub get_token_details {
    my ($self, $token) = @_;

    my $details = $self->dbic->run(
        fixup => sub {
            $_->selectrow_hashref(<<'SQL', undef, $token) });
SELECT loginid, creation_time, scopes, display_name, last_used, valid_for_ip
  FROM auth.get_token_details($1)
SQL
    $details->{scopes} = __parse_array($details->{scopes});

    return $details;
}

sub get_scopes_by_access_token {
    my ($self, $access_token) = @_;

    my $scopes = $self->dbic->run(
        fixup => sub {
            my $sth = $_->prepare("
        SELECT scopes FROM auth.access_token
        WHERE token = ?
    ");
            $sth->execute($access_token);
            $sth->fetchrow_array;
        });
    $scopes = __parse_array($scopes);
    return @$scopes;
}

sub get_tokens_by_loginid {
    my ($self, $loginid) = @_;

    my $tokens = $self->dbic->run(
        fixup => sub {
            my $sth = $_->prepare("
        SELECT
            token, display_name, scopes, last_used::timestamp(0), valid_for_ip
        FROM auth.access_token WHERE client_loginid = ? ORDER BY display_name
    ");
            $sth->execute($loginid);
            return $sth->fetchall_arrayref({});
        });
    $_->{scopes} = __parse_array($_->{scopes}) for @$tokens;
    return wantarray ? @$tokens : $tokens;
}

sub get_token_count_by_loginid {
    my ($self, $loginid) = @_;

    return $self->dbic->run(
        fixup => sub {
            $_->selectrow_array("SELECT COUNT(*) FROM auth.access_token WHERE client_loginid = ?", undef, $loginid);
        });
}

sub is_name_taken {
    my ($self, $loginid, $display_name) = @_;

    return $self->dbic->run(
        fixup => sub {
            $_->selectrow_array("SELECT 1 FROM auth.access_token WHERE client_loginid = ? AND display_name = ?", undef, $loginid, $display_name);
        });
}

sub remove_by_loginid {
    my ($self, $client_loginid) = @_;

    return $self->dbic->run(
        ping => sub {
            $_->do("DELETE FROM auth.access_token WHERE client_loginid = ?", undef, $client_loginid);
        });
}

sub remove_by_token {
    my ($self, $token, $loginid) = @_;

    return $self->dbic->run(
        ping => sub {
            $_->do("DELETE FROM auth.access_token WHERE token = ? and client_loginid = ?", undef, $token, $loginid);
        });
}

sub get_all_tokens_by_loginid {
    my ($self, $loginid) = @_;

    return $self->dbic->run(
        fixup => sub {
            $_->selectall_arrayref("
        SELECT                           
            access_token as token, 'Access' as type, 'App ID: '|| app_id::text as info, creation_time::timestamp(0)
        FROM
            oauth.access_token
        WHERE
            loginid = ?
        UNION
        SELECT
            token, 'API', 'Name: ' ||display_name||'; Scopes: '||array_to_string(scopes,','), creation_time::timestamp(0)
        FROM
            auth.access_token
        WHERE
            client_loginid = ?",
                {Slice => {}},
                $loginid, $loginid);
        });
}

sub token_deletion_history {
    my ($self, $loginid) = @_;

    my $tokens = $self->dbic->run(
        fixup => sub {
            $_->selectall_arrayref("
                SELECT payload->>'token' AS token, payload->>'display_name' AS name, 
                  stamp::timestamp(0) AS deleted, payload->>'scopes' as scopes
                FROM audit.auth_token 
                WHERE operation = 'DELETE' 
                  AND payload->>'client_loginid' = ?",
                {Slice => {}},
                $loginid);
        });
    # Easier to convert the scopes array here than in Postgres
    map { $_->{scopes} =~ s/[\[\]\"]//g; $_->{info} = 'Name: ' . $_->{name} . '; Scopes: ' . $_->{scopes} } @$tokens;

    return $tokens;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
