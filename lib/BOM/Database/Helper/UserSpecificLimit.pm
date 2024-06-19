package BOM::Database::Helper::UserSpecificLimit;

use Moose;
use Rose::DB;
use Carp;

my @parameters = qw(client_loginid realized_loss potential_loss client_type market_type expiry);

sub BUILD {
    my $self = shift;

    foreach my $param (@parameters) {
        $self->$param(undef) if defined $self->$param and $self->$param eq '';
    }

    return;
}

has [@parameters] => (
    is => 'rw',
);

has 'db' => (
    is  => 'rw',
    isa => 'Rose::DB',
);

sub record_user_specific_limit {
    my $self = shift;

    my $sql = q{
    	SELECT * FROM betonmarkets.insert_user_specific_limit(?,?,?,?,?,?)
    };

    $self->db->dbic->run(
        ping => sub {
            $_->do($sql, undef, $self->client_loginid, $self->market_type, $self->client_type, $self->potential_loss, $self->realized_loss,
                $self->expiry);
        });

    return 1;
}

sub delete_user_specific_limit {
    my $self = shift;

    my $sql = q{
	SELECT * FROM betonmarkets.delete_user_specific_limit(?,?,?)
    };

    $self->db->dbic->run(
        ping => sub {
            $_->do($sql, undef, $self->client_loginid, $self->market_type, $self->client_type);
        });

    return 1;
}

sub select_user_specific_limit {
    my $self = shift;

    my $sql = q{
       SELECT * FROM betonmarkets.get_user_specific_limit()
    };

    return $self->db->dbic->run(
        fixup => sub {
            my $sth = $_->prepare($sql);
            $sth->execute;

            return @{$sth->fetchall_arrayref({})};
        });
}

sub select_default_user_specific_limit {
    my $self = shift;

    my $sql = q{
       SELECT * FROM betonmarkets.user_specific_limits WHERE binary_user_id IS NULL
    };

    return $self->db->dbic->run(
        fixup => sub {
            my $sth = $_->prepare($sql);
            $sth->execute;

            return $sth->fetchall_arrayref({});
        });
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
