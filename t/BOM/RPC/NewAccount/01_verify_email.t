use strict;
use warnings;

use Test::Most;
use Test::Mojo;
use Test::MockModule;

use MojoX::JSON::RPC::Client;
use Data::Dumper;
use BOM::System::Password;

use BOM::Test::RPC::Client;
use BOM::Test::Data::Utility::UnitTestDatabase;
use BOM::RPC::v3::Utility;
use BOM::Database::Model::AccessToken;
use BOM::Test::Email qw(get_email_by_address_subject clear_mailbox);
use BOM::Platform::User;

use utf8;

my ($user, $client, $email);
my ($t, $rpc_ct);
my $method = 'verify_email';

my @params = (
    $method,
    {
        language => 'EN',
        country  => 'ru',
    });

{
    # cleanup
    BOM::Database::Model::AccessToken->new->dbh->do('DELETE FROM auth.access_token');
}

subtest 'Initialization' => sub {
    lives_ok {
        my $password = 'jskjd8292922';
        my $hash_pwd = BOM::System::Password::hashpw($password);

        $email = 'exists_email' . rand(999) . '@binary.com';

        $user = BOM::Platform::User->create(
            email    => $email,
            password => $hash_pwd
        );
        $user->save;

        $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });

        $user->add_loginid({loginid => $client->loginid});
        $user->save;
    }
    'Initial user and client';

    lives_ok {
        $t = Test::Mojo->new('BOM::RPC');
        $rpc_ct = BOM::Test::RPC::Client->new(ua => $t->app->ua);
    }
    'Initial RPC server and client connection';
};

subtest 'Account opening request with email does not exist' => sub {
    clear_mailbox();

    $params[1]->{args}->{verify_email} = 'test' . rand(999) . '@binary.com';
    $params[1]->{args}->{type}         = 'account_opening';
    $params[1]->{server_name}          = 'binary.com';
    $params[1]->{link}                 = 'binary.com/some_url';

    $rpc_ct->call_ok(@params)
        ->has_no_system_error->has_no_error->result_is_deeply({status => 1}, "It always should return 1, so not to leak client's email");

    my %msg = get_email_by_address_subject(
        email   => $params[1]->{args}->{verify_email},
        subject => qr/Verify your email address/
    );
    ok keys %msg, 'Email sent successfully';
    clear_mailbox();
};

subtest 'Account opening request with email exists' => sub {
    clear_mailbox();

    $params[1]->{args}->{verify_email} = $email;
    $params[1]->{args}->{type}         = 'account_opening';
    $params[1]->{server_name}          = 'binary.com';
    $params[1]->{link}                 = 'binary.com/some_url';

    $rpc_ct->call_ok(@params)
        ->has_no_system_error->has_no_error->result_is_deeply({status => 1}, "It always should return 1, so not to leak client's email");

    my %msg = get_email_by_address_subject(
        email   => $params[1]->{args}->{verify_email},
        subject => qr/A Duplicate Email Address Has Been Submitted/
    );
    ok keys %msg, 'Email sent successfully';
    clear_mailbox();
};

subtest 'Reset password for exists user' => sub {
    clear_mailbox();

    $params[1]->{args}->{verify_email} = $email;
    $params[1]->{args}->{type}         = 'reset_password';
    $params[1]->{server_name}          = 'binary.com';
    $params[1]->{link}                 = 'binary.com/some_url';

    $rpc_ct->call_ok(@params)
        ->has_no_system_error->has_no_error->result_is_deeply({status => 1}, "It always should return 1, so not to leak client's email");

    my %msg = get_email_by_address_subject(
        email   => $params[1]->{args}->{verify_email},
        subject => qr/New Password Request/
    );
    ok keys %msg, 'Email sent successfully';
    clear_mailbox();
};

subtest 'Reset password for not exists user' => sub {
    $params[1]->{args}->{verify_email} = 'not_' . $email;
    $params[1]->{args}->{type}         = 'reset_password';
    $params[1]->{server_name}          = 'binary.com';
    $params[1]->{link}                 = 'binary.com/some_url';

    $rpc_ct->call_ok(@params)
        ->has_no_system_error->has_no_error->result_is_deeply({status => 1}, "It always should return 1, so not to leak client's email");
};

subtest 'Payment agent withdraw' => sub {
    clear_mailbox();

    $params[1]->{args}->{verify_email} = $email;
    $params[1]->{args}->{type}         = 'paymentagent_withdraw';
    $params[1]->{server_name}          = 'binary.com';
    $params[1]->{link}                 = 'binary.com/some_url';

    my $token = BOM::Database::Model::AccessToken->new->create_token($client->loginid, 'test token');
    $params[1]->{params}->{token_details} = BOM::RPC::v3::Utility::get_token_details($token);

    $rpc_ct->call_ok(@params)
        ->has_no_system_error->has_no_error->result_is_deeply({status => 1}, "It always should return 1, so not to leak client's email");

    my %msg = get_email_by_address_subject(
        email   => $params[1]->{args}->{verify_email},
        subject => qr/Verify your withdrawal request/
    );
    ok keys %msg, 'Email sent successfully';
    clear_mailbox();

    $params[1]->{args}->{verify_email} = 'dummy@email.com';
    $rpc_ct->call_ok(@params)
        ->has_no_system_error->has_no_error->result_is_deeply({status => 1}, "It always should return 1, so not to leak client's email");

    %msg = get_email_by_address_subject(
        email   => $params[1]->{args}->{verify_email},
        subject => qr/Verify your withdrawal request/
    );
    is %msg, 0, 'no email as token email different from passed email';
};

subtest 'Payment withdraw' => sub {
    clear_mailbox();

    $params[1]->{args}->{verify_email} = $email;
    $params[1]->{args}->{type}         = 'payment_withdraw';
    $params[1]->{server_name}          = 'binary.com';
    $params[1]->{link}                 = 'binary.com/some_url';

    my $token = BOM::Database::Model::AccessToken->new->create_token($client->loginid, 'test token 1');
    $params[1]->{params}->{token_details} = BOM::RPC::v3::Utility::get_token_details($token);

    $rpc_ct->call_ok(@params)
        ->has_no_system_error->has_no_error->result_is_deeply({status => 1}, "It always should return 1, so not to leak client's email");

    my %msg = get_email_by_address_subject(
        email   => $params[1]->{args}->{verify_email},
        subject => qr/Verify your withdrawal request/
    );
    ok keys %msg, 'Email sent successfully';
    clear_mailbox();

    $params[1]->{args}->{verify_email} = 'dummy@email.com';
    $rpc_ct->call_ok(@params)
        ->has_no_system_error->has_no_error->result_is_deeply({status => 1}, "It always should return 1, so not to leak client's email");

    %msg = get_email_by_address_subject(
        email   => $params[1]->{args}->{verify_email},
        subject => qr/Verify your withdrawal request/
    );
    is %msg, 0, 'no email as token email different from passed email';
};

done_testing();
