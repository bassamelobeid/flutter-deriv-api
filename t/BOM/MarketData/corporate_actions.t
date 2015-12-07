#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 10;
use Test::Exception;
use Test::NoWarnings;
use Date::Utility;

use BOM::MarketData::CorporateAction;
use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);

is(BOM::MarketData::CorporateAction->new(symbol => 'FPGZ')->document, undef, 'document is not present');

my $old_date = Date::Utility->new()->minus_time_interval("15m");
my $int = BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('corporate_action', {
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
        },
        recorded_date => $old_date,
    }
);

ok $int->save, 'save without error';

lives_ok {
    my $new = BOM::MarketData::CorporateAction->new(symbol => 'QWER');
    ok $new->document;
    is $new->document->{actions}->{62799500}->{type}, "ACQUIS";
    is $new->document->{actions}->{62799500}->{effective_date}, "15-Jul-14";
} 'successfully retrieved saved document';

lives_ok {
    my $int = BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('corporate_action', {
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
        }
    );

    ok $int->save, 'save again without error';

    my $old_corp_action = BOM::MarketData::CorporateAction->new(
        symbol      => 'QWER',
        for_date    => $old_date);

    is $old_corp_action->document->{actions}->{62799500}->{type}, "ACQUIS";
} 'successfully reads older corporate actions';
