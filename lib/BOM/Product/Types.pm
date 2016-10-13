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

    package MyClass;

    use Moose;

    use BOM::Product::Types qw( bom_contract_category );

    has 'contract_category' => (
        is  => 'rw',
        isa => 'bom_contract_category',
    );

    package main;

    my $good = new MyClass( client_loginid => 'CR1234' ); # works
    my $bad = new MyClass( client_loginid => 'fribitz' ); # dies with an explanation


=cut

use MooseX::Types::Moose qw(Int Num Str);
use MooseX::Types -declare => [
    map { "bom_$_" }
        qw(
        contract_category
        ),
    'PositiveNum'
];
extends 'BOM::MarketData::Types';
use Moose::Util::TypeConstraints;

subtype 'bom_contract_category', as 'BOM::Product::Contract::Category';
coerce 'bom_contract_category', from 'Str', via { BOM::Product::Contract::Category->new($_) };

subtype
    'PositiveNum' => as 'Num',
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
