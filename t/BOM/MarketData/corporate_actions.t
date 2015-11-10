#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 2;
use Test::Exception;
use Test::NoWarnings;
use Date::Utility;

use BOM::MarketData::CorporateAction;

#is(BOM::MarketData::CorporateAction->new(symbol => 'FPGZ')->document, undef, 'document is not present');

my $int = BOM::MarketData::CorporateAction->new(
    symbol        => 'QWER',
    recorded_date => Date::Utility->new('2014-10-10'),
    actions       => {
        "62799500" => {
            "monitor_date" => "2014-02-07T06:00:07Z",
            "type" => "ACQUIS",
            "monitor" => 1,
            "description" =>  "Acquisition",
            "effective_date" =>  "15-Jul-15",
            "flag" => "N"
        },
    }
);

ok $int->save, 'save without error';

lives_ok {
    my $new = BOM::MarketData::CorporateAction->new(symbol => 'QWER');
    ok $new->document;
    is $new->document->actions->{62799500}->{type}, "ACQUIS";
}
'successfully retrieved saved document';
