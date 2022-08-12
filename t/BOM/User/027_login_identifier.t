use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Fatal qw(exception lives_ok);

use BOM::User;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $email = 'social_resp@binary.com';
my $user  = BOM::User->create(
    email    => $email,
    password => "hello",
);
my $device_id  = '';
my $user_agent = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_11_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/54.0.2840.98 Safari/537.36';

subtest 'check login identifer with device information' => sub {

    $device_id = 'android1212';
    my $env_string = qr/IP=456.34.12.1 IP_COUNTRY=TR User_AGENT=$user_agent LANG=EN DEVICE_ID=$device_id/;
    my $actual     = BOM::User::Utility::login_details_identifier($env_string);
    my $expected   = 'TR::Mac OS X::Chrome::456.34::android1212';

    is $actual, $expected, 'Returns correct identifier with device information';
};

subtest 'check login identifer without device information' => sub {

    $device_id = '';
    my $env_string = qr/IP=124.12.10.1 IP_COUNTRY=TR User_AGENT=$user_agent LANG=EN DEVICE_ID=$device_id/;
    my $actual     = BOM::User::Utility::login_details_identifier($env_string);
    my $expected   = 'TR::Mac OS X::Chrome::124.12';

    is $actual, $expected, 'Returns correct identifier without device information';

    my $is_logged_before_same_loc = $user->logged_in_before_from_same_location($env_string);
    is $is_logged_before_same_loc, 1, 'Logged in from the same location, as no login history';
};

subtest 'check login from no device information in last login' => sub {

    $device_id = 'android1212';
    my $env_string = qr/IP=1.1.1.1 IP_COUNTRY=TR User_AGENT=$user_agent LANG=EN DEVICE_ID=$device_id/;

    my $mock_history = Test::MockModule->new('BOM::User');
    $mock_history->mock(
        'get_last_successful_login_history' => sub {
            return {"environment" => qr/IP=1.1.1.1 IP_COUNTRY=TR User_AGENT=$user_agent LANG=EN/};
        });

    my $is_logged_before_same_loc = $user->logged_in_before_from_same_location($env_string);
    is $is_logged_before_same_loc, 1, 'Logged in from the different location';
};

subtest 'check login from different location' => sub {

    $device_id = 'android1212';
    my $env_string = qr/IP=1.1.1.1 IP_COUNTRY=TR User_AGENT=$user_agent LANG=EN DEVICE_ID=$device_id/;

    my $mock_history = Test::MockModule->new('BOM::User');
    $mock_history->mock(
        'get_last_successful_login_history' => sub {
            return {"environment" => qr/IP=1.1.1.1 IP_COUNTRY=TR User_AGENT=$user_agent LANG=EN DEVICE_ID=12312/};
        });

    my $is_logged_before_same_loc = $user->logged_in_before_from_same_location($env_string);
    is $is_logged_before_same_loc, undef, 'Logged in from the different location';
};

subtest 'check login when previous env do not have ip address' => sub {

    $device_id = 'android1212';
    my $env_string = qr/IP=1.1.1.1 IP_COUNTRY=TR User_AGENT=$user_agent LANG=EN DEVICE_ID=$device_id/;

    my $mock_history = Test::MockModule->new('BOM::User');
    $mock_history->mock(
        'get_last_successful_login_history' => sub {
            return {"environment" => qr/IP_COUNTRY=TR User_AGENT=$user_agent LANG=EN DEVICE_ID=12312/};
        });

    my $is_logged_before_same_loc = $user->logged_in_before_from_same_location($env_string);
    is $is_logged_before_same_loc, undef, 'Logged from ip location';
};

subtest 'check login from same location' => sub {

    $device_id = 'android1212';
    my $env_string = qr/IP=1.1.1.1 IP_COUNTRY=TR User_AGENT=$user_agent LANG=EN DEVICE_ID=$device_id/;

    my $mock_history = Test::MockModule->new('BOM::User');
    $mock_history->mock(
        'get_last_successful_login_history' => sub {
            return {"environment" => $env_string};
        });

    my $is_logged_before_same_loc = $user->logged_in_before_from_same_location($env_string);
    is $is_logged_before_same_loc, 1, 'Logged in from the same location';
};

done_testing();
