use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::MockObject;
use Test::MockModule;
use Test::FailWarnings;
use Mojo::URL;

use BOM::Platform::Context::Request;

subtest 'base build' => sub {
    my $request = BOM::Platform::Context::Request::from_mojo();
    ok !$request, "Unable to build without mojo_request";

    $request = BOM::Platform::Context::Request::from_mojo({mojo_request => mock_request_for("https://www.binary.com")});
    ok $request, "Able to build request";
    done_testing;
};

subtest 'headers vs builds' => sub {
    subtest 'domain_name' => sub {
        {
            my $request = BOM::Platform::Context::Request::from_mojo({mojo_request => mock_request_for("https://www.binary.com")});
            is $request->domain_name, "www.binary.com";
        }

        {
            my $request = BOM::Platform::Context::Request::from_mojo({mojo_request => mock_request_for("https://www.binary.com:5984")});
            is $request->domain_name, "www.binary.com";
        }

        {
            my $request = BOM::Platform::Context::Request::from_mojo({mojo_request => mock_request_for("https://www.binaryqa02.com")});
            is $request->domain_name, "www.binaryqa02.com";
        }
        done_testing;
    };
    done_testing;
};

subtest 'accepted http_methods' => sub {
    subtest 'GET|POST|HEAD' => sub {
        foreach my $method (qw/GET POST HEAD/) {
            my $request = BOM::Platform::Context::Request::from_mojo({mojo_request => mock_request_for("https://www.binary.com/", undef, $method)});
            is $request->http_method, $method, "Method $method ok";
        }
        done_testing;
    };

    subtest 'PUT' => sub {
        throws_ok {
            BOM::Platform::Context::Request::from_mojo({mojo_request => mock_request_for("https://www.binary.com/", undef, 'PUT')});
        }
        qr/PUT is not an accepted request method/;
        done_testing;
    };

    subtest 'GETR' => sub {
        throws_ok {
            BOM::Platform::Context::Request::from_mojo({mojo_request => mock_request_for("https://www.binary.com/", undef, 'GETR')});
        }
        qr/GETR is not an accepted request method/;
        done_testing;
    };
    done_testing;
};

subtest 'client IP address' => sub {
    ok(my $code = BOM::Platform::Context::Request::Builders->can('_remote_ip'), 'have our _remote_ip sub');

    my %headers;
    my $obj = Test::MockObject->new;
    my $hdr = Test::MockObject->new;
    $hdr->mock(
        header => sub {
            my ($self, $hdr) = @_;
            $headers{$hdr};
        });
    $obj->mock(url    => sub { Mojo::URL->new('https://www.binary.com/') });
    $obj->mock(method => sub { 'GET' });
    $obj->set_always(env     => \%headers);
    $obj->set_always(headers => $hdr);

    for my $ip (qw(4.2.2.1 9.2.3.4 8.8.8.8 199.199.199.199)) {
        {
            local $headers{'cf-connecting-ip'} = $ip;
            is($code->($obj), $ip, "set $ip via CF-Connecting-IP");
        }
        {
            local $headers{'x-forwarded-for'} = "$ip,1.2.3.4";
            is($code->($obj), $ip, "set $ip via X-Forwarded-For");
        }
        {
            local $headers{'x-forwarded-for'} = "1.2.3.4,$ip";
            is($code->($obj), '1.2.3.4', "have first result when $ip is last in X-Forwarded-For");
        }
        {
            local $headers{'x-forwarded-for'} = "$ip";
            is($code->($obj), '', "no result when $ip is the only entry in X-Forwarded-For");
        }
        {
            local $headers{'REMOTE_ADDR'} = $ip;
            is($code->($obj), $ip, "set $ip via REMOTE_ADDR");
        }
        {
            local $headers{'cf-connecting-ip'} = $ip;
            # Must be two addresses that aren't in the tests
            my @addr = qw(1.2.3.4 5.6.7.8);
            fail('update @addr list and pick something other than ' . $_) for grep { $_ eq $ip } @addr;
            local $headers{'x-forwarded-for'} = join ',', @addr;
            is($code->($obj), $ip, "set $ip via CF-Connecting-IP, it overrides X-Forwarded-For");
        }
    }

    ok($code = BOM::Platform::Context::Request::Builders->can('from_mojo'), 'have our _remote_ip sub');

    for my $country (qw(my ru)) {
        {
            local $headers{'CF-IPCOUNTRY'} = $country;
            is($code->({mojo_request => $obj})->country_code, $country, "set country via CF-IPCOUNTRY");
        }
        {
            local $headers{'CloudFront-Viewer-Country'} = $country;
            is($code->({mojo_request => $obj})->country_code, $country, "set country via CloudFront-Viewer-Country");
        }

        {
            local $headers{'CloudFront-Viewer-Country'} = 'xx';
            is($code->({mojo_request => $obj})->country_code, 'aq', "set country via CloudFront-Viewer-Country");
        }
        {
            local $headers{'CF-IPCOUNTRY'} = 'xx';
            is($code->({mojo_request => $obj})->country_code, 'aq', "set country via CloudFront-Viewer-Country");
        }
    }

    done_testing;
};

subtest 'json payload' => sub {
    my $payload = {
        app_id    => 1,
        challenge => 'mydogmouthsmellslikefish',
        expire    => 1900901010,
        from_json => 9000,
    };

    my $params = {
        from_json => 1,
    };

    my $request =
        BOM::Platform::Context::Request::from_mojo({mojo_request => mock_request_for("https://www.binary.com/", $params, 'POST', $payload)});

    for my $key (keys $payload->%*) {
        # Note params should have priority over json payload
        is $request->param($key), $params->{$key} // $payload->{$key}, "Expected value for $key";
    }
};

done_testing;

sub mock_request_for {
    my $for_url = shift;
    my $param   = shift || {};
    my $method  = shift || 'GET';
    my $json    = shift || {};

    my $url_mock = Mojo::URL->new($for_url);
    $url_mock->query(%$param) if keys %$param;

    my $header_mock = Test::MockObject->new();
    $header_mock->mock('header', sub { return; });

    my $params_mock = Test::MockObject->new();
    $params_mock->mock('to_hash', sub { return $url_mock->query->to_hash; });
    $params_mock->mock('param',   sub { shift; return $url_mock->query->param(@_); });

    my $request_mock = Test::MockObject->new();
    $request_mock->set_always('url',     $url_mock);
    $request_mock->set_always('headers', $header_mock);
    $request_mock->set_always('params',  $params_mock);
    $request_mock->set_always('method',  $method);
    $request_mock->mock('param', sub { shift; return $params_mock->param(@_); });
    $request_mock->mock('env',   sub { {} });
    $request_mock->mock('json',  sub { $json });

    return $request_mock;
}
