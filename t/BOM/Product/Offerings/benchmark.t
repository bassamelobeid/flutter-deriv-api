#!/etc/rmg/bin/perl

use Test::More tests => 1;

use BOM::Platform::Offerings qw(get_offerings_with_filter);
use BOM::Platform::LandingCompany::Registry;
use Finance::Asset::Market::Registry;
use Finance::Asset::SubMarket::Registry;

use Time::HiRes;

subtest 'benchmark offerings' => sub {
    foreach my $lc (map { $_->short } BOM::Platform::LandingCompany::Registry->new->all) {
        my $before = Time::HiRes::time;
        get_offerings_with_filter('market', {landing_company => $lc});
        my $diff = Time::HiRes::time - $before;
        cmp_ok($diff, "<", 1, "construction of $lc offerings objectis less that 1 seconds");
        foreach my $market (map { $_->name } Finance::Asset::Market::Registry->all) {
            my @common_calls = [
                'submarket',
                {
                    market          => $market,
                    landing_company => $lc
                }];
            foreach my $submarket (map { $_->name } Finance::Asset::SubMarket::Registry->all) {
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
