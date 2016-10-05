use strict;
use warnings;

use Test::Most (tests => 1);
use Test::FailWarnings;

use BOM::Test::Data::Utility::UnitTestRedis;

use BOM::Market::UnderlyingDB;
use BOM::Product::Offerings qw( get_offerings_with_filter );

my $udb = BOM::Market::UnderlyingDB->new;

subtest 'Sets match' => sub {

    my %expected = %{$BOM::Product::Offerings::BARRIER_CATEGORIES};

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
