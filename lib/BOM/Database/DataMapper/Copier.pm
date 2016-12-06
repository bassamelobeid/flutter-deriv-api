package BOM::Database::DataMapper::Copier;

use Moose;
extends 'BOM::Database::DataMapper::Base';

sub get_copiers_cnt {
    my ($self, $args) = @_;

    my $sql = q{
        SELECT count(*)
          FROM betonmarkets.copiers
         WHERE trader_id = $1
    };

    my @binds = ($args->{trader_id});
    return $self->db->dbh->selectcol_arrayref($sql, undef, @binds)->[0] // 0;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

=head1 NAME

BOM::Database::DataMapper::Copier

=head1 DESCRIPTION

Currently has methods that return data structures associated with trader copiers.

=cut
