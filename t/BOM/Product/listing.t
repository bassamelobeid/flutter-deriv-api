#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Exception;
use Test::FailWarnings;

use BOM::Product::Listing;

subtest 'exceptions' => sub {
    my $error;
    lives_ok { $error = BOM::Product::Listing->new->by_country() } 'throws exception if country code is undefined';
    is $error->{error_code}, 'UndefinedCountryCode', 'error code - UndefinedCountryCode';
    lives_ok { $error = BOM::Product::Listing->new->by_country('unknown') } 'throws exception if country code is invalid';
    is $error->{error_code}, 'InvalidCountryCode', 'error code - InvalidCountryCode';
    lives_ok { BOM::Product::Listing->new->by_country('id', [123]) } 'throws exception if app is unknown';
};

subtest 'product listing - deriv smarttrader' => sub {
    my $app_id        = 22168;
    my $deriv_dtrader = BOM::Product::Listing->new->by_country('id', [$app_id]);

    cmp_bag $deriv_dtrader->{$app_id}->{available_markets},     ['Commodities', 'Forex', 'Stock Indices', 'Derived'], 'available markets matched';
    cmp_bag $deriv_dtrader->{$app_id}->{available_trade_types}, ['Options'],                                          'available trade types matched';
    is scalar $deriv_dtrader->{$app_id}->{product_list}->@*, 69, '69 listing';
    # check the structure
    cmp_bag [keys $deriv_dtrader->{$app_id}->{product_list}->[0]->%*],
        ['available_account_types', 'available_trade_types', 'symbol', 'market', 'submarket'],
        'data structure matched';
};

subtest 'product listing - deriv binarybot' => sub {
    my $app_id          = 29864;
    my $deriv_binarybot = BOM::Product::Listing->new->by_country('id', [$app_id]);

    cmp_bag $deriv_binarybot->{$app_id}->{available_markets},     ['Commodities', 'Forex', 'Stock Indices', 'Derived'], 'available markets matched';
    cmp_bag $deriv_binarybot->{$app_id}->{available_trade_types}, ['Options'], 'available trade types matched';
    is scalar $deriv_binarybot->{$app_id}->{product_list}->@*, 69, '69 listing';
    # check the structure
    cmp_bag [keys $deriv_binarybot->{$app_id}->{product_list}->[0]->%*],
        ['available_account_types', 'available_trade_types', 'symbol', 'market', 'submarket'],
        'data structure matched';

};

# we will only be testing for certain platforms, since it's a data structure test rather than testing the correctness of data.
subtest 'product listing - deriv dtrader' => sub {
    my $app_id        = 16929;
    my $deriv_dtrader = BOM::Product::Listing->new->by_country('id', [$app_id]);
    cmp_bag $deriv_dtrader->{$app_id}->{available_markets},
        ['Commodities', 'Cryptocurrencies', 'Forex', 'Stock Indices', 'Derived'],
        'available markets matched';
    cmp_bag $deriv_dtrader->{$app_id}->{available_trade_types}, ['Accumulators', 'Multipliers', 'Options', 'Spreads'],
        'available trade types matched';
    is scalar $deriv_dtrader->{$app_id}->{product_list}->@*, 79, '79 listing';
    # check the structure
    cmp_bag [keys $deriv_dtrader->{$app_id}->{product_list}->[0]->%*],
        ['available_account_types', 'available_trade_types', 'symbol', 'market', 'submarket'],
        'data structure matched';
};

subtest 'product listing - deriv bot' => sub {
    my $app_id    = 19111;
    my $deriv_bot = BOM::Product::Listing->new->by_country('id', [$app_id]);
    cmp_bag $deriv_bot->{$app_id}->{available_markets}, ['Commodities', 'Forex', 'Stock Indices', 'Derived'], 'available markets matched';
    cmp_bag $deriv_bot->{$app_id}->{available_trade_types}, ['Options', 'Multipliers'], 'available trade types matched';
    is scalar $deriv_bot->{$app_id}->{product_list}->@*, 74, '74 listing';
    # check the structure
    cmp_bag [keys $deriv_bot->{$app_id}->{product_list}->[0]->%*],
        ['available_account_types', 'available_trade_types', 'symbol', 'market', 'submarket'],
        'data structure matched';
};

subtest 'product listing - deriv go' => sub {
    my $app_id   = 23789;
    my $deriv_go = BOM::Product::Listing->new->by_country('id', [$app_id]);
    cmp_bag $deriv_go->{$app_id}->{available_markets}, ['Cryptocurrencies', 'Forex', 'Derived', 'Commodities', 'Stock Indices'],
        'available markets matched';
    cmp_bag $deriv_go->{$app_id}->{available_trade_types}, ['Accumulators', 'Multipliers', 'Options', 'Spreads'], 'available trade types matched';
    is scalar $deriv_go->{$app_id}->{product_list}->@*, 84, '84 listing';
    # check the structure
    cmp_bag [keys $deriv_go->{$app_id}->{product_list}->[0]->%*],
        ['available_account_types', 'available_trade_types', 'symbol', 'market', 'submarket'],
        'data structure matched';
};

done_testing();
