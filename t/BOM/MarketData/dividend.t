#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 2;
use Test::Exception;
use Test::NoWarnings;

use BOM::Test::Data::Utility::UnitTestChronicle qw(create_doc init_chronicle);

use BOM::MarketData::Dividend;
use Date::Utility;

init_chronicle;

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
        lives_ok { BOM::MarketData::Dividend->new(symbol => 'AEX')->document } 'successfully retrieved saved document from couch';
    }
    'sucessfully save dividend for AEX';
};
