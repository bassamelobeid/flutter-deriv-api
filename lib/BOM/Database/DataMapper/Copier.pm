package BOM::Database::DataMapper::Copier;

use List::Util qw(uniq);
use BOM::Database::Model::AccessToken;
use BOM::Database::Model::OAuth;
use Moose;

extends 'BOM::Database::DataMapper::Base';

sub get_copiers_cnt {
    my ($self, $args) = @_;

    my $sql = q{
        SELECT copier_id, trader_token
          FROM betonmarkets.copiers
         WHERE trader_id = $1
    };

    my @binds = ($args->{trader_id});
    my $res = $self->db->dbic->run(fixup => sub { [$_->selectall_arrayref($sql, undef, @binds)]->[0] });
    return scalar @{_filter_invalid_tokens($res)};
}

sub get_trade_copiers {
    my ($self, $args) = @_;
    ### This SQL query can be written in more obvious way but this long query is faster.
    ### Please, check with DBA if you want to change it
    my $sql = <<'SQL';
SELECT DISTINCT copier_id, trader_token from (
    SELECT copier_id, trader_token
      FROM betonmarkets.copiers AS copiers
     WHERE trader_id = $1
       AND trade_type = $2
       AND asset = $3
       AND ($4 IS NULL OR
            (min_trade_stake is NULL OR $4 >= min_trade_stake) AND
            (max_trade_stake is NULL OR $4 <= max_trade_stake))

    UNION ALL

    SELECT copier_id, trader_token
      FROM betonmarkets.copiers AS copiers
     WHERE trader_id = $1
       AND trade_type = '*'
       AND asset = $3
       AND ($4 IS NULL OR
            (min_trade_stake is NULL OR $4 >= min_trade_stake) AND
            (max_trade_stake is NULL OR $4 <= max_trade_stake))

    UNION ALL

    SELECT copier_id, trader_token
      FROM betonmarkets.copiers AS copiers
     WHERE trader_id = $1
       AND trade_type = $2
       AND asset = '*'
       AND ($4 IS NULL OR
            (min_trade_stake is NULL OR $4 >= min_trade_stake) AND
            (max_trade_stake is NULL OR $4 <= max_trade_stake))

    UNION ALL

    SELECT copier_id, trader_token
      FROM betonmarkets.copiers AS copiers
     WHERE trader_id = $1
       AND trade_type = '*'
       AND asset = '*'
       AND ($4 IS NULL OR
            (min_trade_stake is NULL OR $4 >= min_trade_stake) AND
            (max_trade_stake is NULL OR $4 <= max_trade_stake))
) t
SQL

    my $res = $self->db->dbic->run(
        fixup => sub {
            $_->selectall_arrayref($sql, undef, @{$args}{qw/trader_id trade_type asset price/});
        }) // [];
    return _filter_invalid_tokens($res);
}

sub get_traders {
    my ($self, $args) = @_;

    my $sql = q{
        SELECT trader_id, trader_token
          FROM betonmarkets.copiers
         WHERE copier_id = $1
    };

    my @binds = ($args->{copier_id});
    my $res = $self->db->dbic->run(fixup => sub { $_->selectall_arrayref($sql, undef, @binds) });
    return _filter_invalid_tokens($res);
}

# Takes pairs of logins and tokens, returns a unique list of logins
# that had a valid token OR no token at all

sub _filter_invalid_tokens {
    my $list = shift;
    my @copiers = map { $_->[0] } grep {
        my $token = $_->[1];
        if (!$token) {    # because copiers created before this change did not store trader token
            1;
        } elsif (length $token == 15) {    # access token
            BOM::Database::Model::AccessToken->new->get_token_details($token)->{loginid};
        } elsif (length $token == 32 && $token =~ /^a1-/) {
            BOM::Database::Model::OAuth->new->get_token_details($token)->{loginid};
        } else {
            0;
        }
    } @$list;
    return [uniq @copiers];
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

=head1 NAME

BOM::Database::DataMapper::Copier

=head1 DESCRIPTION

Currently has methods that return data structures associated with trader copiers.

=cut
