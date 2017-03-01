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

use BOM::Test::RPC::Client;
use BOM::Test::Data::Utility::UnitTestDatabase;
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Platform::Token;
use Client::Account;

use utf8;

my ($t, $rpc_ct);

subtest 'Initialization' => sub {
    lives_ok {
        $t = Test::Mojo->new('BOM::RPC');
        $rpc_ct = BOM::Test::RPC::Client->new(ua => $t->app->ua);
    }
    'Initial RPC server and client connection';
};

my $params = {
    language => 'EN',
    source   => 1,
    country  => 'in',
    args     => {},
};

my ($method, $email, $client_cr, $client_cr1, $client_mlt, $client_mf, $user) = ('transfer_between_accounts');

subtest 'check_landing_company' => sub {
    $email     = 'dummy' . rand(999) . '@binary.com';
    $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email
    });

    $client_mlt = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MLT',
        email       => $email
    });
    $client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MF',
        email       => $email
    });

    $user = BOM::Platform::User->create(
        email    => $email,
        password => BOM::Platform::Password::hashpw('jskjd8292922'));
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

    $client_cr = Client::Account->new({loginid => $client_cr->loginid});
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
    subtest 'Initialization' => sub {
        lives_ok {
            $email = 'new_email' . rand(999) . '@binary.com';
            # Make real client
            $client_mlt = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'MLT',
                email       => $email
            });

            $user = BOM::Platform::User->create(
                email    => $email,
                password => BOM::Platform::Password::hashpw('jskjd8292922'));
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

        $client_mlt = Client::Account->new({loginid => $client_mlt->loginid});
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
    };

    subtest 'Transfer between mlt and mf' => sub {
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
        is $tmp->{balance}, "100.00", 'balance is 100';
        ($tmp) = grep { $_->{loginid} eq $client_mf->loginid } @{$result->{accounts}};
        is $tmp->{balance}, "0.00", 'balance is 0.00 for other account';

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
        $client_mlt = Client::Account->new({loginid => $client_mlt->loginid});
        $client_mf  = Client::Account->new({loginid => $client_mf->loginid});
        ok $client_mlt->default_account->balance == 90, '-10';
        ok $client_mf->default_account->balance == 10,  '+10';
    };

};

subtest 'Sub account transfer' => sub {
    subtest 'validate sub transfer' => sub {
        $email     = 'new_cr_email' . rand(999) . '@sample.com';
        $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
            email       => $email
        });

        $client_cr1 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
            email       => $email
        });

        $client_cr->set_default_account('USD');
        $client_cr1->set_default_account('USD');

        $user = BOM::Platform::User->create(
            email    => $email,
            password => BOM::Platform::Password::hashpw('jskjd8292922'));
        $user->email_verified(1);

        $user->add_loginid({loginid => $client_cr->loginid});
        $user->add_loginid({loginid => $client_cr1->loginid});
        $user->save;

        $params->{token} = BOM::Database::Model::AccessToken->new->create_token($client_cr->loginid, 'test token omnibus');
        $params->{args} = {
            "account_from" => $client_cr->loginid,
            "account_to"   => $client_cr1->loginid,
            "currency"     => "USD",
            "amount"       => 10
        };

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', "Sub account transfer error")
            ->error_message_is('The account transfer is unavailable for your account.',
            'Correct error message for sub account as client is not marked as allow_omnibus');

        $client_cr = Client::Account->new({loginid => $client_cr->loginid});
        ok $client_cr->get_status('disabled'), 'Client CR disabled';
        $client_cr->clr_status('disabled');
        # set allow_omnibus (master account has this set)
        $client_cr->allow_omnibus(1);
        $client_cr->save();

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', "Sub account transfer error")
            ->error_message_is('The account transfer is unavailable for your account.',
            'Correct error message for sub account as client has no sub account');

        $client_cr = Client::Account->new({loginid => $client_cr->loginid});
        ok $client_cr->get_status('disabled'), 'Client CR disabled';
        $client_cr->clr_status('disabled');
        $client_cr->allow_omnibus(1);
        $client_cr->save();

        $client_cr1 = Client::Account->new({loginid => $client_cr1->loginid});
        # set cr1 client as sub account of cr
        $client_cr1->sub_account_of($client_cr->loginid);
        $client_cr1->save();
    };

    subtest 'Sub account transfer' => sub {
        $client_cr->payment_free_gift(
            currency => 'USD',
            amount   => 100,
            remark   => 'free gift',
        );

        $client_cr->clr_status('cashier_locked');    # clear locked
        $client_cr->save();

        $params->{args} = {
            "account_from" => $client_cr->loginid,
            "account_to"   => $client_cr1->loginid,
            "currency"     => "USD",
            "amount"       => 10
        };

        my $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
        is $result->{client_to_loginid}, $client_cr1->loginid, 'Client to loginid is correct';

        # after withdraw, check both balance
        $client_cr  = Client::Account->new({loginid => $client_cr->loginid});
        $client_cr1 = Client::Account->new({loginid => $client_cr1->loginid});
        ok $client_cr->default_account->balance == 90,  '-10';
        ok $client_cr1->default_account->balance == 10, '+10';
    };
};

done_testing();
