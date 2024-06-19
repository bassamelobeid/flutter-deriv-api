#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;
use List::Util                               qw(all);
use BOM::Product::Offerings::TradingContract qw(get_contracts);
use BOM::Product::ContractFinder::Basic;
use Date::Utility;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);

my $now = Date::Utility->new;
BOM::Test::Data::Utility::UnitTestMarketData::create_doc('currency', {symbol => $_}) for qw(USD JPY AUD CAD EUR);
BOM::Test::Data::Utility::UnitTestMarketData::create_doc('index',    {symbol => $_}) for qw(frxAUDUSD frxXPDUSD);
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => $_,
        recorded_date => $now
    }) for qw(frxUSDJPY frxAUDCAD frxXAUUSD frxXPDUSD frxEURUSD);

subtest 'contract finder basic' => sub {
    my $symbol    = 'frxUSDJPY';
    my $contracts = BOM::Product::ContractFinder::Basic::decorate({
        offerings             => get_contracts({symbol => $symbol}),
        symbol                => $symbol,
        landing_company_short => 'virtual'
    });
    my %expected_forward_starting_params = (
        contract_category => 'callput',
        expiry_type       => 'intraday',
        start_type        => 'forward'
    );

    my %expected_forward_starting_params_callputequal = (
        contract_category => 'callputequal',
        expiry_type       => 'intraday',
        start_type        => 'forward'
    );

    foreach my $data (@{$contracts->{available}}) {
        if (   all { $data->{$_} eq $expected_forward_starting_params{$_} } qw(contract_category expiry_type start_type)
            or all { $data->{$_} eq $expected_forward_starting_params_callputequal{$_} } qw(contract_category expiry_type start_type))
        {
            ok exists $data->{forward_starting_options}, "forward starting options available for $data->{expiry_type} and $data->{contract_category}";
        } else {

            ok !exists $data->{forward_starting_options},
                "forward starting options not available for $data->{expiry_type} and $data->{contract_category}";
        }
    }
};

done_testing();
