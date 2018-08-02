package BOM::RPC::v3::Pricing;

use 5.014;
use strict;
use warnings;

use BOM::RPC::Registry '-dsl';

use BOM::Pricing::v3::Contract;
use BOM::Pricing::v3::MarketData;

rpc send_ask => sub {
    my $params = shift;

    my $args_error = BOM::RPC::v3::Utility::contract_args_check($params->{args});
    return $args_error if $args_error;

    return BOM::Pricing::v3::Contract::send_ask($params);
};

rpc get_bid => \&BOM::Pricing::v3::Contract::get_bid;

rpc get_contract_details => \&BOM::Pricing::v3::Contract::get_contract_details;

rpc contracts_for => \&BOM::Pricing::v3::Contract::contracts_for;

rpc trading_times => \&BOM::Pricing::v3::MarketData::trading_times;

rpc asset_index => \&BOM::Pricing::v3::MarketData::asset_index;

1;
