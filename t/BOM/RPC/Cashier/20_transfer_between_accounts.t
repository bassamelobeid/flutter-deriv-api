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

subtest 'call params validation' => sub {
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

    my $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is @{$result->{accounts}}, 3, 'if no loginid from or to passed then it returns accounts';

    $params->{args} = {
        "account_from" => $client_cr->loginid,
        "account_to"   => $client_mlt->loginid,
    };

    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code},              'TransferBetweenAccountsError',   'Correct error code for no currency';
    is $result->{error}->{message_to_client}, 'Please provide valid currency.', 'Correct error message for no currency';

    $params->{args}->{currency} = 'EUR';

    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code},              'TransferBetweenAccountsError', 'Correct error code for invalid amount';
    is $result->{error}->{message_to_client}, 'Please provide valid amount.', 'Correct error message for invalid amount';

    $params->{args}->{amount} = 'NA';

    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code},              'TransferBetweenAccountsError', 'Correct error code for invalid amount';
    is $result->{error}->{message_to_client}, 'Please provide valid amount.', 'Correct error message for invalid amount';

    $params->{args}->{amount} = 1;
};

subtest 'validation' => sub {
    # random loginid to make it fail
    $params->{args}->{account_from} = 'CR123';

    my $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'TransferBetweenAccountsError', 'Correct error code for loginid that does not exists';
    is $result->{error}->{message_to_client}, 'Account transfer is not available for your account.',
        'Correct error message for loginid that does not exists';

    my $cr_dummy = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email
    });

    # send loginid that is not linked to used
    $params->{args}->{account_from} = $cr_dummy->loginid;

    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'TransferBetweenAccountsError', 'Correct error code for loginid not in siblings';
    is $result->{error}->{message_to_client}, 'Account transfer is not available for your account.',
        'Correct error message for loginid not in siblings';

    $params->{args}->{account_from} = $client_mlt->loginid;
    $params->{args}->{account_to}   = $client_mlt->loginid;

    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'TransferBetweenAccountsError', 'Correct error code if from and to are same';
    is $result->{error}->{message_to_client}, 'Account transfer is not available within same account.',
        'Correct error message if from and to are same';

    $params->{args}->{account_from} = $client_cr->loginid;

    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'TransferBetweenAccountsError', 'Correct error code';
    is $result->{error}->{message_to_client}, 'Account transfer is not available for your account.', 'Correct error message';

    $params->{args}->{account_from} = $client_mf->loginid;

    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code},              'TransferBetweenAccountsError',    'Correct error code for no default currency';
    is $result->{error}->{message_to_client}, 'Please deposit to your account.', 'Correct error message for no default currency';

    $client_mf->set_default_account('EUR');
    $params->{args}->{currency} = 'JPY';

    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'TransferBetweenAccountsError', 'Correct error code for invalid currency for landing company';
    is $result->{error}->{message_to_client}, 'Currency provided is not valid for your account.',
        'Correct error message for invalid currency for landing company';

    $params->{args}->{currency} = 'BTC';

    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'TransferBetweenAccountsError', 'Correct error code for invalid currency for landing company';
    is $result->{error}->{message_to_client}, 'Currency provided is not valid for your account.',
        'Correct error message for invalid currency for landing company';

    $params->{args}->{currency} = 'USD';

    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'TransferBetweenAccountsError', 'Correct error code';
    is $result->{error}->{message_to_client}, 'Currency provided is different from account currency.', 'Correct error message';

    $params->{args}->{currency} = 'EUR';

    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'TransferBetweenAccountsError', 'Correct error code';
    is $result->{error}->{message_to_client}, 'Please set the currency for your existing account ' . $client_mlt->loginid . '.',
        'Correct error message';

    $client_mlt->set_default_account('USD');

    $params->{token} = BOM::Database::Model::AccessToken->new->create_token($client_mf->loginid, 'test token');
    $params->{args}->{account_from} = $client_mf->loginid;
    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', 'Transfer error as no different currency')
        ->error_message_is('Account transfer is not available for accounts with different default currency.', 'Different currency error message');

    $email    = 'new_email' . rand(999) . '@binary.com';
    $cr_dummy = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email
    });

    $user = BOM::Platform::User->create(
        email    => $email,
        password => BOM::Platform::Password::hashpw('jskjd8292922'));
    $user->email_verified(1);
    $user->save;

    $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email,
    });

    $user->add_loginid({loginid => $cr_dummy->loginid});
    $user->add_loginid({loginid => $client_cr->loginid});
    $user->save;

    $client_cr->set_default_account('BTC');
    $cr_dummy->set_default_account('BTC');

    $params->{token} = BOM::Database::Model::AccessToken->new->create_token($client_cr->loginid, 'test token');
    $params->{args}->{currency}     = 'BTC';
    $params->{args}->{account_from} = $client_cr->loginid;
    $params->{args}->{account_to}   = $cr_dummy->loginid;

    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'TransferBetweenAccountsError', 'Correct error code crypto to crypto';
    is $result->{error}->{message_to_client}, 'Account transfer is not available within accounts with cryptocurrency as default currency.',
        'Correct error message for crypto to crypto';
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
            ->error_message_is('Please deposit to your account.', 'Please deposit before transfer.');

        $client_mf->set_default_account('EUR');
        $client_mlt->set_default_account('EUR');

        # some random clients
        $params->{args}->{account_to} = 'MLT999999';
        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', 'Transfer error as wrong to client')
            ->error_message_is('Account transfer is not available for your account.', 'Correct error message for transfering to random client');

        $params->{args}->{account_to} = $client_mf->loginid;
        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', 'Transfer error as no money in account')
            ->error_message_is('The maximum amount you may transfer is: EUR 0.00.', 'Correct error message for account with no money');

        $params->{args}->{amount} = -1;
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', "Invalid amount")
            ->error_message_is('Please provide valid amount.', 'Correct error message for transfering invalid amount');

        $params->{args}->{amount} = 0.01;
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', "Invalid amount")
            ->error_message_is('The maximum amount you may transfer is: EUR 0.00.', 'Correct error message for transfering invalid amount');
    };

    subtest 'Transfer between mlt and mf' => sub {
        $params->{args} = {};
        my $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
        is scalar(@{$result->{accounts}}), 2, 'two accounts';
        my ($tmp) = grep { $_->{loginid} eq $client_mlt->loginid } @{$result->{accounts}};
        is $tmp->{balance}, "0.00", 'balance is 0';

        $client_mlt->payment_free_gift(
            currency => 'EUR',
            amount   => 5000,
            remark   => 'free gift',
        );

        $client_mlt->clr_status('cashier_locked');    # clear locked
        $client_mlt->save();

        $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
        is scalar(@{$result->{accounts}}), 2, 'two accounts';
        ($tmp) = grep { $_->{loginid} eq $client_mlt->loginid } @{$result->{accounts}};
        is $tmp->{balance}, "5000.00", 'balance is 5000';
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
        ok $client_mlt->default_account->balance == 4990, '-10';
        ok $client_mf->default_account->balance == 10,    '+10';
    };

    subtest 'test limit from mlt to mf' => sub {
        $client_mlt->payment_free_gift(
            currency => 'EUR',
            amount   => -2000,
            remark   => 'free gift',
        );
        ok $client_mlt->default_account->load->balance == 2990, '-2000';

        $params->{args} = {
            "account_from" => $client_mlt->loginid,
            "account_to"   => $client_mf->loginid,
            "currency"     => "EUR",
            "amount"       => 110
        };
        my $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
        is($result->{error}{message_to_client}, 'The maximum amount you may transfer is: EUR -10.00.', 'error for limit');
        is($result->{error}{code}, 'TransferBetweenAccountsError', 'error code for limit');
        }
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
            ->error_message_is('The maximum amount you may transfer is: USD 0.00.', 'Correct error message as no deposit done yet.');

        $client_cr = Client::Account->new({loginid => $client_cr->loginid});
        # set allow_omnibus (master account has this set)
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
