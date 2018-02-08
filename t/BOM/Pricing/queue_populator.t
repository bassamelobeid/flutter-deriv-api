#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Exception;
use BOM::Pricing::QueuePopulator::Japan;
use LandingCompany::Registry;
use Date::Utility;
use BOM::Platform::Runtime;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);

BOM::Test::Data::Utility::UnitTestMarketData::create_predefined_parameters_for($_, Date::Utility->new)
    for LandingCompany::Registry::get('japan')->multi_barrier_offerings(BOM::Platform::Runtime->instance->get_offerings_config)
    ->values_for_key('underlying_symbol');

subtest 'it runs' => sub {
    my $pop = BOM::Pricing::QueuePopulator::Japan->new;
    lives_ok { $pop->process } 'does not die';
};

done_testing();
