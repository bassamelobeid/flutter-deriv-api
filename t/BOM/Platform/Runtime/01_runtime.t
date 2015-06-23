#!/usr/bin/perl -I ../../../../lib

use strict;
use warnings;

use Test::More (tests => 7);
use Test::Exception;
use Test::NoWarnings;

use BOM::System::Host;
use BOM::Platform::Runtime;
use BOM::Platform::Context::Request;

new_ok('BOM::Platform::Runtime');
ok(BOM::Platform::Runtime->instance,                    "instance");
ok(BOM::Platform::Runtime->instance->host_roles,        "host_roles");
ok(BOM::Platform::Runtime->instance->hosts,             "hosts");
ok(BOM::Platform::Runtime->instance->landing_companies, "landing_companies");
ok(BOM::Platform::Runtime->instance->app_config,        "app_config");
