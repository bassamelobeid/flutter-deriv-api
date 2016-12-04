package BOM::Database::DataMapper::Client;

use DBD::Pg ':async';
use Time::HiRes qw(usleep);
use Try::Tiny;

use Moose;
extends 'BOM::Database::DataMapper::Base';

sub get_duplicate_client() {
    my $self = shift;
    my $args = shift;

    my $dupe_sql =
"
    SELECT
        loginid,
        first_name,
        last_name,
        date_of_birth,
        email
    FROM
        betonmarkets.client
    WHERE
        UPPER(TRIM(BOTH ' ' FROM first_name))=(TRIM(BOTH ' ' FROM ?)) AND
        UPPER(TRIM(BOTH ' ' FROM last_name))=(TRIM(BOTH ' ' FROM ?)) AND
        date_of_birth=? AND
        broker_code=?
";
    my $dupe_dbh = $self->db->dbh;
    my $dupe_sth = $dupe_dbh->prepare($dupe_sql);
    $dupe_sth->bind_param( 1, uc $args->{first_name} );
    $dupe_sth->bind_param( 2, uc $args->{last_name} );
    $dupe_sth->bind_param( 3, $args->{date_of_birth} );
    $dupe_sth->bind_param( 4, $self->broker_code );
    $dupe_sth->execute();
    my @dupe_record = $dupe_sth->fetchrow_array();

    return @dupe_record;
}

sub lock_client_loginid {
    my $self = shift;

    $self->db->dbh->do('SET synchronous_commit=local');

    my $sth = $self->db->dbh->prepare('SELECT lock_client_loginid($1)');
    $sth->execute( $self->client_loginid );

    $self->db->dbh->do('SET synchronous_commit=on');

    my $result;
    if ( $result = $sth->fetchrow_arrayref and $result->[0] ) {

        return 1;
    }

    return;
}

BEGIN {
    *freeze = \&lock_client_loginid;
}

sub unlock_client_loginid {
    my $self = shift;

    $self->db->dbh->do('SET synchronous_commit=local');

    my $sth = $self->db->dbh->prepare('SELECT unlock_client_loginid($1)');
    $sth->execute( $self->client_loginid );

    $self->db->dbh->do('SET synchronous_commit=on');

    my $result;
    if ( $result = $sth->fetchrow_arrayref and $result->[0] ) {
        return 1;
    }

    return;
}

BEGIN {
    *unfreeze = \&unlock_client_loginid;
}

sub locked_client_list {
    my $self = shift;

    my $sth = $self->db->dbh->prepare(
'SELECT *, age(now()::timestamp(0), time) as age from betonmarkets.client_lock where locked order by time'
    );
    $sth->execute();

    return $sth->fetchall_hashref('client_loginid');
}

sub copytrading_traders_list {
    my ($self) = @_;

    my $sql = q{
        SELECT
            loginid
        FROM
            betonmarkets.client
        WHERE
            allow_copiers IS TRUE
    };

    return $self->db->dbh->selectcol_arrayref($sql);
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

=head1 NAME

BOM::Database::DataMapper::Client

=head1 DESCRIPTION

Currently has methods that return data structures associated with Clients
(as in people who use our site, not classes).

=cut
