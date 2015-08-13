#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 2;
use Test::Exception;
use Test::NoWarnings;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

use BOM::Product::Contract::Finder qw(available_contracts_for_symbol);

subtest "available contracts for symbol" => sub {
    my %input = (
        random  => ['R_100',     'RDMARS',    'RDBEAR'],
        forex   => ['frxUSDJPY', 'frxAUDCAD', 'WLDUSD'],
        indices => ['AEX',       'SYNAEX'],
        stocks  => ['FPCS'],
        commodities => ['frxXAUUSD', 'frxXPDUSD'],
    );
    my %expected = (
        R_100 => {
            callput      => 12,
            touchnotouch => 4,    # intraday and daily separated
            staysinout   => 4,
            endsinout    => 4,
            digits       => 2,
            asian        => 2,
            spreads      => 2
        },
        RDMARS => {
            callput   => 8,
            endsinout => 2,
            digits    => 2,
            asian     => 2,
        },
        RDBEAR => {
            callput      => 8,
            touchnotouch => 2,    # intraday and daily separated
            staysinout   => 2,
            endsinout    => 2,
            digits       => 2,
            asian        => 2,
        },
        frxUSDJPY => {
            callput      => 12,
            touchnotouch => 4,    # intraday and daily separated
            staysinout   => 2,
            endsinout    => 2,
        },
        frxAUDCAD => {
            callput => 6,
        },
        WLDUSD => {
            callput => 4,
        },
        AEX => {
            callput      => 8,
            touchnotouch => 2,    # intraday and daily separated
            staysinout   => 2,
            endsinout    => 2,
        },
        SYNAEX => {
            callput => 4,
        },
        FPCS => {
            callput => 4,
        },
        frxXAUUSD => {
            callput      => 8,
            touchnotouch => 2,    # intraday and daily separated
            staysinout   => 2,
            endsinout    => 2,
        },
        frxXPDUSD => {
            callput => 2,
        },
    );
    foreach my $market (keys %input) {
        foreach my $u (@{$input{$market}}) {
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
                underlying => $u,
                epoch      => time,
                quote      => 100
            });
            my $f = available_contracts_for_symbol($u);
            my %got;
            $got{$_->{contract_category}}++ for (@{$f->{available}});
            cmp_ok $got{$_}, '==', $expected{$u}{$_}, "expected outcome for $u-$_" for (keys %{$expected{$u}});
        }
    }
};
