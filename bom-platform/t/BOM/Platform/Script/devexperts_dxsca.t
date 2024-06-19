use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::Deep;
use Test::MockTime qw(set_fixed_time);
use IO::Async::Loop;
use BOM::Platform::Script::DevExpertsAPIService::Dxsca;
use WebService::Async::DevExperts::DxWeb::Model::Error;
use IO::Async::Loop;
use JSON::MaybeUTF8   qw(:v1);
use Log::Any::Adapter qw(TAP);

set_fixed_time(0);

my $loop = IO::Async::Loop->new;
$loop->add(
    my $service = BOM::Platform::Script::DevExpertsAPIService::Dxsca->new(
        demo_host => 'http://localhost',
        real_host => 'http://localhost',
    ));

# for making requests
$loop->add(my $http = Net::Async::HTTP->new);

isa_ok($service, 'BOM::Platform::Script::DevExpertsAPIService::Dxsca');

my $port = $service->start->get;
# it will have chosen a random port because none was specified
my $url = 'http://localhost:' . $port;

my $mock_api = Test::MockModule->new('WebService::Async::DevExperts::Dxsca::Client');
$mock_api->redefine('request', sub { Future->done({timeout => '00:30:00', sessionToken => 'x'}); });
my $logined = 0;
$mock_api->redefine('login', sub { $logined = 1; $mock_api->original('login')->(@_); });

my $resp = $http->POST($url, '{ "server": "demo", "method": "login" }', content_type => 'application/json')->get;
cmp_deeply decode_json_utf8($resp->content),
    {
    timeout       => '00:30:00',
    session_token => 'x'
    },
    'login';

is $service->{clients}{demo}->session_expiry, 1800, 'session expiry set';

$logined = 0;
$http->POST($url, '{ "server": "demo", "method": "order_history", "accounts": [ "x" ] }', content_type => 'application/json')->get;
is $logined, 0, 'login not called again';

set_fixed_time(1700);
$http->POST($url, '{ "server": "demo", "method": "order_history", "accounts": [ "x" ] }', content_type => 'application/json')->get;
is $logined, 0, 'login not called a bit later';

set_fixed_time(1750);
$http->POST($url, '{ "server": "demo", "method": "order_history", "accounts": [ "x" ] }', content_type => 'application/json')->get;
is $logined, 1, 'session renewed within 1 min of token expiry';

done_testing;
