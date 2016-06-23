#!/usr/bin/perl -I ../../../lib

use strict;
use warnings;

use Test::More (tests => 4);
use Test::Exception;
use Test::NoWarnings;
use Test::MockModule;
use JSON qw(decode_json);

use BOM::Test::Runtime qw(:normal);
use BOM::Platform::Runtime;
use BOM::Platform::Context;

subtest 'request' => sub {
    ok(BOM::Platform::Context::request(), 'default');
    is(BOM::Platform::Context::request()->broker->code, 'CR', 'default request');

    my $request = BOM::Platform::Context::Request->new(country_code => 'nl');
    is(BOM::Platform::Context::request()->broker->code, 'CR', 'default request');

    ok(BOM::Platform::Context::request($request), 'new request');
    is(BOM::Platform::Context::request()->broker->code, 'MLT', 'now its MLT request');
    BOM::Platform::Context::request_completed();

    is(BOM::Platform::Context::request()->broker->code, 'CR', 'back to default request');
};

subtest 'app_config' => sub {
    ok(BOM::Platform::Context::app_config(), 'default');

    my $request = BOM::Platform::Context::Request->new(
        domain_name => 'www.binary.com',
        backoffice  => 1
    );
    ok(BOM::Platform::Context::request($request), 'new request');
    is(scalar @{BOM::Platform::Context::app_config()->cgi->allowed_languages}, 4, 'new settings');

    BOM::Platform::Context::request_completed();
};

