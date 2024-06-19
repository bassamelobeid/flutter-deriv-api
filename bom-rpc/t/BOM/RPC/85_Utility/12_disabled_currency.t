use strict;
use warnings;

use Test::Most;
use BOM::RPC::v3::Utility;

subtest 'Filter out signup disabled currencies' => sub {
    my $currencies = ['GBP', 'USD', 'EUR'];

    is_deeply(
        BOM::RPC::v3::Utility::filter_out_signup_disabled_currencies('maltainvest', $currencies),
        ['EUR', 'USD'],
        "Disabled currency is removed from the arrayref for maltainvest."
    );

    is_deeply(
        BOM::RPC::v3::Utility::filter_out_signup_disabled_currencies('svg', $currencies),
        ['EUR', 'GBP', 'USD'],
        "Sorted arrayref is returned for svg."
    );
};

done_testing();
