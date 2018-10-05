package BOM::Database::Helper::UserSpecificLimit;

use Moose;
use Rose::DB;
use Carp;

has 'client_loginid' => (
    is => 'ro',
);

has 'realized_loss' => (
    is => 'ro',
);

has 'potential_loss' => (
    is => 'ro',
);

has 'db' => (
    is  => 'rw',
    isa => 'Rose::DB',
);

sub record_user_specific_limit {
    my $self = shift;

    my $potential_limit = $self->potential_loss eq '' ? undef : $self->potential_loss;
    my $realized_limit  = $self->realized_loss eq ''  ? undef : $self->realized_loss;

    my $sql = q{
    	SELECT * FROM betonmarkets.insert_user_specific_limit(?,?,?)
    };

    $self->db->dbic->run(
        ping => sub {
            $_->do($sql, undef, $self->client_loginid, $potential_limit, $realized_limit);
        });

    return 1;
}

sub default_user_specific_limit {
    my $self = shift;

    my $potential_limit = $self->potential_loss eq '' ? undef : $self->potential_loss;
    my $realized_limit  = $self->realized_loss eq ''  ? undef : $self->realized_loss;

    my $sql = q{
        SELECT * FROM betonmarkets.default_user_specific_limit(?,?)
    };

    $self->db->dbic->run(
        ping => sub {
            $_->do($sql, undef, $potential_limit, $realized_limit);
        });

    return 1;
}

sub delete_user_specific_limit {
    my $self = shift;

    my $sql = q{
	SELECT * FROM betonmarkets.delete_user_specific_limit(?)
    };

    $self->db->dbic->run(
        ping => sub {
            $_->do($sql, undef, $self->client_loginid);
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
       SELECT * FROM betonmarkets.user_specific_limits where binary_user_id=0
    };

    return $self->db->dbic->run(
        fixup => sub {
            my $sth = $_->prepare($sql);
            $sth->execute;

            return $sth->fetchall_arrayref({})->[0];
        });
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
