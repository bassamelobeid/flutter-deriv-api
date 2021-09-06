use strict;
use warnings;
use utf8;
use Test::More;
use Test::Deep;
use Test::Mojo;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use Email::Address::UseXS;
use BOM::Test::Email qw(:no_event);
use BOM::Platform::Token::API;
use BOM::Test::Helper::Token;
use Test::BOM::RPC::QueueClient;
use Test::BOM::RPC::Accounts;

BOM::Test::Helper::Token::cleanup_redis_tokens();

# init db
my $email       = 'abc@binary.com';
my $password    = 'Abcd33!@';
my $hash_pwd    = BOM::User::Password::hashpw($password);
my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});

$test_client->email($email);
$test_client->save;

my $user = BOM::User->create(
    email    => $email,
    password => $hash_pwd
);
$user->add_client($test_client);

my $test_client_disabled = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});

$test_client_disabled->status->set('disabled', 1, 'test disabled');

my $m              = BOM::Platform::Token::API->new;
my $token          = $m->create_token($test_client->loginid,          'test token');
my $token_disabled = $m->create_token($test_client_disabled->loginid, 'test token');

my $c = Test::BOM::RPC::QueueClient->new();

my $method = 'change_password';
subtest 'change password' => sub {
    my $oldpass = '1*VPB0k.BCrtHeWoH8*fdLuwvoqyqmjtDF2FfrUNO7A0MdyzKkelKhrc7MQjNQ=';
    is(
        BOM::RPC::v3::Utility::check_password({
                old_password => 'old_password',
                new_password => 'new_password',
                user_pass    => '1*VPB0k.BCrtHeWoH8*fdLuwvoqyqmjtDF2FfrUNO7A0MdyzKkelKhrc7MQjPQ='
            }
        )->{error}->{message_to_client},
        'Provided password is incorrect.',
        'Provided password is incorrect.',
    );
    is(
        BOM::RPC::v3::Utility::check_password({
                old_password => 'old_password',
                new_password => 'old_password',
                user_pass    => $oldpass
            }
        )->{error}->{message_to_client},
        'Current password and new password cannot be the same.',
        'Current password and new password cannot be the same.',
    );
    is(
        BOM::RPC::v3::Utility::check_password({
                old_password => 'old_password',
                new_password => 'water',
                user_pass    => $oldpass
            }
        )->{error}->{message_to_client},
        'Your password must be 8 to 25 characters long. It must include lowercase and uppercase letters, and numbers.',
        'Your password must be 8 to 25 characters long. It must include lowercase and uppercase letters, and numbers.',
    );
    is(
        BOM::RPC::v3::Utility::check_password({
                old_password => 'old_password',
                new_password => 'New#_p$ssword',
                user_pass    => $oldpass
            }
        )->{error}->{message_to_client},
        'Your password must be 8 to 25 characters long. It must include lowercase and uppercase letters, and numbers.',
        'no number.',
    );
    is(
        BOM::RPC::v3::Utility::check_password({
                old_password => 'old_password',
                new_password => 'pa$5A',
                user_pass    => $oldpass
            }
        )->{error}->{message_to_client},
        'Your password must be 8 to 25 characters long. It must include lowercase and uppercase letters, and numbers.',
        'too short.',
    );
    is(
        BOM::RPC::v3::Utility::check_password({
                old_password => 'old_password',
                new_password => 'pass$5ss',
                user_pass    => $oldpass
            }
        )->{error}->{message_to_client},
        'Your password must be 8 to 25 characters long. It must include lowercase and uppercase letters, and numbers.',
        'no upper case.',
    );
    is(
        BOM::RPC::v3::Utility::check_password({
                old_password => 'old_password',
                new_password => 'PASS$5SS',
                user_pass    => $oldpass
            }
        )->{error}->{message_to_client},
        'Your password must be 8 to 25 characters long. It must include lowercase and uppercase letters, and numbers.',
        'no lower case.',
    );
    is(
        BOM::RPC::v3::Utility::check_password({
                email        => 'abc1@binary.com',
                old_password => 'old_password',
                new_password => 'ABC1@binary.com',
                user_pass    => $oldpass
            }
        )->{error}->{message_to_client},
        'You cannot use your email address as your password.',
        'password must not be the same as email',
    );
    is($c->tcall($method, {token => '12345'})->{error}{message_to_client}, 'The token is invalid.', 'invalid token error');
    is(
        $c->tcall(
            $method,
            {
                token => undef,
            }
        )->{error}{message_to_client},
        'The token is invalid.',
        'invlaid token error'
    );
    isnt(
        $c->tcall(
            $method,
            {
                token => $token,
            }
        )->{error}{message_to_client},
        'The token is invalid.',
        'no token error if token is valid'
    );
    is(
        $c->tcall(
            $method,
            {
                token => $token_disabled,
            }
        )->{error}{message_to_client},
        'This account is unavailable.',
        'check authorization'
    );

    is($c->tcall($method, {})->{error}{message_to_client}, 'The token is invalid.', 'invalid token error');
    is(
        $c->tcall(
            $method,
            {
                token => $token_disabled,
            }
        )->{error}{message_to_client},
        'This account is unavailable.',
        'need a valid client'
    );
    my $params = {
        token => $token,
    };
    is($c->tcall($method, $params)->{error}{message_to_client}, 'Permission denied.', 'need token_type');
    $params->{token_type} = 'hello';
    is($c->tcall($method, $params)->{error}{message_to_client}, 'Permission denied.', 'need token_type');
    $params->{token_type}         = 'oauth_token';
    $params->{args}{old_password} = 'old_password';
    $params->{cs_email}           = 'cs@binary.com';
    $params->{client_ip}          = '127.0.0.1';
    is($c->tcall($method, $params)->{error}{message_to_client}, 'Provided password is incorrect.');
    $params->{args}{old_password} = $password;
    $params->{args}{new_password} = $password;
    is($c->tcall($method, $params)->{error}{message_to_client}, 'Current password and new password cannot be the same.');
    $params->{args}{new_password} = '111111111';
    is($c->tcall($method, $params)->{error}{message_to_client},
        'Your password must be 8 to 25 characters long. It must include lowercase and uppercase letters, and numbers.');
    my $new_password = 'Fsfjxljfwkls3@fs9';
    $params->{args}{new_password} = $new_password;
    mailbox_clear();
    my $result = $c->tcall($method, $params);
    is($result->{status}, 1, 'update password correctly');
    my $subject = 'Your new Deriv account password';
    my $msg     = mailbox_search(
        email   => $email,
        subject => qr/\Q$subject\E/
    );
    ok($msg, "email received");
    $user = BOM::User->new(id => $user->{id});
    isnt($user->{password}, $hash_pwd, 'user password updated');
    $test_client->load;
    isnt($user->{password}, $hash_pwd, 'client password updated');
    $password = $new_password;
};

done_testing();
