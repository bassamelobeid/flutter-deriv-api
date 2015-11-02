use Test::More (tests => 9);
use Test::Exception;
use Test::NoWarnings;
use Test::MockObject;
use Test::MockModule;
use JSON qw(decode_json);

use Mojo::URL;
use Mojo::Cookie::Request;
use URL::Encode;
use Data::Dumper;

use BOM::Platform::Context::Request;

subtest 'base build' => sub {
    my $request = BOM::Platform::Context::Request::from_mojo();
    ok !$request, "Unable to build with out mojo_request";

    $request = BOM::Platform::Context::Request::from_mojo({mojo_request => mock_request_for("https://www.binary.com")});
    ok $request, "Able to build request";
};

subtest 'from_ui' => sub {
    my $request = BOM::Platform::Context::Request::from_mojo({mojo_request => mock_request_for("https://www.binary.com")});
    ok $request, "Able to build request";

    ok $request->from_ui, 'The Request is from UI';
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

my $email = 'abc@binary.com';
subtest 'param builds' => sub {
    subtest 'session_cookie' => sub {
        my $lc = BOM::Platform::SessionCookie->new(
            loginid => 'CR1001',
            email   => $email,
        );

        my $request =
            BOM::Platform::Context::Request::from_mojo({mojo_request => mock_request_for("https://www.binary.com/", {login => $lc->token})});

        is $request->session_cookie->loginid, 'CR1001', "Valid Client";

        $request = BOM::Platform::Context::Request::from_mojo({mojo_request => mock_request_for("https://www.binary.com/")});
        ok((not defined $request->session_cookie), "not a valid cookie");

    };

    subtest 'loginid' => sub {
        my $cookie_name = BOM::Platform::Runtime->instance->app_config->cgi->cookie_name->login;
        my $lc          = BOM::Platform::SessionCookie->new(
            loginid => 'CR1001',
            email   => $email,
        );

        my $request =
            BOM::Platform::Context::Request::from_mojo({mojo_request => mock_request_for("https://www.binary.com/", {login => $lc->token})});
        is $request->loginid, 'CR1001', "Valid Client and loginid";
    };

    subtest 'broker_code' => sub {
        subtest 'loginid inputs' => sub {
            my $cookie_name = BOM::Platform::Runtime->instance->app_config->cgi->cookie_name->login;
            my $lc          = BOM::Platform::SessionCookie->new(
                loginid => 'MX1001',
                email   => $email,
            );

            my $request =
                BOM::Platform::Context::Request::from_mojo({mojo_request => mock_request_for("https://www.binary.com/", {}, {login => $lc->token})});
            is $request->broker_code, 'MX', "Valid broker" or diag(Dumper($request));

            $request =
                BOM::Platform::Context::Request::from_mojo({mojo_request => mock_request_for("https://www.binary.com/", {login => $lc->token}, {})});
            is $request->broker_code, 'MX', "Valid broker";
        };

        subtest 'broker inputs' => sub {
            my $request = BOM::Platform::Context::Request::from_mojo({mojo_request => mock_request_for("https://www.binary.com/", {broker => 'MX'})});
            is $request->broker_code, 'MX', "Valid broker from broker param";

            $request = BOM::Platform::Context::Request::from_mojo({mojo_request => mock_request_for("https://www.binary.com/", {broker => 'MESA'})});
            throws_ok { $request->broker_code } qr/Unknown broker code or loginid \[MESA\]/, "not a valid broker";

            $request = BOM::Platform::Context::Request::from_mojo({mojo_request => mock_request_for("https://www.binary.com/", {w => 'MX'})});
            is $request->broker_code, 'CR', "Not read from w param";
        };
    };

    subtest 'is_pjax' => sub {
        my $request = BOM::Platform::Context::Request::from_mojo({mojo_request => mock_request_for("https://www.binary.com/")});
        ok !$request->is_pjax, "Is not a pjax page";

        $request = BOM::Platform::Context::Request::from_mojo({mojo_request => mock_request_for("https://www.binary.com/?_pjax")});
        ok $request->is_pjax, "Is a pjax page";
    };
};

subtest 'cookie builds' => sub {

    subtest 'session_cookie' => sub {
        my $cookie_name = BOM::Platform::Runtime->instance->app_config->cgi->cookie_name->login;
        my $lc          = BOM::Platform::SessionCookie->new(
            loginid => 'CR1001',
            email   => $email,
        );

        my $request =
            BOM::Platform::Context::Request::from_mojo({mojo_request => mock_request_for("https://www.binary.com/", {}, {login => $lc->token})});
        is $request->session_cookie->loginid, 'CR1001', "Valid Client";

        $request =
            BOM::Platform::Context::Request::from_mojo({mojo_request => mock_request_for("https://www.binary.com/", {}, {$cookie_name => ''})});
        ok !$request->session_cookie, "not a valid cookie";

    };

    subtest 'loginid' => sub {
        my $cookie_name = BOM::Platform::Runtime->instance->app_config->cgi->cookie_name->login;
        my $lc          = BOM::Platform::SessionCookie->new(
            loginid => 'CR1001',
            email   => $email,
        );

        my $request =
            BOM::Platform::Context::Request::from_mojo({mojo_request => mock_request_for("https://www.binary.com/", {}, {login => $lc->token})});
        is $request->loginid, 'CR1001', "Valid Client and loginid";
    };

    subtest 'broker_code' => sub {
        my $cookie_name = BOM::Platform::Runtime->instance->app_config->cgi->cookie_name->login;
        my $lc          = BOM::Platform::SessionCookie->new(
            loginid => 'CR1001',
            email   => $email,
        );

        my $request =
            BOM::Platform::Context::Request::from_mojo(
            {mojo_request => mock_request_for("https://www.binary.com/", {}, {$cookie_name => $lc->token})});
        is $request->broker_code, 'CR', "Valid login id and broker";
    };
};

subtest 'cookie preferred' => sub {
    subtest 'session_cookie' => sub {
        my $cookie_name = BOM::Platform::Runtime->instance->app_config->cgi->cookie_name->login;
        my $lc          = BOM::Platform::SessionCookie->new(
            loginid => 'CR1001',
            email   => $email,
        );

        my $lc2 = BOM::Platform::SessionCookie->new(
            loginid => 'CR1002',
            email   => $email,
        );

        my $request = BOM::Platform::Context::Request::from_mojo(
            {mojo_request => mock_request_for("https://www.binary.com/", {login => $lc2->token}, {$cookie_name => $lc->token})});
        is $request->session_cookie->loginid, 'CR1001', "Valid Client";
    };
};

subtest 'ids failed' => sub {
    throws_ok {
        BOM::Platform::Context::Request::from_mojo({mojo_request => mock_request_for("https://www.binary.com/", {test => '/etc/passwd%00'})});
    }
    qr/Detected IDS attacks/;
};

subtest 'accepted http_methods' => sub {
    subtest 'GET|POST|HEAD' => sub {
        foreach my $method (qw/GET POST HEAD/) {
            my $request =
                BOM::Platform::Context::Request::from_mojo(
                {mojo_request => mock_request_for("https://www.binary.com/", undef, undef, undef, $method)});
            is $request->http_method, $method, "Method $method ok";
        }
    };

    subtest 'PUT' => sub {
        throws_ok {
            BOM::Platform::Context::Request::from_mojo({mojo_request => mock_request_for("https://www.binary.com/", undef, undef, undef, 'PUT')});
        }
        qr/PUT is not an accepted request method/;
    };

    subtest 'GETR' => sub {
        throws_ok {
            BOM::Platform::Context::Request::from_mojo({mojo_request => mock_request_for("https://www.binary.com/", undef, undef, undef, 'GETR')});
        }
        qr/GETR is not an accepted request method/;
    };
};

sub mock_request_for {
    my $for_url = shift;
    my $param   = shift || {};
    my $cookies = shift || {};
    my $headers = shift || {};
    my $method  = shift || 'GET';

    my $url_mock = Mojo::URL->new($for_url);
    $url_mock->query->param(%$param);
    my $header_mock = Test::MockObject->new();
    $header_mock->mock('header', sub { shift; return $headers->{shift}; });

    my $params_mock = Test::MockObject->new();
    $params_mock->mock('to_hash', sub { return $url_mock->query->to_hash; });
    $params_mock->mock('param', sub { shift; return $url_mock->query->param(@_); });

    my $request_mock = Test::MockObject->new();
    $request_mock->set_always('url',     $url_mock);
    $request_mock->set_always('headers', $header_mock);
    $request_mock->set_always('params',  $params_mock);
    $request_mock->set_always('method',  $method);
    $request_mock->mock('param', sub { shift; return $params_mock->param(@_); });

    my $request_cookies = {};
    foreach my $name (keys %$cookies) {
        my $cookie = Mojo::Cookie::Request->new();
        $cookie->name($name);
        $cookie->value($cookies->{$name});
        $request_cookies->{$name} = $cookie;
    }

    $request_mock->mock('cookie', sub { shift; my $name = shift; return $request_cookies->{$name}; });

    $request_mock->mock('env', sub { {} });

    return $request_mock;
}
