#!/usr/bin/perl

use strict;
use warnings;

use Test::More (tests => 4);
use Test::Exception;
use Test::NoWarnings;

use BOM::MarketData::Fetcher::CorporateAction;
use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('corporate_action');

lives_ok {
    my $corp    = BOM::MarketData::Fetcher::CorporateAction->new;
    my $actions = $corp->get_underlyings_with_corporate_action;
    my @symbols = keys %$actions;
    is scalar @symbols, 1, 'only one underlying with action';
    is $symbols[0], 'FPFP', 'underlying is FPFP';
}
'get underlying with actions';
