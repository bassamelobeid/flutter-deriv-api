#!/usr/bin/perl -I ../../../../lib

use strict;
use warnings;

use Test::More (tests => 10);
use Test::Deep;
use Test::Exception;
use Test::NoWarnings;
use Test::MockObject;
use Test::MockModule;
use JSON qw(decode_json);

use Carp;

{
    no strict 'refs';
    *{"Carp::Croak"} = sub { };
}

use BOM::Platform::Context::Request;
use BOM::Platform::SessionCookie;

subtest 'base build' => sub {
    my $request = BOM::Platform::Context::Request::from_cgi({
        cookies => {},
        cgi     => mock_cgi_for(),
    });
    ok $request, "Able to build request";

    $request = BOM::Platform::Context::Request::from_cgi({
        http_cookie => '',
        cgi         => mock_cgi_for(),
    });
    ok $request, "Able to build request";
};

subtest 'from_ui' => sub {
    my $request = BOM::Platform::Context::Request::from_cgi({
        http_cookie => '',
        cgi         => mock_cgi_for(),
    });
    ok $request, "Able to build request";

    ok $request->from_ui, 'The Request is from UI';
};

subtest 'env vars' => sub {
    subtest 'client_ip' => sub {
        local %ENV;
        local $ENV{'REMOTE_ADDR'} = '192.12.12.1';

        my $request = BOM::Platform::Context::Request::from_cgi({
            cookies => {},
            cgi     => mock_cgi_for(),
        });
        is $request->client_ip, '192.12.12.1';
    };

    subtest 'domain_name' => sub {
        local %ENV;
        local $ENV{'HTTP_HOST'} = 'www.binary.com';

        my $request = BOM::Platform::Context::Request::from_cgi({
            cookies => {},
            cgi     => mock_cgi_for(),
        });
        is $request->domain_name, 'www.binary.com';

        local $ENV{'HTTP_HOST'} = 'www.binary.com:5984';
        $request = BOM::Platform::Context::Request::from_cgi({
            cookies => {},
            cgi     => mock_cgi_for(),
        });
        is $request->domain_name, 'www.binary.com';
    };
};

subtest 'request_method' => sub {
    subtest 'GET|POST|HEAD' => sub {
        foreach my $method (qw/GET POST HEAD/) {
            my $request = BOM::Platform::Context::Request::from_cgi({
                cgi => mock_cgi_for(undef, undef, $method),
            });
            is $request->http_method, $method, "Method $method ok";
        }
    };

    subtest 'PUT' => sub {
        throws_ok {
            BOM::Platform::Context::Request::from_cgi({
                cgi => mock_cgi_for(undef, undef, 'PUT'),
            });
        }
        qr/PUT is not an accepted request method/;
    };

    subtest 'GETR' => sub {
        throws_ok {
            BOM::Platform::Context::Request::from_cgi({
                cgi => mock_cgi_for(undef, undef, 'GETR'),
            });
        }
        qr/GETR is not an accepted request method/;
    };
};

subtest 'param' => sub {
    subtest 'POST - url_params' => sub {
        my $request = BOM::Platform::Context::Request::from_cgi({
            cgi => mock_cgi_for({a => 'test'}, {b => 'test'}, 'POST'),
        });
        is $request->param('a'), 'test', 'Got param from request vars';
        is $request->param('b'), 'test', 'Got param from url_param';
        ok !$request->param('c'), 'No c param';

    };

    subtest 'array' => sub {
        my $request = BOM::Platform::Context::Request::from_cgi({
            cgi => mock_cgi_for({a => ['val1', 'val2']}, {b => ['val1', 'val2']}, 'POST'),
        });
        isa_ok $request->param('a'), 'ARRAY';
        isa_ok $request->param('b'), 'ARRAY';
    };
};

