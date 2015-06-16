use strict;
use warnings;

use Test::Most (tests => 1);
use Test::FailWarnings;

use BOM::Test::Data::Utility::UnitTestRedis;

use BOM::Market::UnderlyingDB;
use BOM::Product::Offerings qw( get_offerings_with_filter );

my $udb = BOM::Market::UnderlyingDB->new;

subtest 'Sets match' => sub {
    my %po_to_udb_method = (
        'market'            => 'markets',
        'contract_category' => 'available_contract_categories',
        'expiry_type'       => 'available_expiry_types',
        'start_type'        => 'available_start_types',
        'barrier_category'  => 'available_barrier_categories',
    );

    while (my ($po, $udb_method) = each(%po_to_udb_method)) {
        eq_or_diff([sort(get_offerings_with_filter($po))], [sort $udb->$udb_method], $po . ' list match with UnderlyingDB->' . $udb_method);

    }
};

1;
