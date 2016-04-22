package BOM::Market::SubMarket::Registry;
use strict;
use warnings;

## no critic (RequireArgUnpacking,RequireLocalizedPunctuationVars)

=head1 NAME

BOM::Market::SubMarket::Registry

=head1 SYNOPSYS

    my $registry = BOM::Market::SubMarket::Registry->instance;
    my $submarket = $registry->get('volidx'); # By name

=head1 DESCRIPTION

This class parses a file describing submarkets and provides a singleton
lookup object to access this information. This is a singleton, you shouldn't
call I<new>, just get the object using I<instance> method.

=cut

use namespace::autoclean;
use MooseX::Singleton;
use Carp;

use BOM::Market::SubMarket;

with 'MooseX::Role::Registry';

=head1 METHODS

=head2 config_filename

The default location of the YML file describing known server roles.

=cut

sub config_file {
    return '/home/git/regentmarkets/bom-market/config/files/submarkets.yml';
}

=head2 build_registry_object

Builds a BOM::Market object from provided configuration.

=cut

sub build_registry_object {
    my $self   = shift;
    my $name   = shift;
    my $values = shift;

    return BOM::Market::SubMarket->new({
        name => $name,
        %$values
    });
}

sub find_by_market {
    my ($self, $market) = @_;
    Carp::croak("Usage: find_by_market(market_name)") if not $market;
    my @result = (
        sort { $a->{display_order} <=> $b->{display_order} }
        grep { $_->{market}->name eq $market and $_->{offered} == 1 } ($self->all));
    return @result;
}

__PACKAGE__->meta->make_immutable;
1;

=head1 AUTHOR

Shuwn Yuan, C<< <shuwnyuan at regentmarkets.com> >>

=head1 LICENSE AND COPYRIGHT

Copyright 2013 RMG Technology (M) Sdn Bhd

=cut

