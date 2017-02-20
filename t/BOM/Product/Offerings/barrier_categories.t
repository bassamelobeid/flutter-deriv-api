use strict;
use warnings;

use Test::Most (tests => 1);
use Test::FailWarnings;

use BOM::Test::Data::Utility::UnitTestRedis;

use BOM::MarketData qw(create_underlying_db);
use BOM::Platform::Runtime;
use LandingCompany::Offerings qw( get_offerings_with_filter reinitialise_offerings);

my $udb = create_underlying_db();
reinitialise_offerings(BOM::Platform::Runtime->instance->get_offerings_config);

subtest 'Sets match' => sub {

    my %expected = %{$LandingCompany::Offerings::BARRIER_CATEGORIES};
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
