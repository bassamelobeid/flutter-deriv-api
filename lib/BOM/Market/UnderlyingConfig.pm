package BOM::Market::UnderlyingConfig;

use strict;
use warnings;
our $VERSION = 0.01;

=head1 NAME

BOM::Market::UnderlyingConfig

=head1 SYNOPSYS

    my $udb     = BOM::Market::UnderlyingConfig->instance;
    my $sym_props = $udb->get_parameters_for('frxEURUSD');

=head1 DESCRIPTION

This module implements functions to access information from
underlyings.yml.  The class is a singleton. You do not need to
explicitely initialize the class, it will be initialized automatically
when you will try to get an instance. By default it reads information
from underlyings.yml.

=cut

use MooseX::Singleton;
use namespace::autoclean;
use YAML::CacheLoader;

use BOM::Utility::Log4perl qw( get_logger );
use BOM::Market::Registry;
use BOM::Market::SubMarket;

has _cached_underlyings => (
    is      => 'ro',
    default => sub { {} },
);

has all_parameters => (
    is         => 'ro',
    lazy_build => 1,
);

has _markets => (
    is         => 'rw',
    lazy_build => 1,
);

sub _build_all_parameters {
    my $self = shift;

    return YAML::CacheLoader::LoadFile('/home/git/bom/config/files/underlyings.yml');
}

sub _build__markets {
    my $self = shift;
    my @markets =
        map { $_->name } BOM::Market::Registry->instance->display_markets;
    return \@markets;
}

=head2 $self->cached_underlyings

Return reference to the hash containing previously created underlying objects.
If underlyings.yml changed, cache will be flushed.

=cut

sub cached_underlyings {
    my $self = shift;
    return $self->_cached_underlyings;
}

=head2 $self->markets

Return list of all markets for which we have symbols

=cut

sub markets {
    return @{shift->_markets};
}

=head2 $self->symbols

Return list of all underlyings from the db

=cut

sub symbols {
    my $self = shift;
    return keys %{$self->all_parameters};
}

=head2 $self->get_parameters_for($symbol)

Return reference to hash with parameters for given symbol.

=cut

sub get_parameters_for {
    my ($self, $underlying) = @_;
    return $self->all_parameters->{$underlying};
}

=head2 $self->available_contract_categories

Return list of all available contract categories

=cut

sub available_contract_categories {
    return qw(asian digits callput endsinout spreads touchnotouch staysinout);
}

=head2 $self->available_expiry_types

Return list of all available bet sub types

=cut

sub available_expiry_types {
    return qw(intraday daily tick);
}

=head2 $self->available_start_types

Return list of all available start types

=cut

sub available_start_types {
    return qw(spot forward);
}

=head2 $self->available_barrier_categories

Return list of all available barrier_categories

=cut

sub available_barrier_categories {
    return qw(euro_atm euro_non_atm american non_financial asian spreads);
}

=head2 $self->available_iv_categories

Return list of all available iv contract categories

=cut

sub available_iv_categories {
    return qw(callput endsinout touchnotouch staysinout);
}

__PACKAGE__->meta->make_immutable;

1;
