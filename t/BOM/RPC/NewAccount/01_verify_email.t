use strict;
use warnings;

use Test::Most;
use Test::Mojo;
use Test::MockModule;

use MojoX::JSON::RPC::Client;
use Data::Dumper;

use Test::BOM::RPC::Client;
use BOM::Test::Data::Utility::UnitTestDatabase;
use BOM::Test::Email qw(get_email_by_address_subject clear_mailbox);

use utf8;

my ($user, $client, $email);
my ($t, $rpc_ct);
my $method = 'verify_email';

my @params = (
    $method,
    {
        language => 'RU',
        source   => 1,
        country  => 'ru',
    });

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
        $rpc_ct = Test::BOM::RPC::Client->new(ua => $t->app->ua);
    }
    'Initial RPC server and client connection';
};

subtest 'Account opening request with email does not exist' => sub {
    clear_mailbox();

    $params[1]->{email}       = 'test' . rand(999) . '@binary.com';
    $params[1]->{type}        = 'account_opening';
    $params[1]->{server_name} = 'anynotqaserver';
    $params[1]->{link}        = 'binary.com/some_url';

    $rpc_ct->call_ok(@params)
        ->has_no_system_error->has_no_error->result_is_deeply({status => 1}, "It always should return 1, so not to leak client's email");

    my %msg = get_email_by_address_subject(
        email   => $params[1]->{email},
        subject => qr/Подтвердите свой электронный адрес/
    );
    ok keys %msg, 'Email sent successfully';
    clear_mailbox();
};

subtest 'Account opening request with email exists' => sub {
    clear_mailbox();

    $params[1]->{email}       = $email;
    $params[1]->{type}        = 'account_opening';
    $params[1]->{server_name} = 'qa30';
    $params[1]->{link}        = 'binary.com/some_url';

    $rpc_ct->call_ok(@params)
        ->has_no_system_error->has_no_error->result_is_deeply({status => 1}, "It always should return 1, so not to leak client's email");

    my %msg = get_email_by_address_subject(
        email   => $params[1]->{email},
        subject => qr/Предоставлен дублирующий Email/
    );
    ok keys %msg, 'Email sent successfully';
    ok lc($msg{subject}) =~ /binaryqa30\.com$/, 'Using right website_name';
    clear_mailbox();
};

subtest 'Reset password for exists user' => sub {
    clear_mailbox();

    $params[1]->{email}       = $email;
    $params[1]->{type}        = 'reset_password';
    $params[1]->{server_name} = 'anynotqaserver';
    $params[1]->{link}        = 'binary.com/some_url';

    $rpc_ct->call_ok(@params)
        ->has_no_system_error->has_no_error->result_is_deeply({status => 1}, "It always should return 1, so not to leak client's email");

    my %msg = get_email_by_address_subject(
        email   => $params[1]->{email},
        subject => qr/Запрос нового пароля/
    );
    ok keys %msg, 'Email sent successfully';
    ok lc($msg{subject}) =~ /binary\.com$/, 'Using right website_name';
    clear_mailbox();
};

subtest 'Reset password for not exists user' => sub {
    $params[1]->{email}       = 'not_' . $email;
    $params[1]->{type}        = 'reset_password';
    $params[1]->{server_name} = 'anynotqaserver';
    $params[1]->{link}        = 'binary.com/some_url';

    $rpc_ct->call_ok(@params)
        ->has_no_system_error->has_no_error->result_is_deeply({status => 1}, "It always should return 1, so not to leak client's email");
};

subtest 'Payment agent withdraw' => sub {
    clear_mailbox();

    $params[1]->{email}       = $email;
    $params[1]->{type}        = 'paymentagent_withdraw';
    $params[1]->{server_name} = 'anynotqaserver';
    $params[1]->{link}        = 'binary.com/some_url';

    $rpc_ct->call_ok(@params)
        ->has_no_system_error->has_no_error->result_is_deeply({status => 1}, "It always should return 1, so not to leak client's email");

    my %msg = get_email_by_address_subject(
        email   => $params[1]->{email},
        subject => qr/Подтвердите свой запрос на вывод/
    );
    ok keys %msg, 'Email sent successfully';
    clear_mailbox();
};

done_testing();
