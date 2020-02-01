use strict;
use warnings;
use Test::More;
#use Test::Warnings;
use Test::MockObject;
use Test::MockModule;
use Mojo::URL;

BEGIN { use_ok('BOM::Platform::Context::Request'); }

my $simple_request = BOM::Platform::Context::Request->new;

my $mocked_hostname = Test::MockModule->new('Sys::Hostname');
my $hostname        = 'mockname';
$mocked_hostname->mock('hostname', sub { $hostname });

subtest 'params' => sub {
    is_deeply($simple_request->params, {}, 'default params is empty');
    my $params = {
        foo      => "bar",
        an_array => ["item1", "item2"]};
    my $mojo_request = BOM::Platform::Context::Request::from_mojo({mojo_request => mock_request_for("https://www.dummy.com", $params, 'GET')});
    is_deeply($mojo_request->params, $params, 'param of request from mojo is same with mojo request');
    is($mojo_request->param('foo'), 'bar', "param method is ok");
};

subtest 'domain_name' => sub {
    is(BOM::Platform::Context::Request->new->domain_name, 'www.binary.com', 'default hostname is www.binary.com');
    $hostname = 'qa123.com';
    is(BOM::Platform::Context::Request->new->domain_name, 'www.binaryqa123.com', 'qa hostname will be qa self');

};

subtest 'brand' => sub {
    $hostname = 'hello';
    my $request = BOM::Platform::Context::Request->new;
    is($request->brand_name,  'binary', 'brand name (no param brand but have a random domain name) is binary');
    is($request->brand->name, 'binary', 'brand name (no param brand but have a random domain name) is binary');
    $hostname = 'www.binaryqa123.com';
    $request  = BOM::Platform::Context::Request->new;
    is($request->brand_name,  'binary', 'brand name (no param brand but have a qa domain name) is binary');
    is($request->brand->name, 'binary', 'brand name (no param brand but have a qa domain name) is binary');
    $hostname = 'www.binary.com';
    $request  = BOM::Platform::Context::Request->new;
    is($request->brand_name,  'binary', 'brand name (no param brand but have binary domain name) is binary');
    is($request->brand->name, 'binary', 'brand name (no param brand but have binary domain name) is binary');
    my $mojo_request =
        BOM::Platform::Context::Request::from_mojo({mojo_request => mock_request_for("https://www.dummy.com", {brand => 'deriv'}, 'GET')});
    is($mojo_request->brand_name,  'deriv', 'brand name (with param brand) is param brand');
    is($mojo_request->brand->name, 'deriv', 'brand name (with param brand) is param brand');
};

subtest 'http method' => sub {
    is($simple_request->http_method, '', 'http method default is empty');
    my $mojo_request =
        BOM::Platform::Context::Request::from_mojo({mojo_request => mock_request_for("https://www.dummy.com", {brand => 'deriv'}, 'GET')});
    is($mojo_request->http_method, 'GET', 'http method is same with mojo request');
};

subtest 'language' => sub {
    is($simple_request->language, 'EN', 'default language is EN');
    is(BOM::Platform::Context::Request::from_mojo({mojo_request => mock_request_for("https://www.dummy.com", {l => 'ru'}, 'GET')})->language,
        'RU', 'language will be param "l"');
    is(BOM::Platform::Context::Request::from_mojo({mojo_request => mock_request_for("https://www.dummy.com", {l => 'xx'}, 'GET')})->language,
        'EN', 'language will be EN if param "l" is not a valid language');
    is(
        BOM::Platform::Context::Request::from_mojo({mojo_request => mock_request_for("https://www.dummy.com", {l => ['ru', 'en']}, 'GET')})->language,
        'RU',
        'language will be the first value if param "l" is an array'
    );
};

subtest 'client_ip' => sub {
    is($simple_request->client_ip, '127.0.0.1', 'default client ip is 127.0.0.1');
    is(BOM::Platform::Context::Request::from_mojo({mojo_request => mock_request_for("https://www.dummy.com", {}, 'GET')})->client_ip, '1.1.1.1', 'ip can be fetched from mojo request');
};

done_testing;

sub mock_request_for {
    my $for_url = shift;
    my $param   = shift || {};
    my $method  = shift || 'GET';

    my $url_mock = Mojo::URL->new($for_url);
    $url_mock->query(%$param) if keys %$param;

    my $header_mock = Test::MockObject->new();
    $header_mock->mock('header', sub { return; });

    my $params_mock = Test::MockObject->new();
    $params_mock->mock('to_hash', sub { return $url_mock->query->to_hash; });
    $params_mock->mock('param', sub { shift; return $url_mock->query->param(@_); });

    my $request_mock = Test::MockObject->new();
    $request_mock->set_always('url',     $url_mock);
    $request_mock->set_always('headers', $header_mock);
    $request_mock->set_always('params',  $params_mock);
    $request_mock->set_always('method',  $method);
    $request_mock->mock('param', sub { shift; return $params_mock->param(@_); });
    $request_mock->mock('env', sub { {REMOTE_ADDR => '1.1.1.1'} });

    return $request_mock;
}
