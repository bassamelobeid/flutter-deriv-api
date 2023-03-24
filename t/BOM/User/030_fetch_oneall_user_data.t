use strict;
use warnings;

use Test::More;
use Test::MockModule;
use BOM::User::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

subtest "oneall__data" => sub {

    my $rose          = Test::MockModule->new('DBIx::Connector');
    my $mock_response = [];
    $rose->mock('run', $mock_response);
    my $result       = BOM::User->oneall_data;
    my $expected_res = [];
    is_deeply $result, $expected_res, 'No oneall data is available for the user';

    $mock_response = [{provider => "google", provider_data => "{\"user\" : { \"user_token\" : \"token\"}}"}];
    $rose->mock('run', $mock_response);
    $result       = BOM::User->oneall_data;
    $expected_res = [{binary_user_id => undef, provider => "google", user_token => "token"}];
    is_deeply $result, $expected_res, 'Successfully extracted the oneall data';

    $mock_response = [{
            provider      => "google",
            provider_data => "{\"user\" : { \"user_token\" : \"token\"}}"
        },
        {
            provider      => "facebook",
            provider_data => "{\"user\" : { \"user_token\" : \"token_1\"}}"
        }];
    $rose->mock('run', $mock_response);
    $result       = BOM::User->oneall_data;
    $expected_res = [{
            binary_user_id => undef,
            provider       => "google",
            user_token     => "token"
        },
        {
            binary_user_id => undef,
            provider       => "facebook",
            user_token     => "token_1"
        }];
    is_deeply $result, $expected_res, 'Successfully extracted the multiple oneall data entries';

    # Test on malformed data
    $mock_response = [{
            provider      => "google",
            provider_data => "{\"user\" => { \"some_field\" : \"token\"}}"
        }];
    $rose->mock('run', $mock_response);
    $result       = BOM::User->oneall_data;
    $expected_res = [];
    is_deeply $result, $expected_res, 'Returned an empty object for malformed data';
};

done_testing();
