package BOM::Product::Types;

use strict;
use warnings;

use Moose;

=head1 NAME

BOM::Product::Types - validated Moose types with BetOnMarkets-specific semantics

=head1 VERSION

Version 0.01

=head1 SYNOPSIS

This module provides validated definition of various datatypes that are prevalent through the BetOnMarkets system. By convention, these types are all prefixed with 'bom_' in order to avoid namespace collisions.

=cut

use MooseX::Types::Moose qw(Int Num Str);
use MooseX::Types -declare => ['PositiveNum'];
extends 'BOM::MarketData::Types';
use Moose::Util::TypeConstraints;

subtype
    'PositiveNum'       => as 'Num',
    => where { $_ > 0 } => message { 'Must be positive number: [' . $_ . ']' };

=head1 AUTHOR

Nick Marden, C<< <nick at regentmarkets dot com> >>

=head1 COPYRIGHT

(c) 2010 RMG Technology (Malaysia) Sdn Bhd

=cut

no Moose;
no Moose::Util::TypeConstraints;
__PACKAGE__->meta->make_immutable;
1;
