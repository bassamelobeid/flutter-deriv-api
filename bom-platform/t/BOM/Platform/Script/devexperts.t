use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::Deep;
use IO::Async::Loop;
use BOM::Platform::Script::DevExpertsAPIService::Dxsca;
use Net::Async::HTTP;
use IO::Async::Loop;
use JSON::MaybeUTF8   qw(:v1);
use Log::Any::Adapter qw(TAP);

my $loop = IO::Async::Loop->new;
$loop->add(
    my $service = BOM::Platform::Script::DevExpertsAPIService::Dxsca->new(
        demo_host => 'http://localhost',
        real_host => 'http://localhost',
    ));
$loop->add(my $http = Net::Async::HTTP->new);

my $port = $service->start->get;
# it will have chosen a random port because none was specified
my $url = 'http://localhost:' . $port;

subtest 'datadog' => sub {

    my $mock_client  = Test::MockModule->new('WebService::Async::DevExperts::Dxsca::Client');
    my $mock_service = Test::MockModule->new('BOM::Platform::Script::DevExpertsAPIService');
    my $mock_request = Test::MockModule->new('Net::Async::HTTP::Server::Request');

    my $timing;
    $mock_client->redefine(login => sub { Future->done('dummy') });
    $mock_service->redefine(stats_timing => sub { $timing = $_[1]; ok $timing, 'got stats_timing'; });
    $mock_request->redefine(
        respond => sub {
            is $_[1]->header('timing'), $timing, 'timing header set in response';
            $mock_request->original('respond')->(@_);
        });

    $http->POST($url, '{ "server": "demo", "method": "login" }', content_type => 'application/json')->get;

    $mock_service->unmock('stats_timing');
    $mock_request->unmock('respond');

    $mock_client->redefine(login => sub { die });
    my @stats;
    $mock_service->redefine(stats_inc => sub { push @stats, \@_ });
    $http->POST($url, '{ "server": "demo", "method": "login" }', content_type => 'application/json')->get;

    cmp_deeply(
        \@stats,
        [
            ['devexperts.dxsca_api_service.request',          {'tags' => bag('server:demo', 'method:login')}],
            ['devexperts.dxsca_api_service.unexpected_error', {'tags' => bag('server:demo', 'method:login')}]
        ],
        'expected stats_inc'
    );

};

done_testing;
