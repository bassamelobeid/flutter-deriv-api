package BOM::RPC::v3::Pricing;

use 5.014;
use strict;
use warnings;

use BOM::RPC::Registry '-dsl';

use BOM::Pricing::v3::Contract;
use BOM::Pricing::v3::MarketData;
use BOM::Pricing::v3::Utility;

rpc send_ask => sub {
    my ($params) = @_;

    my $response = BOM::Pricing::v3::Contract::send_ask($params);

    unless (exists $response->{error}) {
        my $relative_shortcode = BOM::Pricing::v3::Utility::create_relative_shortcode({$params->{args}->%*}, $response->{spot});
        BOM::Pricing::v3::Utility::update_price_metrics($relative_shortcode, $response->{rpc_time});
    }

    return $response;
};

rpc get_bid => \&BOM::Pricing::v3::Contract::get_bid;

rpc get_contract_details => \&BOM::Pricing::v3::Contract::get_contract_details;

rpc contracts_for => \&BOM::Pricing::v3::Contract::contracts_for;

rpc trading_times => \&BOM::Pricing::v3::MarketData::trading_times;

rpc asset_index => \&BOM::Pricing::v3::MarketData::asset_index;

rpc trading_durations => \&BOM::Pricing::v3::MarketData::trading_durations;

1;
