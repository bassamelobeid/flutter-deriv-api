#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 2;
use Test::Exception;
use Test::NoWarnings;

#we need this import here so the market-data db will be fresh for the test
use BOM::Test::Data::Utility::UnitTestMarketData qw( :init );

use BOM::MarketData::Dividend;
use Date::Utility;

subtest 'save dividend' => sub {
    lives_ok {
        is(BOM::MarketData::Dividend->new(symbol => 'AEX')->document, undef, 'document is not present');
        my $dvd = BOM::MarketData::Dividend->new(
            rates           => {365          => 0},
            discrete_points => {'2014-10-10' => 0},
            recorded_date   => Date::Utility->new('2014-10-10'),
            symbol          => 'AEX',
        );
        ok $dvd->save, 'save without error';
        lives_ok { BOM::MarketData::Dividend->new(symbol => 'AEX')->document } 'successfully retrieved saved document from data-store';
    }
    'sucessfully save dividend for AEX';
};
