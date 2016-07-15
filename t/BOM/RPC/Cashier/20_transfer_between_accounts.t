use strict;
use warnings;

use Test::Most;
use Test::Mojo;
use Test::MockModule;
use Test::FailWarnings;
use Test::Warn;

use MojoX::JSON::RPC::Client;
use Data::Dumper;
use POSIX qw/ ceil /;

use Test::BOM::RPC::Client;
use BOM::Test::Data::Utility::UnitTestDatabase;
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Platform::Token;
use BOM::Platform::Client;

use utf8;

my ($t, $rpc_ct);

subtest 'Initialization' => sub {
    lives_ok {
        $t = Test::Mojo->new('BOM::RPC');
        $rpc_ct = Test::BOM::RPC::Client->new(ua => $t->app->ua);
    }
    'Initial RPC server and client connection';
};

my $params = {
    language => 'EN',
    source   => 1,
    country  => 'in',
    args     => {},
};

my $method = 'transfer_between_accounts';

subtest 'check_landing_company' => sub {
    my $email     = 'dummy' . rand(999) . '@binary.com';
    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email
    });
    my $client_mlt = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MLT',
        email       => $email
    });
    my $client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MF',
        email       => $email
    });

    my $password = 'jskjd8292922';
    my $hash_pwd = BOM::System::Password::hashpw($password);
    my $user     = BOM::Platform::User->create(
        email    => $email,
        password => $hash_pwd
    );
    $user->email_verified(1);
    $user->save;

    $user->add_loginid({loginid => $client_cr->loginid});
    $user->add_loginid({loginid => $client_mlt->loginid});
    $user->add_loginid({loginid => $client_mf->loginid});
    $user->save;

    $params->{token} = BOM::Database::Model::AccessToken->new->create_token($client_cr->loginid, 'test token');
    $params->{args} = {
        "account_from" => $client_cr->loginid,
        "account_to"   => $client_mlt->loginid,
        "currency"     => "EUR",
        "amount"       => 100
    };

    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', 'Transfer error as wrong landing companies')
        ->error_message_is('The account transfer is unavailable for your account.', 'Correct error message for transfer failure');

    $client_cr = BOM::Platform::Client->new({loginid => $client_cr->loginid});
    ok $client_cr->get_status('disabled'), 'Client CR cannot transfer to MLT';

    $client_mf->set_default_account('EUR');
    $client_mlt->set_default_account('USD');

    $params->{token} = BOM::Database::Model::AccessToken->new->create_token($client_mf->loginid, 'test token');
    $params->{args}->{account_from} = $client_mf->loginid;
    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', 'Transfer error as no different currency')
        ->error_message_is('The account transfer is unavailable for accounts with different default currency.', 'Different currency error message');
};

