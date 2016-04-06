package BOM::Market::Registry;
use strict;
use warnings;

## no critic (RequireArgUnpacking,RequireLocalizedPunctuationVars)

=head1 NAME

BOM::Market::Registry

=head1 SYNOPSYS

    my $registry = BOM::Market::Registry->instance;
    my $host = $registry->get('volidx'); # By name

=head1 DESCRIPTION

This class parses a file describing markets and provides a singleton
lookup object to access this information. This is a singleton, you shouldn't
call I<new>, just get the object using I<instance> method.

=cut

use namespace::autoclean;
use MooseX::Singleton;
use Carp;

use BOM::Market;
use List::Util qw( first );

with 'MooseX::Role::Registry';

=head1 METHODS

=head2 config_filename

The default location of the YML file describing known server roles.

=cut

sub config_file {
    return '/home/git/regentmarkets/bom-market/config/files/financial_markets.yml';
}

=head2 build_registry_object

Builds a BOM::Market object from provided configuration.

=cut

sub build_registry_object {
    my $self   = shift;
    my $name   = shift;
    my $values = shift;

    return BOM::Market->new({
        name => $name,
        %$values
    });
}

sub display_markets {
    my $self = shift;

    my @display_markets =
        sort { $a->display_order <=> $b->display_order }
        grep { $_->display_order } $self->all;
    return @display_markets;
}

sub all_market_names {
    my $self = shift;
    my @names = grep { $_ ne 'config' } map { $_->name } $self->display_markets;
    return @names;
}

__PACKAGE__->meta->make_immutable;

1;

=head1 AUTHOR

Arun Murali, C<< <arun at regentmarkets.com> >>

=head1 LICENSE AND COPYRIGHT

Copyright 2013 RMG Technology (M) Sdn Bhd

=cut

