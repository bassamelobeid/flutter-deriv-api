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
            my $sth = $_->prepare(
                "INSERT INTO auth.access_token(token, display_name, client_loginid, scopes, valid_for_ip, creation_time)
                VALUES (?,?,?,?,?,?)
                RETURNING *"
            );
            $sth->execute(@{$args}{'token', 'display_name', 'loginid', 'scopes', 'valid_for_ip', 'creation_time'});
            $sth->fetchrow_hashref();
        });

    return $res;
}

sub remove_by_token {
    my ($self, $token, $last_used) = @_;

    # we might be deleting token that was never used
    $self->_update_token_last_used($token, $last_used) if $last_used;

    return $self->dbic->run(
        fixup => sub {
            $_->do("DELETE FROM auth.access_token WHERE token = ?", undef, $token);
        });
}

sub _update_token_last_used {
    my ($self, $token, $last_used) = @_;

    unless ($token and $last_used) {
        die 'token and last_used are required to update_token_last_used';
    }

    return $self->dbic->run(
        fixup => sub {
            my $sth = $_->prepare(q{UPDATE auth.access_token SET last_used=$1 WHERE token=$2 AND last_used IS DISTINCT FROM $1});
            $sth->bind_param(1, $last_used);
            $sth->bind_param(2, $token);
            $sth->execute();
        });
}

sub get_all_tokens {
    my $self = shift;

    my $res = $self->dbic->run(
        fixup => sub {
            my $sth = $_->prepare("SELECT * FROM auth.access_token");
            $sth->execute();
            $sth->fetchall_hashref('token');
        });

    foreach my $key (keys %$res) {
        $res->{$key}{scopes} = _parse_array($res->{$key}{scopes});
    }

    return $res;
}

sub _parse_array {
    my ($array_string) = @_;
    return $array_string if ref($array_string) eq 'ARRAY';
    return [] unless $array_string;
    return BOM::Database::AuthDB::rose_db()->parse_array($array_string);
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
            $_->selectall_arrayref("SELECT * FROM audit.get_deleted_tokens(?)", {Slice => {}}, $loginid);
        });
    # Easier to convert the scopes array here than in Postgres
    map { $_->{scopes} =~ s/[\[\]\"]//g; $_->{info} = 'Name: ' . $_->{name} . '; Scopes: ' . $_->{scopes} } @$tokens;

    return $tokens;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
