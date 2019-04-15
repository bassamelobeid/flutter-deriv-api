package BOM::Database::DataMapper::Copier;

use List::Util qw(any uniq);
use BOM::Database::Model::AccessToken;
use BOM::Database::Model::OAuth;
use BOM::Database::AuthDB;
use Moose;

extends 'BOM::Database::DataMapper::Base';

has auth_db => (
    is      => 'ro',
    lazy    => 1,
    default => sub { BOM::Database::AuthDB::rose_db()->dbic });

=head2 get_copiers_count

Gets the count of copy traders attached to a trader

Takes the following arguments as named parameters

=over 4

=item trader_id  : client_id of the trader.

=back

Returns an integer with the count of copiers.

=cut

sub get_copiers_count {

    my ($self, $args) = @_;
    my $tokens = $self->_filter_invalid_tokens($self->get_copiers_tokens_all($args));
    return scalar @$tokens;
}

=head2 get_copiers_tokens_all

Returns details on the copy traders attached to a trader including ones with invalid tokens.

Takes the following arguments as named parameters

=over 4

=item trader_id  : client_id of the trader.

=back

Returns an ArrayRef with the following  ArrayRef

    [
        [copier_id, traderid, traders token] ,
    ]

=cut

sub get_copiers_tokens_all {
    my ($self, $args) = @_;

    my $sql = q{
        SELECT DISTINCT copier_id, trader_id, trader_token
          FROM betonmarkets.copiers
         WHERE trader_id = $1
         ORDER BY copier_id
    };

    my @binds = ($args->{trader_id});
    my $res = $self->db->dbic->run(fixup => sub { $_->selectall_arrayref($sql, undef, @binds) });
    return $res;
}

sub get_trade_copiers {
    my ($self, $args) = @_;

    my $sql = 'SELECT copier_id, trader_id, trader_token FROM betonmarkets.get_copiers($1,$2,$3,$4)';

    my $res = $self->db->dbic->run(
        fixup => sub {
            $_->selectall_arrayref($sql, undef, @{$args}{qw/trader_id trade_type asset price/});
        }) // [];
    return $self->_filter_invalid_tokens($res);
}

=head2 get_traders_tokens_all

Returns a list of traders a copier is following including Invalid tokens.

Takes the following arguments as named parameters

=over 4

=item  copier_id :   The client_id of the copier.

=back

Returns an ArrayRef with an ArrayRef  of copy trader details

    [
        [   trader_id, copier_id, traders token] ,
    ]

=cut

sub get_traders_tokens_all {
    my ($self, $args) = @_;

    my $sql = q{
        SELECT DISTINCT trader_id, copier_id, trader_token
          FROM betonmarkets.copiers
         WHERE copier_id = $1
         ORDER BY trader_id
    };

    my @binds = ($args->{copier_id});
    my $res = $self->db->dbic->run(fixup => sub { $_->selectall_arrayref($sql, undef, @binds) });
    return $res;
}

=head2 get_traders

Gets an ArrayRef of traders for a copier  with valid tokens
Takes the following arguments as named parameters

=over 4

=item  copier_id :   The client_id of the copier.

=back

Returns an ArrayRef of unique trader client id with valid tokens.

=cut

sub get_traders {
    my ($self, $args) = @_;
    my $res = $self->get_traders_tokens_all($args);
    #maintaining some awkward backwards compatibility with _filter_invalid _tokens()
    my @remapped = map { [$_->[0], $_->[0], $_->[2]] } $res->@*;
    return $self->_filter_invalid_tokens(\@remapped);
}

=head2 delete_copiers

Deletes copier tokens from the database

Takes the following arguments as named parameters


=over 4

=item  copier_id  client login id of the copier

=item  trader_id client login id of the trader

=item  token  token representing the copy

=back

Returns number of rows deleted.

=cut

sub delete_copiers {
    my ($self, $args) = @_;
    my $rows_affected = $self->db->dbic->run(
        ping => sub {
            my $rows_affected = $_->do('SELECT FROM betonmarkets.delete_copiers(?::VARCHAR(12),?::VARCHAR(12),?::TEXT)',
                undef, ($args->{trader_id}, $args->{copier_id}, $args->{token}));
        });
    return $rows_affected;
}

# Takes arrayref of [ item, login, token ]
# Returns a unqiue list of items who had a login with a valid token.
sub _filter_invalid_tokens {
    my ($self, $list) = @_;

    my @logins = uniq map { $_->[1] } @$list;

    my $res = $self->auth_db->run(
        fixup => sub {
            $_->selectall_arrayref('SELECT * FROM get_valid_tokens_for_loginids(?::VARCHAR[])', undef, \@logins);
        });

    # Make a hash of valid tokens per login id
    my %tokens;
    push @{$tokens{$_->[0]}}, $_->[1] for @$res;

    my @copiers = map { $_->[0] } grep {
        my $loginid = $_->[1];
        my $token   = $_->[2];
        !$token || (exists $tokens{$loginid} && any { $_ eq $token } @{$tokens{$loginid}});
    } @$list;
    return [uniq @copiers];
}

=head2 get_traders_all

Gets an HashRef of traders and details for a copier
Takes the following arguments as named parameters

=over 4

=item  copier_id :   The client_id of the copier.

=back

Returns an HashRef of unique trader client id and details.

=cut

sub get_traders_all {
    my ($self, $args) = @_;

    my $sql = q{
        SELECT trader_id, trader_token, array_agg(trade_type), array_agg(asset),min_trade_stake,max_trade_stake
        FROM betonmarkets.copiers
        WHERE copier_id = $1
        GROUP BY trader_id, trader_token, min_trade_stake, max_trade_stake
    };

    my @binds = ($args->{copier_id});
    my $res   = $self->db->dbic->run(fixup => sub { $_->selectall_arrayref($sql, undef, @binds) });
    my @res   = map { {
            loginid         => $_->[0],
            token           => $_->[1],
            trade_types     => $_->[2],
            assets          => $_->[3],
            min_trade_stake => $_->[4],
            max_trade_stake => $_->[5]}
    } @$res;

    return \@res;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;

=head1 NAME

BOM::Database::DataMapper::Copier

=head1 DESCRIPTION

Currently has methods that return data structures associated with trader copiers.

=cut
