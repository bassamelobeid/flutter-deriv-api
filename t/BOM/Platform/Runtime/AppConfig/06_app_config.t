#!/usr/bin/env perl

use strict;
use warnings;

use Test::Most 0.22 (tests => 1);
use Test::NoWarnings;
use Test::MockTime 'set_relative_time';
use Test::MockObject;

use BOM::Platform::Runtime;
use BOM::Platform::Runtime::AppConfig;

my $app_config;
lives_ok {
    $app_config = BOM::Platform::Runtime::AppConfig->new();
}
'Able to create';
