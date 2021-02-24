use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::Deep;
use IO::Async::Loop;
use BOM::Platform::Script::DevExpertsAPIService;
use IO::Async::Loop;
use JSON::MaybeUTF8 qw(:v1);
use Log::Any::Adapter qw(TAP);

my $loop = IO::Async::Loop->new;
$loop->add(my $service = BOM::Platform::Script::DevExpertsAPIService->new);
$loop->add(my $http    = Net::Async::HTTP->new);

isa_ok($service, 'BOM::Platform::Script::DevExpertsAPIService');

my $port = $service->start->get;
# it will have chosen a random port because none was specified
my $url = 'http://localhost:' . $port;
my $resp;

subtest 'bad requests' => sub {

    for my $method ('GET', 'PUT', 'DELETE') {
        $resp = $http->$method($url)->get;
        is $resp->content, 'Only POST is allowed', $method . ' not allowed - message';
        ok $resp->is_error, $method . ' not allowed - error';
    }

    $resp = $http->POST($url, 'boo', content_type => 'application/json')->get;
    like $resp->content, qr/malformed JSON string/, 'bad json - message';
    ok $resp->is_error, 'bad json - error';

    $resp = $http->POST($url, '{ "x": 1 }', content_type => 'application/json')->get;
    is $resp->content, 'Method not provided', 'Method missing - message';
    ok $resp->is_error, 'Method missing - error';

};

subtest 'API response types' => sub {

    my $mock_api = Test::MockModule->new('WebService::Async::DevExperts::Client');
    $mock_api->mock('http_send', sub { Future->done(decode_json_utf8($_[3])) });
    my $login = 'mylogin';
    $resp = $http->POST($url, '{ "method": "client_create", "login": "' . $login . '" }', content_type => 'application/json')->get;
    is decode_json_utf8($resp->content)->{login}, $login, 'client_create (scalar result)';

    $mock_api->mock('http_get', sub { Future->done([{login => $login}]) });
    $resp = $http->POST($url, '{ "method": "client_list" }', content_type => 'application/json')->get;
    is decode_json_utf8($resp->content)->[0]{login}, $login, 'client_list (array result)';

    $resp = $http->POST($url, '{ "method": "client_password_change" }', content_type => 'application/json')->get;
    is $resp->content, '', 'client_password_change (empty result)';

};

done_testing;
