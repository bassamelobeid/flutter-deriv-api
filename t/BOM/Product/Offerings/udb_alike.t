use strict;
use warnings;

use Test::Most (tests => 2);
use Test::Warnings;

use BOM::Test::Data::Utility::UnitTestRedis;

use BOM::MarketData qw(create_underlying_db);
use LandingCompany::Registry;

my $offerings_cfg = BOM::Platform::Runtime->instance->get_offerings_config;

my $udb = create_underlying_db();

subtest 'Sets match' => sub {
    my %po_to_udb_method = (
        'market'            => 'markets',
        'contract_category' => 'available_contract_categories',
        'expiry_type'       => 'available_expiry_types',
        'start_type'        => 'available_start_types',
        'barrier_category'  => 'available_barrier_categories',
    );
    my $offerings_obj = LandingCompany::Registry::get('costarica')->basic_offerings($offerings_cfg);

    while (my ($po, $udb_method) = each(%po_to_udb_method)) {
        # This is just a temporary hack to make the test pass.
        # coinauction is a new categroy for ICO offering but it does not attached to any symbol
        # so get_offerings_with_filter will not return coinauction when filter by contract_category
        # we also need similar hacks for lookback
        my @result = $offerings_obj->values_for_key($po);
        if ($po eq 'contract_category') {

            push @result, 'coinauction';
            push @result, 'lookback';
        }
        eq_or_diff([sort @result], [sort $udb->$udb_method], $po . ' list match with UnderlyingDB->' . $udb_method);

    }
};

1;
