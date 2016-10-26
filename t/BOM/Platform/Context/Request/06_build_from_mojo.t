use Test::More (tests => 3);
use Test::Exception;
use Test::MockObject;
use Test::MockModule;
use Mojo::URL;

use BOM::Platform::Context::Request;

subtest 'base build' => sub {
    my $request = BOM::Platform::Context::Request::from_mojo();
    ok !$request, "Unable to build with out mojo_request";

    $request = BOM::Platform::Context::Request::from_mojo({mojo_request => mock_request_for("https://www.binary.com")});
    ok $request, "Able to build request";
};

subtest 'headers vs builds' => sub {
    subtest 'domain_name' => sub {
        my $request = BOM::Platform::Context::Request::from_mojo({mojo_request => mock_request_for("https://www.binary.com")});
        is $request->domain_name, "www.binary.com";

        my $request = BOM::Platform::Context::Request::from_mojo({mojo_request => mock_request_for("https://www.binary.com:5984")});
        is $request->domain_name, "www.binary.com";

        my $request = BOM::Platform::Context::Request::from_mojo({mojo_request => mock_request_for("https://www.binaryqa02.com")});
        is $request->domain_name, "www.binaryqa02.com";
    };
};

subtest 'accepted http_methods' => sub {
    subtest 'GET|POST|HEAD' => sub {
        foreach my $method (qw/GET POST HEAD/) {
            my $request = BOM::Platform::Context::Request::from_mojo({mojo_request => mock_request_for("https://www.binary.com/", undef, $method)});
            is $request->http_method, $method, "Method $method ok";
        }
    };

    subtest 'PUT' => sub {
        throws_ok {
            BOM::Platform::Context::Request::from_mojo({mojo_request => mock_request_for("https://www.binary.com/", undef, 'PUT')});
        }
        qr/PUT is not an accepted request method/;
    };

    subtest 'GETR' => sub {
        throws_ok {
            BOM::Platform::Context::Request::from_mojo({mojo_request => mock_request_for("https://www.binary.com/", undef, 'GETR')});
        }
        qr/GETR is not an accepted request method/;
    };
};

sub mock_request_for {
    my $for_url = shift;
    my $param   = shift || {};
    my $method  = shift || 'GET';

    my $url_mock = Mojo::URL->new($for_url);
    $url_mock->query->param(%$param) if keys %$param;

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
    $request_mock->mock('cookie', sub { return; });
    $request_mock->mock('env',    sub { {} });

    return $request_mock;
}
