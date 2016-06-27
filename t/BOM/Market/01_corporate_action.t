#!/usr/bin/perl

use strict;
use warnings;

use Test::More (tests => 3);
use Test::Exception;
use Test::NoWarnings;

use BOM::MarketData::Fetcher::CorporateAction;
use Date::Utility;
use Quant::Framework::Utils::Test;
use Quant::Framework::StorageAccessor;
use Quant::Framework::CorporateAction;

my $now = Date::Utility->new;

my $storage_accessor = Quant::Framework::StorageAccessor->new(
    chronicle_reader => BOM::System::Chronicle::get_chronicle_reader(),
    chronicle_writer => BOM::System::Chronicle::get_chronicle_writer(),
);
Quant::Framework::CorporateAction->create(
    storage_accessor => $storage_accessor,
    symbol           => 'USAAPL',
    for_date         => $now,
)->update({
        80004829 => {
            type        => 'DVD_CASH',
            flag        => 'N',
            description => 'Test Corporate Action',
            modifier    => 'divide',
            value       => 1.234
        },
    },
    $now
)->save;

my $corp    = BOM::MarketData::Fetcher::CorporateAction->new;
my $actions = $corp->get_underlyings_with_corporate_action;
my @symbols = keys %$actions;
is scalar @symbols, 1, 'only one underlying with action';
is $symbols[0], 'USAAPL', 'underlying is USAAPL';
