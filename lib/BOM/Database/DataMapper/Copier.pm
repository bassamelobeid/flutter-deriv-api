package BOM::Database::DataMapper::Copier;

use Moose;
extends 'BOM::Database::DataMapper::Base';

sub get_copiers_cnt {
    my ($self, $args) = @_;

    my $sql = q{
        SELECT COUNT(DISTINCT copier_id)
          FROM betonmarkets.copiers
         WHERE trader_id = $1
    };

    my @binds = ($args->{trader_id});
    return $self->db->dbic->run(fixup => sub { [$_->selectrow_array($sql, undef, @binds)]->[0] });
}

sub get_trade_copiers {
    my ($self, $args) = @_;
    ### This SQL query can be written in more obvious way but this long query is faster.
    ### Please, check with DBA if you want to change it
    my $sql = <<'SQL';
SELECT DISTINCT copier_id from (
    SELECT copier_id
      FROM betonmarkets.copiers AS copiers
     WHERE trader_id = $1
       AND trade_type = $2
       AND asset = $3
       AND ($4 IS NULL OR
            (min_trade_stake is NULL OR $4 >= min_trade_stake) AND
            (max_trade_stake is NULL OR $4 <= max_trade_stake))

    UNION ALL

    SELECT copier_id
      FROM betonmarkets.copiers AS copiers
     WHERE trader_id = $1
       AND trade_type = '*'
       AND asset = $3
       AND ($4 IS NULL OR
            (min_trade_stake is NULL OR $4 >= min_trade_stake) AND
            (max_trade_stake is NULL OR $4 <= max_trade_stake))

    UNION ALL

    SELECT copier_id
      FROM betonmarkets.copiers AS copiers
     WHERE trader_id = $1
       AND trade_type = $2
       AND asset = '*'
       AND ($4 IS NULL OR
            (min_trade_stake is NULL OR $4 >= min_trade_stake) AND
            (max_trade_stake is NULL OR $4 <= max_trade_stake))

    UNION ALL

    SELECT copier_id
      FROM betonmarkets.copiers AS copiers
     WHERE trader_id = $1
       AND trade_type = '*'
       AND asset = '*'
       AND ($4 IS NULL OR
            (min_trade_stake is NULL OR $4 >= min_trade_stake) AND
            (max_trade_stake is NULL OR $4 <= max_trade_stake))
) t
SQL

    return $self->db->dbic->run( fixup => 
        sub {
            $_->selectcol_arrayref($sql, undef, @{$args}{qw/trader_id trade_type asset price/});
        }) // [];
}

sub get_traders {
    my ($self, $args) = @_;

    my $sql = q{
        SELECT trader_id
          FROM betonmarkets.copiers
         WHERE copier_id = $1
    };

    my @binds = ($args->{copier_id});
    return $self->db->dbic->run( fixup => sub { $_->selectcol_arrayref($sql, undef, @binds) });
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

=head1 NAME

BOM::Database::DataMapper::Copier

=head1 DESCRIPTION

Currently has methods that return data structures associated with trader copiers.

=cut
