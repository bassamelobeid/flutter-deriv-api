use strict;
use warnings;

use Test::Most (tests => 2);
use Test::Warnings;

use BOM::Test::Data::Utility::UnitTestRedis;

use BOM::MarketData qw(create_underlying_db);
use BOM::Platform::Runtime;
use Finance::Contract;
use LandingCompany::Offerings qw( get_offerings_with_filter reinitialise_offerings);

reinitialise_offerings(BOM::Platform::Runtime->instance->get_offerings_config);
my $udb = create_underlying_db();

subtest 'Sets match' => sub {

    my %expected = %{$Finance::Contract::BARRIER_CATEGORIES};
    my $config   = BOM::Platform::Runtime->instance->get_offerings_config;

    eq_or_diff(
        [sort(get_offerings_with_filter($config, 'contract_category'))],
        [sort keys %expected],
        'Expectations set for all available contract categories'
    );

    while (my ($cc, $hoped) = each(%expected)) {
        eq_or_diff([sort(get_offerings_with_filter($config, 'barrier_category', {contract_category => $cc}))],
            $hoped, '... ' . $cc . ' meets expectations');

    }
};

1;
