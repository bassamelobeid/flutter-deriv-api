#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 2;
use Test::Deep;
use Test::NoWarnings;

use BOM::Platform::Runtime;

my $all = [qw(
        asian
        callput
        digits
        endsinout
        staysinout
        touchnotouch
        )];
my $no_spreads = [qw(
        asian
        callput
        digits
        endsinout
        staysinout
        touchnotouch
        )];
subtest 'legal allowed contract categories' => sub {
    for (qw(VRTC CR)) {
        my $cc = BOM::Platform::Runtime->instance->broker_codes->landing_company_for($_ . '123123')->legal_allowed_contract_categories;
        cmp_bag($cc, $all, $_ . ' has all contract categories');
    }
    for (qw(MX MLT MF)) {
        my $cc = BOM::Platform::Runtime->instance->broker_codes->landing_company_for($_ . '123123')->legal_allowed_contract_categories;
        cmp_bag($cc, $no_spreads, $_ . ' has contract categories except spreads');
    }
};
