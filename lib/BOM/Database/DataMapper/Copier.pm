package BOM::Database::DataMapper::Copier;

use Moose;
extends 'BOM::Database::DataMapper::Base';

sub get_copiers_cnt {
    my ($self, $args) = @_;

    my $sql = q{
        SELECT DISTINCT copier_id
          FROM betonmarkets.copiers
         WHERE trader_id = $1
    };

    my @binds = ($args->{trader_id});
    return scalar(@{$self->db->dbh->selectcol_arrayref($sql, undef, @binds) || []});
}

sub get_traders {
    my ($self, $args) = @_;

    my $sql = q{
        SELECT trader_id
          FROM betonmarkets.copiers
         WHERE copier_id = $1
    };

    my @binds = ($args->{copier_id});
    return $self->db->dbh->selectcol_arrayref($sql, undef, @binds);
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

=head1 NAME

BOM::Database::DataMapper::Copier

=head1 DESCRIPTION

Currently has methods that return data structures associated with trader copiers.

=cut
