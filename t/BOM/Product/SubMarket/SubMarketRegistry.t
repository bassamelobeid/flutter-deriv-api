use strict;
use warnings;

use Test::MockTime qw(:all);
use Test::More tests => 2;
use Test::NoWarnings;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);
use BOM::Market::SubMarket;
use BOM::Market::SubMarket::Registry;

subtest 'BOM::Market::SubMarket::Registry' => sub {
    plan tests => 25;

    my $random_daily = BOM::Market::SubMarket::Registry->instance->get('random_daily');
    is($random_daily->name,                      'random_daily', 'name');
    is($random_daily->display_name,              'Daily Reset Indices',   'display name');
    is($random_daily->translated_display_name(), 'Daily Reset Indices',   'translated display name - by default language = EN');
    is($random_daily->market->name,              'volidx',       'market');

    my $invalid = BOM::Market::SubMarket::Registry->instance->get('forex_test');
    is($invalid, undef, 'invalid Sub Market');

    my %markets = (
        forex       => 3,
        volidx      => 3,
        indices     => 5,
        stocks      => 3,
        commodities => 2,
    );

    foreach my $market (keys %markets) {
        my @found_submarkets = BOM::Market::SubMarket::Registry->find_by_market($market);
        is(scalar @found_submarkets, $markets{$market}, 'found proper number of sub markets for ' . $market);
        my $first_example = $found_submarkets[0];
        isa_ok($first_example, 'BOM::Market::SubMarket', 'Properly returning SubMarket Objects');
        is($first_example->display_order, 1,       'First out is first in order');
        is($first_example->market->name,  $market, 'And on the correct market');
    }

};

