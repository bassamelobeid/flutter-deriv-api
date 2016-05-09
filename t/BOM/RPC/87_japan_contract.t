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
                date_start        => 1459405383,
                contract_category => 'callput',
            }
        ),
        undef,
        'validate_table_props'
    );

    is_deeply(
        BOM::RPC::v3::Japan::Contract::validate_table_props({
                symbol            => 'invalid',
                date_expiry       => 1459406383,
                date_start        => 1459405383,
                contract_category => 'callput',
            }
        ),
        {
            error => {
                code    => 'InvalidSymbol',
                message => "Symbol [_1] invalid",
                params  => [qw/ invalid /],
            }
        },
        'validate_table_props'
    );

    is_deeply(
        BOM::RPC::v3::Japan::Contract::validate_table_props({
                symbol            => 'frxEURUSD',
                date_expiry       => 'test',
                date_start        => 1459405383,
                contract_category => 'callput',
            }
        ),
        {
            error => {
                code    => 'InvalidDateExpiry',
                message => "Date expiry [_1] invalid",
                params  => [qw/ test /],
            }
        },
        'validate_table_props'
    );
};

subtest get_channel_name => sub {

    is(
        BOM::RPC::v3::Japan::Contract::get_channel_name({
                symbol            => 'frxEURUSD',
                date_expiry       => 1459406383,
                date_start        => 1459405383,
                contract_category => 'callput',
            }
        ),
        'PricingTable::frxEURUSD::callput::1459405383::1459406383',
        'get_channel_name'
    );
};
