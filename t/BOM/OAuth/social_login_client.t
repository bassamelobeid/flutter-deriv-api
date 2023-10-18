use strict;
use warnings;
use Test::More;
use Test::Exception;
use Test::MockModule;
use JSON::MaybeUTF8 qw(:v1);
use BOM::OAuth::SocialLoginClient;
use BOM::OAuth::SocialLoginController;

my $mock_http = Test::MockModule->new('HTTP::Tiny');
my $use_oneall_mobile;
my $mock_oauth = Test::MockModule->new('BOM::OAuth::O');
$mock_oauth->mock('_use_oneall_mobile' => sub { return $use_oneall_mobile; });
my $response;
my $code = 200;
my @params;
$mock_http->mock(
    request => sub {
        (@params) = @_;
        return {
            status  => $code,
            content => ref $response ? encode_json_utf8($response) : $response
        };
    });

#mock SocialLoginClient
my $mock_slc = Test::MockModule->new('BOM::OAuth::SocialLoginController');

subtest 'Social login client providers' => sub {

    my $sls = BOM::OAuth::SocialLoginClient->new(
        port => 'dymmy',
        host => 'dummy'
    );

    $response = {data => [{name => 'google'}]};
    my $providers = $sls->get_providers('qa.dev');
    like $params[2], qr/qa.dev/, 'request contains base redirect url';
    is_deeply $providers, [{name => 'google'}], 'providers list returned';

    $providers = $sls->get_providers('qa.dev', 123);
    is_deeply $providers, [{name => 'google'}], 'providers list returned';
    is $params[2], 'http://dummy:dymmy/social-login/providers/123?base_redirect_url=qa.dev', 'url is correct for app_id';

    $response  = {message => 'error'};
    $code      = 500;
    $providers = $sls->get_providers('qa.dev');
    is $providers, 'error', 'return the error if error';

    $response = 'wrong formated response';
    dies_ok { $sls->get_providers('qa.dev') } "Die if malformed response";

};

subtest 'Social login client exchange' => sub {

    my $sls = BOM::OAuth::SocialLoginClient->new(
        port => 'dummy',
        host => 'dummy'
    );

    $code     = 200;
    $response = {
        data => {
            provider => "facebook",
            cookie   => {
                facebook => {
                    code_challenge => "dummy",
                    code_verifier  => "dummy",
                    nonce          => "dummy",
                    state          => "dummy"
                }
            },
            callback_params => {
                code  => "dummy",
                state => "dummy"
            },
        }};

    my $exchange_params;
    my $provider_response = $sls->retrieve_user_info('qa.dev', $exchange_params);
    is_deeply $provider_response, $response->{data}, 'correct response';
    like $params[2], qr/qa.dev/, 'request contains base redirect url';

    my $test_app_id = 123;
    $exchange_params   = {app_id => $test_app_id};
    $provider_response = $sls->retrieve_user_info('qa.dev', $exchange_params);
    is_deeply $provider_response, $response->{data}, 'correct response';
    is $params[2], "http://dummy:dummy/social-login/exchange/$test_app_id?base_redirect_url=qa.dev",
        'url is correct for app_id and base_redirect_url';

    $code              = 400;
    $response          = {error => "error"};
    $provider_response = $sls->retrieve_user_info('qa.dev', $exchange_params);
    is_deeply $provider_response, $response, 'return the error objecr in case of 400';
};

subtest 'Social Login Provider Bridge Endpoint Test' => sub {
    my $provider_response;
    $use_oneall_mobile = 0;
    $response          = $mock_slc->mock(
        get_providers => sub {
            return [{name => "google"}];
        });
    my $c = {_use_oneall_mobile => $use_oneall_mobile};
    $provider_response = BOM::OAuth::SocialLoginController::get_providers($c);
    ok(ref $provider_response eq 'ARRAY' && scalar @$provider_response > 0, 'Non-empty array returned for use_oneall_mobile = 0');
    is_deeply $provider_response, [{name => 'google'}], 'providers list returned';

    $use_oneall_mobile = 1;
    $response          = $mock_slc->mock(
        get_providers => sub {
            return [];
        });
    $c->{_use_oneall_mobile} = $use_oneall_mobile;
    $provider_response = BOM::OAuth::SocialLoginController::get_providers($c);
    ok(ref $provider_response eq 'ARRAY' && scalar @$provider_response == 0, 'Empty array returned for use_oneall_mobile = 1');
    is_deeply $provider_response, [], 'providers list returned an empty array';
};

done_testing();

1;