my $email = 'abc@binary.com';
subtest 'param builds' => sub {
    subtest 'session_cookie' => sub {
        my $lc = BOM::Platform::SessionCookie->new(
            loginid => 'CR1001',
            email   => $email,
        );

        my $request = BOM::Platform::Context::Request::from_cgi({
            cookies => {},
            cgi     => mock_cgi_for({login => $lc->token}),
        });
        is $request->session_cookie->loginid, 'CR1001', "Valid Client";
        is $request->session_cookie->email, $email, "Valid email";

        $request = BOM::Platform::Context::Request::from_cgi({
            cookies => {},
            cgi     => mock_cgi_for({login => ''}),
        });
        ok !$request->session_cookie, "not a valid cookie";

    };

    subtest 'loginid and email' => sub {
        my $cookie_name = BOM::Platform::Runtime->instance->app_config->cgi->cookie_name->login;
        my $lc          = BOM::Platform::SessionCookie->new(
            loginid => 'CR1001',
            email   => $email,
        );

        my $request = BOM::Platform::Context::Request::from_cgi({
            cookies => {},
            cgi     => mock_cgi_for({login => $lc->token}),
        });
        is $request->loginid, 'CR1001', "Valid Client and loginid";
        is $request->email, $email, "Valid email";
    };

    subtest 'broker_code' => sub {
        subtest 'frontend' => sub {
            subtest 'loginid inputs' => sub {
                my $cookie_name = BOM::Platform::Runtime->instance->app_config->cgi->cookie_name->login;
                my $lc          = BOM::Platform::SessionCookie->new(
                    loginid => 'MX1001',
                    email   => $email,
                );

                my $request = BOM::Platform::Context::Request::from_cgi({
                    cookies => {},
                    cgi     => mock_cgi_for({login => $lc->token}),
                });
                is $request->broker_code, 'MX', "Valid broker";
            };

            subtest 'broker inputs' => sub {
                my $request = BOM::Platform::Context::Request::from_cgi({
                    cookies => {},
                    cgi     => mock_cgi_for({broker => "MX"}),
                });
                is $request->broker_code, 'MX', "Valid broker from broker param";

                $request = BOM::Platform::Context::Request::from_cgi({
                    cookies => {},
                    cgi     => mock_cgi_for({broker => "MESA"}),
                });
                throws_ok { $request->broker_code } qr/Unknown broker code or loginid \[MESA\]/, "not a valid broker";

                $request = BOM::Platform::Context::Request::from_cgi({
                    cookies => {},
                    cgi     => mock_cgi_for({w => "MX"}),
                });
                is $request->broker_code, 'CR', "Not read from w param";
            };
        };
    };

};

subtest 'cookie_parsing' => sub {
    subtest 'Valid http_cookie' => sub {
        my $request = BOM::Platform::Context::Request::from_cgi({
            http_cookie => "a=b;",
            cgi         => mock_cgi_for(),
        });
        ok $request, "Request was built";
        is $request->cookie('a'), 'b', 'Cookie a was b';
    };

    subtest 'Invalid http_cookie' => sub {
        my $request = BOM::Platform::Context::Request::from_cgi({
            http_cookie => "b;",
            cgi         => mock_cgi_for(),
        });
        ok $request, "Request was built";
        ok !$request->cookie('a'), 'Cookie a not present';
    };
};

