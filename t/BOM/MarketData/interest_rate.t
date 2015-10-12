#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 2;
use Test::Exception;
use Test::NoWarnings;

use BOM::Test::Data::Utility::UnitTestCouchDB qw( :init );

use BOM::MarketData::InterestRate;

subtest 'save interest rate' => sub {
    throws_ok { BOM::MarketData::InterestRate->new(symbol => 'USD')->document } qr/404/, 'document is not present';
    lives_ok {
        my $int = BOM::MarketData::InterestRate->new(
            symbol        => 'USD',
            rates         => {365 => 0},
            recorded_date => Date::Utility->new('2014-10-10'),
        );
        ok $int->save, 'save without error';
        lives_ok {
            my $new = BOM::MarketData::InterestRate->new(symbol => 'USD');
            ok $new->document;
            is $new->type, 'market';
        }
        'successfully retrieved saved document from couch';
    }
    'successfully save interest rates for USD';
};
