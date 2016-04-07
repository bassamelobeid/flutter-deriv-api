use strict;
use warnings;

use Test::More (tests => 3);
use Test::NoWarnings;
use Test::Exception;

use BOM::RPC::v3::Japan::Contract;
use BOM::RPC::v3::Utility;

subtest validate_table_props => sub {

    is(
        BOM::RPC::v3::Japan::Contract::validate_table_props({
                symbol            => 'frxEURUSD',
                date_expiry       => 1459406383,
                contract_category => 'callput',
            }
        ),
        undef,
        'validate_table_props'
    );
};

subtest get_channel_name => sub {

    is(
        BOM::RPC::v3::Japan::Contract::get_channel_name({
                symbol            => 'frxEURUSD',
                date_expiry       => 1459406383,
                contract_category => 'callput',
            }
        ),
        'PricingTable::frxEURUSD::callput::1459406383',
        'get_channel_name'
    );
};
