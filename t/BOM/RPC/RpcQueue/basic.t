#!/usr/bin/env perl
use strict;
use warnings;

use Test::More;
use JSON::MaybeUTF8 qw(decode_json_utf8);
use Mojo::IOLoop;
use Job::Async::Client::Redis;

use BOM::Test::Helper qw(build_wsapi_test call_instrospection);
use BOM::Test::RPC::Client;
use BOM::Test::Script::RpcQueue;

my $c      = BOM::Test::RPC::Client->new(redis => 1);
my $c_http = BOM::Test::RPC::Client->new(ua    => Test::Mojo->new('BOM::RPC::Transport::HTTP')->app->ua);

subtest 'Method call over rpc queue' => sub {
    my $request = {
        'reset_password'    => 1,
        'verification_code' => 'dummy_dummy',
        'new_password'      => 'dummy_dummy',
    };
    my $result1 = $c->call_ok('reset_password', {args => $request})->has_no_system_error->result;
    my $result2 = $c_http->call_ok('reset_password', {args => $request})->has_no_system_error->result;

    is_deeply $result1, $result2, 'The same result from queue and http rpc for reset password';

    $result1 = $c->call_ok('residence_list')->has_no_system_error->result;
    $result2 = $c_http->call_ok('residence_list')->has_no_system_error->result;

    is_deeply $result1, $result2, 'The same result from queue and http rpc for residence_list';

};

subtest 'Worker service restart' => sub {
    ok 'TO BE IMPPLEMENTED';
};

done_testing();
