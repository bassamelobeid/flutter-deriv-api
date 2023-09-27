use strict;
use warnings;
use Test::More;
use Test::Exception;
use Test::MockModule;
use JSON::MaybeUTF8 qw(:v1);
use BOM::OAuth::SocialLoginClient;

my $mock_http = Test::MockModule->new('HTTP::Tiny');
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

subtest 'Social login client providers' => sub {

    my $sls = BOM::OAuth::SocialLoginClient->new(
        port => 'dymmy',
        host => 'dummy'
    );

    $response = {data => [{name => 'google'}]};
    my $providers = $sls->get_providers('qa.dev');
    like $params[2], qr/qa.dev/, 'request contains base redirect url';
    is_deeply $providers, [{name => 'google'}], 'providers list returned';

    $response  = {message => 'error'};
    $code      = 500;
    $providers = $sls->get_providers('qa.dev');
    is $providers, 'error', 'return the error if error';

    $response = 'wrong formated response';
    dies_ok { $sls->get_providers('qa.dev') } "Die if malformed response";

};

subtest 'Social login client exchange' => sub {

    my $sls = BOM::OAuth::SocialLoginClient->new(
        port => 'dymmy',
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
    my $provider_response = $sls->retrieve_user_info('qa.dev');
    like $params[2], qr/qa.dev/, 'request contains base redirect url';
    is_deeply $provider_response, $response->{data}, 'correct response';

    $code              = 400;
    $response          = {error => "error"};
    $provider_response = $sls->retrieve_user_info('qa.dev');
    is_deeply $provider_response, $response, 'return the error object in case of 400';
};

done_testing();

1;
