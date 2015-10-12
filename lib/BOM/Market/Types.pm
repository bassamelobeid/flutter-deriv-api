package BOM::Market::Types;

use strict;
use warnings;

use Moose;

=head1 NAME

BOM::Market::Types - validated Moose types with BetOnMarkets-specific semantics

=head1 VERSION

Version 0.01

=head1 SYNOPSIS

This module provides validated definition of various datatypes that are prevalent through the BetOnMarkets system. By convention, these types are all prefixed with 'bom_' in order to avoid namespace collisions.

    package MyClass;

    use Moose;

    use BOM::Market::Types qw( bom_client_loginid );

    has 'client_loginid' => (
        is  => 'rw',
        isa => 'bom_client_loginid',
    );

    package main;

    my $good = new MyClass( client_loginid => 'CR1234' ); # works
    my $bad = new MyClass( client_loginid => 'fribitz' ); # dies with an explanation


=cut

use POSIX qw( );
use DateTime;
use Data::Validate::IP qw( );
use Math::BigInt;

extends 'BOM::System::Types';
use MooseX::Types::Moose qw(Int Num Str);
use MooseX::Types -declare => [
    map { "bom_$_" }
        qw(
        financial_market
        submarket
        contract_type
        cutoff_helper
        market_markups
        market_feed
        )];

use Moose::Util::TypeConstraints;
use Try::Tiny;

subtype 'bom_financial_market', as 'BOM::Market';
coerce 'bom_financial_market', from 'Str', via { return BOM::Market::Registry->instance->get($_); };

subtype 'bom_submarket', as 'BOM::Market::SubMarket';
coerce 'bom_submarket', from 'Str', via { return BOM::Market::SubMarket::Registry->instance->get($_); };

subtype 'bom_cutoff_helper', as 'BOM::MarketData::VolSurface::Cutoff';
coerce 'bom_cutoff_helper', from 'Str', via { BOM::MarketData::VolSurface::Cutoff->new($_) };

subtype 'bom_market_markups', as 'BOM::Market::Markups';
coerce 'bom_market_markups', from 'HashRef' => via { BOM::Market::Markups->new($_); };

subtype 'bom_underlying_object', as 'BOM::Market::Underlying';
coerce 'bom_underlying_object', from 'Str', via { BOM::Market::Underlying->new($_) };

=head1 AUTHOR

Nick Marden, C<< <nick at regentmarkets dot com> >>

=head1 COPYRIGHT

(c) 2010 RMG Technology (Malaysia) Sdn Bhd

=cut

no Moose;
no Moose::Util::TypeConstraints;
__PACKAGE__->meta->make_immutable;

1;
