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

sub get_copiers_cnt {
    my ($self, $args) = @_;

    my $sql = q{
        SELECT copier_id, trader_id, trader_token
          FROM betonmarkets.copiers
         WHERE trader_id = $1
    };

    my @binds = ($args->{trader_id});
    my $res = $self->db->dbic->run(fixup => sub { [$_->selectall_arrayref($sql, undef, @binds)]->[0] });
    return scalar @{$self->_filter_invalid_tokens($res)};
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

sub get_traders {
    my ($self, $args) = @_;

    my $sql = q{
        SELECT trader_id, trader_id, trader_token
          FROM betonmarkets.copiers
         WHERE copier_id = $1
    };

    my @binds = ($args->{copier_id});
    my $res = $self->db->dbic->run(fixup => sub { $_->selectall_arrayref($sql, undef, @binds) });
    return $self->_filter_invalid_tokens($res);
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

no Moose;
__PACKAGE__->meta->make_immutable;
1;

=head1 NAME

BOM::Database::DataMapper::Copier

=head1 DESCRIPTION

Currently has methods that return data structures associated with trader copiers.

=cut
