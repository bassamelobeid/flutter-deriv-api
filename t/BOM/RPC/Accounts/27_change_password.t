use strict;
use warnings;
use utf8;
use Test::More;
use Test::Deep;
use Test::Mojo;
use Test::MockModule;
use Test::BOM::RPC::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use Email::Address::UseXS;
use BOM::Test::Email qw(:no_event);
use BOM::Platform::Token::API;
use BOM::Test::Helper::Token;

BOM::Test::Helper::Token::cleanup_redis_tokens();

# init db
my $email       = 'abc@binary.com';
my $password    = 'jskjd8292922';
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
my $token         = $m->create_token($test_client->loginid, 'test token');
my $token_disabled = $m->create_token($test_client_disabled->loginid, 'test token');

my $t = Test::Mojo->new('BOM::RPC::Transport::HTTP');
my $c = Test::BOM::RPC::Client->new(ua => $t->app->ua);

my $method = 'change_password';
subtest 'change password' => sub {
    my $oldpass = '1*VPB0k.BCrtHeWoH8*fdLuwvoqyqmjtDF2FfrUNO7A0MdyzKkelKhrc7MQjNQ=';
    is(
        BOM::RPC::v3::Utility::_check_password({
                old_password => 'old_password',
                new_password => 'new_password',
                user_pass    => '1*VPB0k.BCrtHeWoH8*fdLuwvoqyqmjtDF2FfrUNO7A0MdyzKkelKhrc7MQjPQ='
            }
            )->{error}->{message_to_client},
        'Provided password is incorrect.',
        'Provided password is incorrect.',
    );
    is(
        BOM::RPC::v3::Utility::_check_password({
                old_password => 'old_password',
                new_password => 'old_password',
                user_pass    => $oldpass
            }
            )->{error}->{message_to_client},
        'Current password and new password cannot be the same.',
        'Current password and new password cannot be the same.',
    );
    is(
        BOM::RPC::v3::Utility::_check_password({
                old_password => 'old_password',
                new_password => 'water',
                user_pass    => $oldpass
            }
            )->{error}->{message_to_client},
        'Password should be at least six characters, including lower and uppercase letters with numbers.',
        'Password should be at least six characters, including lower and uppercase letters with numbers.',
    );
    is(
        BOM::RPC::v3::Utility::_check_password({
                old_password => 'old_password',
                new_password => 'New#_p$ssword',
                user_pass    => $oldpass
            }
            )->{error}->{message_to_client},
        'Password should be at least six characters, including lower and uppercase letters with numbers.',
        'no number.',
    );
    is(
        BOM::RPC::v3::Utility::_check_password({
                old_password => 'old_password',
                new_password => 'pa$5A',
                user_pass    => $oldpass
            }
            )->{error}->{message_to_client},
        'Password should be at least six characters, including lower and uppercase letters with numbers.',
        'too short.',
    );
    is(
        BOM::RPC::v3::Utility::_check_password({
                old_password => 'old_password',
                new_password => 'pass$5ss',
                user_pass    => $oldpass
            }
            )->{error}->{message_to_client},
        'Password should be at least six characters, including lower and uppercase letters with numbers.',
        'no upper case.',
    );
    is(
        BOM::RPC::v3::Utility::_check_password({
                old_password => 'old_password',
                new_password => 'PASS$5SS',
                user_pass    => $oldpass
            }
            )->{error}->{message_to_client},
        'Password should be at least six characters, including lower and uppercase letters with numbers.',
        'no lower case.',
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
        'Password should be at least six characters, including lower and uppercase letters with numbers.');
    my $new_password = 'Fsfjxljfwkls3@fs9';
    $params->{args}{new_password} = $new_password;
    mailbox_clear();
    is($c->tcall($method, $params)->{status}, 1, 'update password correctly');
    my $subject = 'Your password has been changed.';
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
