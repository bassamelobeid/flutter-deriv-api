use strict;
use warnings;

use Test::Most (tests => 2);
use Test::Warnings;

use BOM::Test::Data::Utility::UnitTestRedis;

use BOM::MarketData qw(create_underlying_db);
use LandingCompany::Registry;

my $offerings_cfg = BOM::Config::Runtime->instance->get_offerings_config;

my $udb = create_underlying_db();

subtest 'Sets match' => sub {
    my %po_to_udb_method = (
        'market'            => 'markets',
        'contract_category' => 'available_contract_categories',
        'expiry_type'       => 'available_expiry_types',
        'start_type'        => 'available_start_types',
        'barrier_category'  => 'available_barrier_categories',
    );
    my $offerings_obj = LandingCompany::Registry::get('virtual')->basic_offerings($offerings_cfg);

    while (my ($po, $udb_method) = each(%po_to_udb_method)) {
        my @result = $offerings_obj->values_for_key($po);
        eq_or_diff([sort @result], [sort $udb->$udb_method], $po . ' list match with UnderlyingDB->' . $udb_method);

    }

    $offerings_obj = LandingCompany::Registry::get('svg')->basic_offerings($offerings_cfg);

    eq_or_diff([ sort $offerings_obj->values_for_key('market')], [sort $udb->markets]);
    eq_or_diff([ sort $offerings_obj->values_for_key('contract_category')], [sort grep {$_ ne 'multiplier'} $udb->available_contract_categories]);
    eq_or_diff([ sort $offerings_obj->values_for_key('expiry_type')], [sort grep {$_ ne 'no_expiry'} $udb->available_expiry_types]);
    eq_or_diff([ sort $offerings_obj->values_for_key('start_type')], [sort $udb->available_start_types]);
    eq_or_diff([ sort $offerings_obj->values_for_key('barrier_category')], [sort $udb->available_barrier_categories]);
};

1;
