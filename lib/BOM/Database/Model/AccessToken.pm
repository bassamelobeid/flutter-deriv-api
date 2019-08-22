package BOM::Database::Model::AccessToken;

use Moose;

use BOM::Database::AuthDB;
use Date::Utility;

has 'dbic' => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_dbic {
    return BOM::Database::AuthDB::rose_db()->dbic;
}

sub save_token {
    my ($self, $args) = @_;

    for (grep { not $args->{$_} } qw(token display_name loginid scopes)) {
        die "$_ is required in create_token";
    }

    $args->{valid_for_ip}  //= '';
    $args->{creation_time} //= Date::Utility->new->db_timestamp;

    my $dbic = $self->dbic;
    my $res  = $dbic->run(
        fixup => sub {
            my $sth = $_->prepare("
                INSERT INTO auth.access_token(token, display_name, client_loginid, scopes, valid_for_ip, creation_time)
                VALUES (?,?,?,?,?,?)
                RETURNING *
            ");
            $sth->execute(@{$args}{'token', 'display_name', 'loginid', 'scopes', 'valid_for_ip', 'creation_time'});
            $sth->fetchrow_hashref();
        });

    return $res->{token};
}

sub remove_by_token {
    my ($self, $token, $loginid) = @_;

    return $self->dbic->run(
        fixup => sub {
            $_->do("DELETE FROM auth.access_token WHERE token = ? and client_loginid = ?", undef, $token, $loginid);
        });
}

sub update_token_last_used {
    my ($self, $token, $last_used) = @_;

    unless ($token and $last_used) {
        die 'token and last_used are required to update_token_last_used';
    }

    return $self->dbic->run(
        fixup => sub {
            my $sth = $_->prepare("UPDATE auth.access_token SET last_used=? WHERE token=?");
            $sth->execute($last_used, $token);
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

no Moose;
__PACKAGE__->meta->make_immutable;

1;
