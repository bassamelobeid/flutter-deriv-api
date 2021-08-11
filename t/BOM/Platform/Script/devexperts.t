use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::Deep;
use IO::Async::Loop;
use BOM::Platform::Script::DevExpertsAPIService;
use WebService::Async::DevExperts::DxWeb::Model::Error;
use IO::Async::Loop;
use JSON::MaybeUTF8 qw(:v1);
use Log::Any::Adapter qw(TAP);

my $loop = IO::Async::Loop->new;
$loop->add(
    my $service = BOM::Platform::Script::DevExpertsAPIService->new(
        demo_host => 'http://localhost',
        real_host => 'http://localhost'
    ));
$loop->add(my $http = Net::Async::HTTP->new);

isa_ok($service, 'BOM::Platform::Script::DevExpertsAPIService');

my $port = $service->start->get;
# it will have chosen a random port because none was specified
my $url = 'http://localhost:' . $port;
my $resp;

subtest 'bad requests' => sub {

    for my $method ('GET', 'PUT', 'DELETE') {
        $resp = $http->do_request(
            method => $method,
            uri    => $url
        )->get;
        is $resp->content, 'Only POST is allowed', $method . ' not allowed - message';
        ok $resp->is_error, $method . ' not allowed - error';
    }

    $resp = $http->POST($url, 'boo', content_type => 'application/json')->get;
    like $resp->content, qr/malformed JSON string/, 'bad json - message';
    ok $resp->is_error, 'bad json - error';

    $resp = $http->POST($url, '{ "x": 1 }', content_type => 'application/json')->get;
    is $resp->content, 'Server not provided', 'Server missing - message';
    ok $resp->is_error, 'Method missing - error';

    $resp = $http->POST($url, '{ "server": "demo", "x": 1 }', content_type => 'application/json')->get;
    is $resp->content, 'Method not provided', 'Method missing - message';
    ok $resp->is_error, 'Method missing - error';

};

subtest 'API response types' => sub {

    my $mock_api = Test::MockModule->new('WebService::Async::DevExperts::DxWeb::Client');
    $mock_api->redefine('request', sub { Future->done(decode_json_utf8($_[3])) });
    my $login = 'mylogin';
    $resp = $http->POST($url, '{ "server": "demo", "method": "client_create", "login": "' . $login . '" }', content_type => 'application/json')->get;
    is decode_json_utf8($resp->content)->{login}, $login, 'client_create (scalar result)';

    $mock_api->redefine('request', sub { Future->done([{login => $login}]) });
    $resp = $http->POST($url, '{ "server": "demo", "method": "client_list" }', content_type => 'application/json')->get;
    is decode_json_utf8($resp->content)->[0]{login}, $login, 'client_list (array result)';

    $mock_api->redefine('account_category_set', sub { Future->done() });
    $resp = $http->POST($url, '{ "server": "demo", "method": "account_category_set" }', content_type => 'application/json')->get;
    is $resp->content, '', 'account_category_set (empty result)';

    $mock_api->redefine('logout_user_by_login', sub { Future->done('all sessions for user x closed.') });
    $resp =
        $http->POST($url, '{ "server": "demo", "method": "logout_user_by_login", "domain": "x", "login" : "x" }', content_type => 'application/json')
        ->get;
    is $resp->content, 'all sessions for user x closed.', 'logout_user_by_login (text result)';

    $mock_api->redefine(
        'request',
        sub {
            die WebService::Async::DevExperts::DxWeb::Model::Error->new(
                error_code    => '123',
                error_message => 'it failed',
                http_code     => 469
            );
        });

    $resp = $http->POST($url, '{ "server": "demo", "method": "client_create" }', content_type => 'application/json')->get;
    my $msg = decode_json_utf8($resp->content);
    is $msg->{error_code},    123,         'error code';
    is $msg->{error_message}, 'it failed', 'error message';
    is $resp->code, 469, 'http code';
};

done_testing;
