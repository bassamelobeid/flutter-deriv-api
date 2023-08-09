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
$mock_http->mock(
    request => sub {
        my (@params) = @_;
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
    my $providers = $sls->get_providers;
    is_deeply $providers, [{name => 'google'}], 'providers list returned';

    $response  = {message => 'error'};
    $code      = 500;
    $providers = $sls->get_providers;
    is $providers, 'sls error: error', 'return the error if error';

    $response = 'wrong formated response';
    dies_ok { $sls->get_providers } "Die if malformed response";

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
    my $provider_response = $sls->retrieve_user_info;
    is_deeply $provider_response, $response->{data}, 'correct response';

    $code              = 400;
    $response          = {error => "error"};
    $provider_response = $sls->retrieve_user_info;
    is_deeply $provider_response, $response, 'return the error objecr in case of 400';
};

done_testing();

1;
