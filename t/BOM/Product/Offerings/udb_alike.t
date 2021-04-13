use strict;
use warnings;

use Test::Most (tests => 2);
use Test::Warnings;

use BOM::Test::Data::Utility::UnitTestRedis;

use BOM::MarketData qw(create_underlying_db);
use LandingCompany::Registry;

my $non_offerings = {markets => ['stocks']};
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

    subtest 'Virtual' => sub {
        my $offerings_obj = LandingCompany::Registry::get('virtual')->basic_offerings($offerings_cfg);

        while (my ($po, $udb_method) = each(%po_to_udb_method)) {
            my @result     = $offerings_obj->values_for_key($po);
            my @udb_result = $udb->$udb_method;

            if (defined $non_offerings->{$udb_method}) {
                my @tmp_result = @udb_result;
                @udb_result = ();

                for my $item (@tmp_result) {
                    next if grep { $_ eq $item } $non_offerings->{$udb_method}->@*;
                    push @udb_result, $item;
                }
            }

            eq_or_diff([sort @result], [sort @udb_result], $po . ' list match with UnderlyingDB->' . $udb_method);

        }
    };

    subtest 'SVG' => sub {
        my $offerings_obj = LandingCompany::Registry::get('svg')->basic_offerings($offerings_cfg);

        while (my ($po, $udb_method) = each(%po_to_udb_method)) {
            my @result     = $offerings_obj->values_for_key($po);
            my @udb_result = $udb->$udb_method;

            if (defined $non_offerings->{$udb_method}) {
                my @tmp_result = @udb_result;
                @udb_result = ();

                for my $item (@tmp_result) {
                    next if grep { $_ eq $item } $non_offerings->{$udb_method}->@*;
                    push @udb_result, $item;
                }
            }

            eq_or_diff([sort @result], [sort @udb_result], $po . ' list match with UnderlyingDB->' . $udb_method);

        }
    };
};

1;
