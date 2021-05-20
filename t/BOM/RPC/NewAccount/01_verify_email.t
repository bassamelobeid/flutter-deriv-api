use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Test::Fatal qw(lives_ok);

use MojoX::JSON::RPC::Client;
use BOM::User::Password;
use BOM::Test::Data::Utility::UnitTestDatabase;
use BOM::Test::Email qw(:no_event);
use BOM::RPC::v3::Utility;
use BOM::Platform::Token::API;
use BOM::Database::Model::AccessToken;
use BOM::User;
use BOM::Test::Helper::Token qw(cleanup_redis_tokens);
use BOM::Test::RPC::QueueClient;

use utf8;

$ENV{EMAIL_SENDER_TRANSPORT} = 'Test';
my ($user, $client, $email);
my $rpc_ct;
my $method = 'verify_email';

my @params = (
    $method,
    {
        language => 'EN',
        country  => 'ru',
        source   => 1,
    });

{
    # cleanup
    cleanup_redis_tokens();
    BOM::Database::Model::AccessToken->new->dbic->dbh->do('DELETE FROM auth.access_token');
}

my $expected_result = {
    stash => {
        app_markup_percentage      => 0,
        valid_source               => 1,
        source_bypass_verification => 0
    },
    status => 1
};

subtest 'Initialization' => sub {
    lives_ok {
        my $password = 'jskjd8292922';
        my $hash_pwd = BOM::User::Password::hashpw($password);

        $email = 'exists_email' . rand(999) . '@binary.com';

        $user = BOM::User->create(
            email    => $email,
            password => $hash_pwd
        );

        $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });

        $client->account('USD');
        $user->add_client($client);
    }
    'Initial user and client';

    lives_ok {
        $rpc_ct = BOM::Test::RPC::QueueClient->new();
    }
    'Initial RPC server and client connection';
};

subtest 'Account opening request with an invalid email address' => sub {
    mailbox_clear();
    $params[1]->{args}->{verify_email} = 'test' . rand(999) . '.@binary.com';
    $params[1]->{args}->{type}         = 'account_opening';
    $params[1]->{server_name}          = 'deriv.com';
    $params[1]->{link}                 = 'deriv.com/some_url';

    $rpc_ct->call_ok(@params)->has_no_system_error->has_error->error_code_is('InvalidEmail', 'If email address is invalid it should return error')
        ->error_message_is('This email address is invalid.', 'If email address is invalid it should return error_message');
};

subtest 'Account opening request with email does not exist' => sub {
    mailbox_clear();
    $params[1]->{args}->{verify_email} = 'test' . rand(999) . '@binary.com';
    $params[1]->{args}->{type}         = 'account_opening';
    $params[1]->{server_name}          = 'binary.com';
    $params[1]->{link}                 = 'binary.com/some_url';

    $rpc_ct->call_ok(@params)
        ->has_no_system_error->has_no_error->result_is_deeply($expected_result, "It always should return 1, so not to leak client's email");

    my $msg = mailbox_search(
        email   => $params[1]->{args}->{verify_email},
        subject => qr/Verify your email address|Verify your account for Deriv/
    );
    ok $msg, 'Email sent successfully';
};

subtest 'Account opening request with email exists' => sub {
    mailbox_clear();
    $params[1]->{args}->{verify_email} = uc $email;
    $params[1]->{args}->{type}         = 'account_opening';
    $params[1]->{server_name}          = 'deriv.com';
    $params[1]->{link}                 = 'deriv.com/some_url';

    $rpc_ct->call_ok(@params)
        ->has_no_system_error->has_no_error->result_is_deeply($expected_result, "It always should return 1, so not to leak client's email");

    my $msg = mailbox_search(
        email   => lc($params[1]->{args}->{verify_email}),
        subject => qr/Duplicate email address submitted|Unsuccessful Deriv account creation/
    );
    ok $msg, 'Email sent successfully';
};

subtest 'Reset password for exists user' => sub {
    mailbox_clear();
    $params[1]->{args}->{verify_email} = uc $email;
    $params[1]->{args}->{type}         = 'reset_password';
    $params[1]->{server_name}          = 'deriv.com';
    $params[1]->{link}                 = 'deriv.com/some_url';

    $rpc_ct->call_ok(@params)
        ->has_no_system_error->has_no_error->result_is_deeply($expected_result, "It always should return 1, so not to leak client's email");

    my $msg = mailbox_search(
        email   => lc($params[1]->{args}->{verify_email}),
        subject => qr/Get a new .* account password/
    );
    ok $msg, 'Email sent successfully';
};

subtest 'Reset password for not exists user' => sub {
    $params[1]->{args}->{verify_email} = 'not_' . $email;
    $params[1]->{args}->{type}         = 'reset_password';
    $params[1]->{server_name}          = 'deriv.com';
    $params[1]->{link}                 = 'deriv.com/some_url';

    $rpc_ct->call_ok(@params)
        ->has_no_system_error->has_no_error->result_is_deeply($expected_result, "It always should return 1, so not to leak client's email");
};