subtest $method => sub {
    my ($user, $client_mlt, $client_mf, $auth_token, $email);

    subtest 'Initialization' => sub {
        lives_ok {
            $email = 'new_email' . rand(999) . '@binary.com';
            # Make real client
            $client_mlt = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'MLT',
                email       => $email
            });
            $auth_token = BOM::Database::Model::AccessToken->new->create_token($client_mlt->loginid, 'test token');

            my $password = 'jskjd8292922';
            my $hash_pwd = BOM::System::Password::hashpw($password);
            $user = BOM::Platform::User->create(
                email    => $email,
                password => $hash_pwd
            );
            $user->email_verified(1);
            $user->save;

            $client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'MF',
                email       => $email,
            });

            $user->add_loginid({loginid => $client_mlt->loginid});
            $user->add_loginid({loginid => $client_mf->loginid});
            $user->save;
        }
        'Initial users and clients setup';
    };

    subtest 'Validate transfers' => sub {
        $params->{token} = BOM::Database::Model::AccessToken->new->create_token($client_mlt->loginid, 'test token');
        $params->{args} = {
            "account_from" => $client_mlt->loginid,
            "account_to"   => $client_mf->loginid,
            "currency"     => "EUR",
            "amount"       => 100
        };

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', 'Transfer error as no deposit done')
            ->error_message_is('The account transfer is unavailable. Please deposit to your account.', 'Please deposit before transfer.');

        $client_mf->set_default_account('EUR');
        $client_mlt->set_default_account('EUR');

        # some random clients
        $params->{args}->{account_to} = 'MLT999999';
        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', 'Transfer error as wrong to client')
            ->error_message_is('The account transfer is unavailable for your account.', 'Correct error message for transfering to random client');

        $client_mlt = BOM::Platform::Client->new({loginid => $client_mlt->loginid});
        ok $client_mlt->get_status('disabled'), 'Disabled as tampereb by transferring to random client';

        $client_mlt->clr_status('disabled');
        $client_mlt->save();

        $params->{args}->{account_to} = $client_mf->loginid;
        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', 'Transfer error as no money in account')
            ->error_message_is('The maximum amount you may transfer is: EUR 0.', 'Correct error message for account with no money');

        foreach my $amount (-1, 0.01) {
            $params->{args}->{amount} = $amount;
            $rpc_ct->call_ok($method, $params)
                ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', "Invalid amount $amount")
                ->error_message_is('Invalid amount. Minimum transfer amount is 0.10, and up to 2 decimal places.',
                'Correct error message for transfering invalid amount');
        }

        $params->{args} = {};
        my $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
        is scalar(@{$result->{accounts}}), 2, 'two accounts';
        my ($tmp) = grep { $_->{loginid} eq $client_mlt->loginid } @{$result->{accounts}};
        is $tmp->{balance}, "0.00", 'balance is 0';

        $client_mlt->payment_free_gift(
            currency => 'EUR',
            amount   => 100,
            remark   => 'free gift',
        );

        $client_mlt->clr_status('cashier_locked');    # clear locked
        $client_mlt->save();

        $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
        is scalar(@{$result->{accounts}}), 2, 'two accounts';
        ($tmp) = grep { $_->{loginid} eq $client_mlt->loginid } @{$result->{accounts}};
        is $tmp->{balance}, "100.00", 'balance is 0';

        $params->{args} = {
            "account_from" => $client_mlt->loginid,
            "account_to"   => $client_mf->loginid,
            "currency"     => "EUR",
            "amount"       => 10
        };
        $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
        is $result->{client_to_loginid},   $client_mf->loginid,   'transfer_between_accounts to client is ok';
        is $result->{client_to_full_name}, $client_mf->full_name, 'transfer_between_accounts to client name is ok';

        ## after withdraw, check both balance
        $client_mlt = BOM::Platform::Client->new({loginid => $client_mlt->loginid});
        $client_mf  = BOM::Platform::Client->new({loginid => $client_mf->loginid});
        ok $client_mlt->default_account->balance == 90, '-10';
        ok $client_mf->default_account->balance == 10,  '+10';
    };

    subtest 'Sub account transfer' => sub {
        $params->{args}->{sub_account} = 1;
        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', "Sub account transfer error")
            ->error_message_is('The account transfer is unavailable for your account.',
            'Correct error message for sub account as client is not marked as allow_omnibus');

        $client_mlt = BOM::Platform::Client->new({loginid => $client_mlt->loginid});
        ok $client_mlt->get_status('disabled'), 'Client MLT disabled';
        $client_mlt->clr_status('disabled');
        # set allow_omnibus (master account has this set)
        $client_mlt->allow_omnibus(1);
        $client_mlt->save();

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', "Sub account transfer error")
            ->error_message_is('The account transfer is unavailable for your account.',
            'Correct error message for sub account as client has no sub account');

        $client_mlt = BOM::Platform::Client->new({loginid => $client_mlt->loginid});
        ok $client_mlt->get_status('disabled'), 'Client MLT disabled';
        $client_mlt->clr_status('disabled');
        $client_mlt->allow_omnibus(1);
        $client_mlt->save();

        $client_mf = BOM::Platform::Client->new({loginid => $client_mf->loginid});
        # set mf client as sub account of mlt
        $client_mf->sub_account_of($client_mlt->loginid);
        $client_mf->save();

        my $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
        is $result->{client_to_loginid}, $client_mf->loginid, 'Client to loginid is correct';

        # after withdraw, check both balance
        $client_mlt = BOM::Platform::Client->new({loginid => $client_mlt->loginid});
        $client_mf  = BOM::Platform::Client->new({loginid => $client_mf->loginid});
        ok $client_mlt->default_account->balance == 80, '-10';
        ok $client_mf->default_account->balance == 20,  '+10';
    };
};

done_testing();
