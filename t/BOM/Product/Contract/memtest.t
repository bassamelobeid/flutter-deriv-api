#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::Memory::Cycle;

use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Product::Offerings qw(get_offerings_with_filter);

my @contract_types = get_offerings_with_filter('contract_type');
my @submarkets = get_offerings_with_filter('submarket');
my @underlyings = map {(get_offerings_with_filter('underlying_symbol', {submarket => $_}))[0]} @submarkets;
my 
foreach my $type (@contract_types) {
    foreach my $u_symbol (@underlyings) {
    
    }
}
