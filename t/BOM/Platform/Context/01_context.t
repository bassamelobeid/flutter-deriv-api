#!/etc/rmg/bin/perl -I ../../../lib

use strict;
use warnings;

use Test::More (tests => 1);
use Test::Exception;
use Test::MockModule;
use JSON qw(decode_json);

use BOM::Platform::Runtime;
use BOM::Platform::Context;

subtest 'request' => sub {
    ok(BOM::Platform::Context::request(), 'default');
    is(BOM::Platform::Context::request()->country_code, 'aq', 'default request');

    my $request = BOM::Platform::Context::Request->new(country_code => 'nl');

    ok(BOM::Platform::Context::request($request), 'new request');
    is(BOM::Platform::Context::request()->country_code, 'nl', 'new request');
    BOM::Platform::Context::request_completed();

    is(BOM::Platform::Context::request()->country_code, 'aq', 'back to default request');
};

