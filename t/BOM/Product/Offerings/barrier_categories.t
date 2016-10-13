use strict;
use warnings;

use Test::Most (tests => 1);
use Test::FailWarnings;

use BOM::Test::Data::Utility::UnitTestRedis;

use BOM::MarketData qw(create_underlying_db);
use BOM::Platform::Offerings qw( get_offerings_with_filter );

my $udb = Quant::Framework::UnderlyingDB->new;

subtest 'Sets match' => sub {

    my %expected = %{$BOM::Platform::Offerings::BARRIER_CATEGORIES};

    eq_or_diff(
        [sort(get_offerings_with_filter('contract_category'))],
        [sort keys %expected],
        'Expectations set for all available contract categories'
    );

    while (my ($cc, $hoped) = each(%expected)) {
        eq_or_diff([sort(get_offerings_with_filter('barrier_category', {contract_category => $cc}))], $hoped, '... ' . $cc . ' meets expectations');

    }
};

1;
