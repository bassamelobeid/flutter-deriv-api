#!/usr/bin/perl

use strict;
use warnings;

use Test::More (tests => 4);
use Test::Exception;
use Test::NoWarnings;

use BOM::MarketData::Fetcher::CorporateAction;
use Quant::Framework::Utils::Test;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);

Quant::Framework::Utils::Test::create_doc('corporate_action',
    {
        chronicle_reader => BOM::System::Chronicle::get_chronicle_reader(),
        chronicle_writer => BOM::System::Chronicle::get_chronicle_writer()
    });

lives_ok {
    my $corp    = BOM::MarketData::Fetcher::CorporateAction->new;
    my $actions = $corp->get_underlyings_with_corporate_action;
    my @symbols = keys %$actions;
    is scalar @symbols, 1, 'only one underlying with action';
    is $symbols[0], 'FPFP', 'underlying is FPFP';
}
'get underlying with actions';
