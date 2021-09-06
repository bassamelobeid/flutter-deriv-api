use strict;
use warnings;

use Test::Most;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Helper::Client qw(create_client);
use BOM::User;
use BOM::RPC::v3::Utility;

# Setup a test user
my $test_client = create_client('CR');
$test_client->email('test@binary.com');
$test_client->save;

my $password = 's3kr1t';
my $hash_pwd = BOM::User::Password::hashpw($password);
my $user     = BOM::User->create(
    email    => 'test@binary.com',
    password => $hash_pwd,
);
$user->add_client($test_client);

subtest 'validate_password_with_attempts' => sub {
    my $tries = 1;

    while ($tries <= 5) {
        is BOM::RPC::v3::Utility::validate_password_with_attempts('Abcd1234', $test_client->user->password, $test_client->loginid), 'PasswordError',
            "return PasswordError on failed attempt - $tries";
        ++$tries;
    }

    is BOM::RPC::v3::Utility::validate_password_with_attempts('Abcd1234', $test_client->user->password, $test_client->loginid), 'PasswordReset',
        'return PasswordReset when max password attempt is reached - wrong password';

    is BOM::RPC::v3::Utility::validate_password_with_attempts($password, $test_client->user->password, $test_client->loginid), 'PasswordReset',
        'return PasswordReset when max password attempt is reached - correct password';
};

done_testing();
