#!/usr/bin/env perl

use strict;
use warnings;

use Test::Most 0.22 (tests => 3);
use Test::NoWarnings;
use Test::MockTime 'set_relative_time';
use Test::MockObject;

use BOM::Platform::Runtime;
use BOM::Platform::Runtime::AppConfig;

dies_ok {
    BOM::Platform::Runtime::AppConfig->new();
}
'Attribute website_list is required for app_config';

subtest 'simple creation - without initialization' => sub {

    my $app_config;
    lives_ok {
        $app_config = BOM::Platform::Runtime::AppConfig->new(couch => BOM::Platform::Runtime->instance->datasources->couchdb);
    }
    'Able to create';

};