subtest 'Payment agent withdraw' => sub {
    mailbox_clear();

    $params[1]->{args}->{verify_email} = $client->email;
    $params[1]->{args}->{type}         = 'paymentagent_withdraw';
    $params[1]->{server_name}          = 'binary.com';
    $params[1]->{link}                 = 'binary.com/some_url';

    my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');
    $params[1]->{token} = $token;

    $rpc_ct->call_ok(@params)
        ->has_no_system_error->has_no_error->result_is_deeply($expected_result, "It always should return 1, so not to leak client's email");

    my $msg = mailbox_search(
        email   => $params[1]->{args}->{verify_email},
        subject => qr/Verify your withdrawal request/
    );
    ok $msg, 'Email sent successfully';
    mailbox_clear();

    $params[1]->{args}->{verify_email} = 'dummy@email.com';
    $rpc_ct->call_ok(@params)
        ->has_no_system_error->has_no_error->result_is_deeply($expected_result, "It always should return 1, so not to leak client's email");

    $msg = mailbox_search(
        email   => $params[1]->{args}->{verify_email},
        subject => qr/Verify your withdrawal request/
    );
    ok !$msg, 'no email as token email different from passed email';
};

subtest 'Payment withdraw' => sub {
    mailbox_clear();
    $params[1]->{args}->{verify_email} = $client->email;
    $params[1]->{args}->{type}         = 'payment_withdraw';
    $params[1]->{server_name}          = 'binary.com';
    $params[1]->{link}                 = 'binary.com/some_url';

    my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token 1');
    $params[1]->{token} = $token;

    $rpc_ct->call_ok(@params)
        ->has_no_system_error->has_no_error->result_is_deeply($expected_result, "It always should return 1, so not to leak client's email");

    my $msg = mailbox_search(
        email   => $params[1]->{args}->{verify_email},
        subject => qr/Verify your withdrawal request/
    );
    ok $msg, 'Email sent successfully';
    mailbox_clear();

    $params[1]->{args}->{verify_email} = 'dummy@email.com';
    $rpc_ct->call_ok(@params)
        ->has_no_system_error->has_no_error->result_is_deeply($expected_result, "It always should return 1, so not to leak client's email");

    $msg = mailbox_search(
        email   => $params[1]->{args}->{verify_email},
        subject => qr/Verify your withdrawal request/
    );
    ok !$msg, 'no email as token email different from passed email';
    delete $params[1]->{token};
};

subtest 'Closed account' => sub {

    $client->status->set('disabled', 1, 'test disabled');

    mailbox_clear();
    $params[1]->{args}->{verify_email} = $email;
    $params[1]->{args}->{type}         = 'account_opening';
    $params[1]->{server_name}          = 'binary.com';
    $params[1]->{link}                 = 'binary.com/some_url';

    $rpc_ct->call_ok(@params)->has_no_system_error->has_no_error('no error for disabled account')
        ->result_is_deeply($expected_result, "It always should return 1, so not to leak client's email");

    my $msg = mailbox_search(
        email   => $params[1]->{args}->{verify_email},
        subject => qr/We're unable to sign you up/
    );
    ok $msg, 'Correct email received for signup attempt on closed account';

    my $client2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $user->add_client($client2);

    $rpc_ct->call_ok(@params)->has_no_system_error->has_no_error('no error after adding a non-disabled account')
        ->result_is_deeply($expected_result, "It always should return 1, so not to leak client's email");

    $msg = mailbox_search(
        email   => $params[1]->{args}->{verify_email},
        subject => qr/Duplicate email address submitted|Unsuccessful Deriv account creation/
    );
    ok $msg, 'Get the regular email when not all accounts are disabled';

    $client2->status->set('disabled', 1, 'test disabled');
    mailbox_clear();
    $params[1]->{args}->{type} = 'reset_password';

    $rpc_ct->call_ok(@params)->has_no_system_error->has_no_error('no error for disabled account')
        ->result_is_deeply($expected_result, "It always should return 1, so not to leak client's email");

    $msg = mailbox_search(
        email   => $params[1]->{args}->{verify_email},
        subject => qr/We couldn't reset your password/
    );
    ok $msg, 'Correct email received for reset password attempt on closed account';

    mailbox_clear();
    $params[1]->{args}->{type} = 'payment_withdraw';

    $rpc_ct->call_ok(@params)->has_no_system_error->has_no_error('no error for disabled account')
        ->result_is_deeply($expected_result, "It always should return 1, so not to leak client's email");

    $msg = mailbox_search(
        email   => $params[1]->{args}->{verify_email},
        subject => qr/We couldn't verify your email address/
    );
    ok $msg, 'Correct email received for payment withdraw attempt on closed account';
};

subtest 'withdrawal validation' => sub {

    $params[1]->{args}->{verify_email} = $client->email;
    $params[1]->{server_name}          = 'binary.com';
    $params[1]->{link}                 = 'binary.com/some_url';

    my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token 2');
    $params[1]->{token} = $token;

    my $mock_utility = Test::MockModule->new('BOM::RPC::v3::Utility');
    $mock_utility->mock(cashier_validation => sub { 'dummy' });

    for my $type (qw(payment_withdraw paymentagent_withdraw)) {
        $params[1]->{args}->{type} = $type;
        is $rpc_ct->call_ok(@params)->has_no_system_error->result, 'dummy', $type . ' has withdrawal validation';
    }

    for my $type (qw(account_opening reset_password)) {
        $params[1]->{args}->{type} = $type;
        $rpc_ct->call_ok(@params)
            ->has_no_system_error->has_no_error->result_is_deeply($expected_result, $type . ' does not have withdrawal validation');
    }
};

done_testing();
