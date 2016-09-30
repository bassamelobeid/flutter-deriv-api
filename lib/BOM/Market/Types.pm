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

    use BOM::Market::Types qw( bom_financial_market );

    has 'financial_market' => (
        is  => 'rw',
        isa => 'bom_financial_market',
    );

    package main;

    my $good = new MyClass( financial_market => 'CR1234' ); # works
    my $bad = new MyClass( financial_market => 'fribitz' ); # dies with an explanation


=cut

use POSIX qw( );
use DateTime;
use Data::Validate::IP qw( );
use Math::BigInt;
use Time::Duration::Concise;

use MooseX::Types::Moose qw(Int Num Str);
use MooseX::Types -declare => [
    map { "bom_$_" }
        qw(
        financial_market
        submarket
        contract_type
        market_markups
        market_feed
        surface_type
        date_object
        time_interval
        )];

use Moose::Util::TypeConstraints;
use Try::Tiny;

subtype 'bom_time_interval', as 'Time::Duration::Concise';
coerce 'bom_time_interval', from 'Str', via { Time::Duration::Concise->new(interval => $_) };

subtype 'bom_date_object', as 'Date::Utility';
coerce 'bom_date_object', from 'Str', via { Date::Utility->new($_) };

my @surface_types = qw(delta flat moneyness);
subtype 'bom_surface_type', as Str, where {
    my $regex = '(' . join('|', @surface_types) . ')';
    /^$regex$/;
}, message {
    "Invalid surface type $_. Must be one of: " . join(', ', @surface_types);
};

subtype 'bom_financial_market', as 'BOM::Market';
coerce 'bom_financial_market', from 'Str', via { return BOM::Market::Registry->instance->get($_); };

subtype 'bom_submarket', as 'BOM::Market::SubMarket';
coerce 'bom_submarket', from 'Str', via { return BOM::Market::SubMarket::Registry->instance->get($_); };

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
