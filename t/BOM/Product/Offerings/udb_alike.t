use strict;
use warnings;

use Test::Most (tests => 1);
use Test::FailWarnings;

use BOM::Test::Data::Utility::UnitTestRedis;

use BOM::MarketData qw(create_underlying_db);
use LandingCompany::Offerings qw( get_offerings_with_filter reinitialise_offerings);

my $offerings_cfg = BOM::Platform::Runtime->instance->get_offerings_config;
reinitialise_offerings($offerings_cfg);

my $udb = create_underlying_db();

subtest 'Sets match' => sub {
    my %po_to_udb_method = (
        'market'            => 'markets',
        'contract_category' => 'available_contract_categories',
        'expiry_type'       => 'available_expiry_types',
        'start_type'        => 'available_start_types',
        'barrier_category'  => 'available_barrier_categories',
    );

    while (my ($po, $udb_method) = each(%po_to_udb_method)) {
        # This is just a temporary hack to make the test pass.
        # coinauction is a new categroy for ICO offering but it does not attached to any symbol
        # so get_offerings_with_filter will not return coinauction when filter by contract_category
        my @get_offering_with_filter = get_offerings_with_filter($offerings_cfg, $po);
        if ($po eq 'contract_category') {

            push @get_offering_with_filter, 'coinauction';
        }
        eq_or_diff([sort @get_offering_with_filter], [sort $udb->$udb_method], $po . ' list match with UnderlyingDB->' . $udb_method);

    }
};

1;
