#!/usr/bin/perl

use Test::More tests => 2;
use Test::NoWarnings;

use BOM::Product::Offerings qw(get_offerings_with_filter);
use BOM::Platform::Runtime::LandingCompany::Registry;
use BOM::Market::Registry;
use BOM::Market::SubMarket::Registry;

use Time::HiRes;

subtest 'benchmarket offerings' => sub {
    foreach my $lc (map { $_->short } BOM::Platform::Runtime::LandingCompany::Registry->new->all) {
        my $before = Time::HiRes::time;
        get_offerings_with_filter('market', {landing_company => $lc});
        my $diff = Time::HiRes::time - $before;
        cmp_ok($diff, "<", 2.5, "construction of $lc offerings objectis less that 2 seconds");
        foreach my $market (map { $_->name } BOM::Market::Registry->all) {
            my @common_calls = [
                'submarket',
                {
                    market          => $market,
                    landing_company => $lc
                }];
            foreach my $submarket (map { $_->name } BOM::Market::SubMarket::Registry->all) {
                push @common_calls,
                    [
                    'underlying_symbol',
                    {
                        submarket       => $submarket,
                        market          => $market,
                        landing_company => $lc
                    }];
                push @common_calls,
                    [
                    'contract_type',
                    {
                        submarket       => $submarket,
                        market          => $market,
                        landing_company => $lc
                    }];
                my $before = Time::HiRes::time;
                get_offerings_with_filter(@{$_}) for @common_call;
                my $diff = Time::HiRes::time - $before;
                my $avg  = $diff / @common_calls;
                cmp_ok($avg, "<", 0.002, 'average is less than 2ms');
            }
        }
    }
};
