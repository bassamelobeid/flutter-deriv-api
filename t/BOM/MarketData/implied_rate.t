#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 2;
use Test::Exception;
use Test::NoWarnings;

use BOM::Test::Data::Utility::UnitTestCouchDB qw( :init );

use BOM::MarketData::ImpliedRate;
use Date::Utility;

subtest 'save implied rate' => sub {
    lives_ok {
        throws_ok { BOM::MarketData::ImpliedRate->new(symbol => 'USD-JPY')->document } qr/404/, 'document is not present';
        my $imp = BOM::MarketData::ImpliedRate->new(
            symbol        => 'USD-JPY',
            rates         => {365 => 0},
            recorded_date => Date::Utility->new('2014-10-10'),
            type          => 'implied',
        );
        ok $imp->save, 'save successfully';
        lives_ok {
            my $new = BOM::MarketData::ImpliedRate->new(symbol => 'USD-JPY');
            ok $new->document;
            is $new->type, 'implied';
        }
        'retrieved saved document';
    }
    'successfully save implied rate';
};
