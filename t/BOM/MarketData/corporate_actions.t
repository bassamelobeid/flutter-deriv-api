#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 10;
use Test::Exception;
use Test::NoWarnings;
use Date::Utility;

use BOM::MarketData::CorporateAction;

is(BOM::MarketData::CorporateAction->new(symbol => 'FPGZ')->document, undef, 'document is not present');

my $int = BOM::MarketData::CorporateAction->new(
    symbol        => 'QWER',
    actions       => {
        "62799500" => {
            "monitor_date" => "2014-02-07T06:00:07Z",
            "type" => "ACQUIS",
            "monitor" => 1,
            "description" =>  "Acquisition",
            "effective_date" =>  "15-Jul-14",
            "flag" => "N"
        },
    }
);

my $now = Date::Utility->new();
ok $int->save, 'save without error';

lives_ok {
    my $new = BOM::MarketData::CorporateAction->new(symbol => 'QWER');
    ok $new->document;
    is $new->document->{actions}->{62799500}->{type}, "ACQUIS";
    is $new->document->{actions}->{62799500}->{effective_date}, "15-Jul-14";
} 'successfully retrieved saved document';

lives_ok {
    my $int = BOM::MarketData::CorporateAction->new(
        symbol        => 'QWER',
        actions       => {
            "32799500" => {
                "monitor_date" => "2015-02-07T06:00:07Z",
                "type" => "DIV",
                "monitor" => 1,
                "description" =>  "Divided Stocks",
                "effective_date" =>  "15-Jul-15",
                "flag" => "N"
            },
        }
    );

    sleep 1; #at least wait one second
    ok $int->save, 'save again without error';

    my $old_corp_action = BOM::MarketData::CorporateAction->new(
        symbol      => 'QWER',
        for_date    => $now);

    is $old_corp_action->document->{actions}->{62799500}->{type}, "ACQUIS";
} 'successfully reads older corporate actions';