subtest 'cookie_builds' => sub {
    subtest 'session_cookie' => sub {
        my $cookie_name = BOM::Platform::Runtime->instance->app_config->cgi->cookie_name->login;
        my $lc          = BOM::Platform::SessionCookie->new(
            loginid => 'CR1001',
            email   => $email,
        );

        my $request = BOM::Platform::Context::Request::from_cgi({
            cookies => {$cookie_name => $lc->token},
            cgi     => mock_cgi_for(),
        });
        is $request->session_cookie->loginid, 'CR1001', "Valid Client";
        is $request->session_cookie->email, $email, "Valid email";

        $request = BOM::Platform::Context::Request::from_cgi({
            cookies => {$cookie_name => ''},
            cgi     => mock_cgi_for(),
        });
        ok !$request->session_cookie, "not a valid cookie";

    };

    subtest 'loginid and email' => sub {
        my $cookie_name = BOM::Platform::Runtime->instance->app_config->cgi->cookie_name->login;
        my $lc          = BOM::Platform::SessionCookie->new(
            loginid => 'CR1001',
            email   => $email,
        );

        my $request = BOM::Platform::Context::Request::from_cgi({
            cookies => {$cookie_name => $lc->token},
            cgi     => mock_cgi_for(),
        });
        is $request->loginid, 'CR1001', "Valid Client and loginid";
        is $request->email, $email, "Valid email";
    };

    subtest 'broker_code' => sub {
        my $cookie_name = BOM::Platform::Runtime->instance->app_config->cgi->cookie_name->login;
        my $lc          = BOM::Platform::SessionCookie->new(
            loginid => 'CR1001',
            email   => $email,
        );

        my $request = BOM::Platform::Context::Request::from_cgi({
            cookies => {$cookie_name => $lc->token},
            cgi     => mock_cgi_for(),
        });
        is $request->broker_code, 'CR', "Valid login id and broker";
    };

    subtest 'bo_cookie' => sub {
        local %ENV;
        my $cookie_name = BOM::Platform::Runtime->instance->app_config->cgi->cookie_name->login_bo;
        my $lc          = BOM::Platform::SessionCookie->new(
            loginid => 'CR1001',
            clerk   => 'arun',
            email   => $email,
        );

        my $request = BOM::Platform::Context::Request::from_cgi({
            cookies => {$cookie_name => $lc->token},
            cgi     => mock_cgi_for(),
        });
        is $request->bo_cookie->loginid, 'CR1001', "Valid Client";
        is $request->bo_cookie->email, $email, "Valid Email";

        $request = BOM::Platform::Context::Request::from_cgi({
            cookies => {$cookie_name => ''},
            cgi     => mock_cgi_for(),
        });
        ok !$request->bo_cookie, "not a valid cookie";
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

        my $request = BOM::Platform::Context::Request::from_cgi({
            cookies => {$cookie_name       => $lc->token},
            cgi     => mock_cgi_for({login => $lc2->token}),
        });
        is $request->session_cookie->loginid, 'CR1001', "Valid Client";
        is $request->session_cookie->email, $email, "Valid Email";
    };

    subtest 'bo_cookie' => sub {
        local %ENV;
        my $cookie_name = BOM::Platform::Runtime->instance->app_config->cgi->cookie_name->login_bo;
        my $lc          = BOM::Platform::SessionCookie->new(
            loginid => 'CR1001',
            clerk   => 'arun',
            email   => $email,
        );

        my $lc2 = BOM::Platform::SessionCookie->new(
            loginid => 'CR1002',
            clerk   => 'arun',
            email   => $email,
        );

        my $request = BOM::Platform::Context::Request::from_cgi({
            cookies => {$cookie_name       => $lc->token},
            cgi     => mock_cgi_for({staff => $lc2->token}),
        });
        is $request->bo_cookie->loginid, 'CR1001', "Valid Client";
        is $request->bo_cookie->email, $email, "Valid Email";
    };
};

sub mock_cgi_for {
    my $params     = shift || {};
    my $url_params = shift || {};
    my $method     = shift || 'GET';

    my $request_mock = Test::MockObject->new();
    $request_mock->set_always('request_method', $method);
    $request_mock->set_always('script_name',    'test.cgi');
    $request_mock->mock(
        'url_param',
        sub {
            my $self = shift;
            my $name = shift;
            if ($name) {
                return $url_params->{$name};
            }

            return keys %{$url_params};
        });
    $request_mock->mock(
        'param',
        sub {
            my $self = shift;
            my $name = shift;
            if ($name) {
                return $params->{$name};
            }

            return keys %{$params};
        });

    return $request_mock;
}

END {
}
