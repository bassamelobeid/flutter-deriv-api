#!/etc/rmg/bin/perl

use Test::More tests => 2;
use Test::Warnings;
use LandingCompany::Registry;
use Finance::Asset::Market::Registry;
use Finance::Asset::SubMarket::Registry;
use BOM::Config::Runtime;

use Time::HiRes;

subtest 'benchmark offerings' => sub {
    foreach my $lc (LandingCompany::Registry->new->all) {
        my $before = Time::HiRes::time;
        my $config = BOM::Config::Runtime->instance->get_offerings_config;

        my $offerings_obj = $lc->basic_offerings($config);
        $offerings_obj->values_for_key('market');
        my $diff = Time::HiRes::time - $before;
        cmp_ok($diff, "<", 1, "construction of " . $lc->short . " offerings objectis less that 1 seconds");
        foreach my $market (map { $_->name } Finance::Asset::Market::Registry->all) {
            my @common_calls = [{
                    market          => $market,
                    landing_company => $lc->short
                },
                ['submarket']];
            foreach my $submarket (map { $_->name } Finance::Asset::SubMarket::Registry->all) {
                push @common_calls,
                    [{
                        submarket       => $submarket,
                        market          => $market,
                        landing_company => $lc->short
                    },
                    ['underlying_symbol']];
                push @common_calls,
                    [{
                        submarket       => $submarket,
                        market          => $market,
                        landing_company => $lc->short
                    },
                    ['contract_type']];
                my $before = Time::HiRes::time;
                $offerings_obj->query(@{$_}) for @common_calls;
                my $diff = Time::HiRes::time - $before;
                my $avg  = $diff / @common_calls;
                cmp_ok($avg, "<", 0.002, 'average is less than 2ms');
            }
        }
    }
};
