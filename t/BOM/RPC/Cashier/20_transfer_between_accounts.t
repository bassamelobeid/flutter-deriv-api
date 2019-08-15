use strict;
use warnings;

use Test::Most;
use Test::Mojo;
use Test::MockModule;
use Test::MockTime qw(:all);
use Guard;
use Test::FailWarnings;
use Test::Warn;

use MojoX::JSON::RPC::Client;
use POSIX qw/ ceil /;
use ExchangeRates::CurrencyConverter qw(in_usd convert_currency);
use Format::Util::Numbers qw/financialrounding/;

use BOM::User::Client;
use BOM::RPC::v3::MT5::Account;

use BOM::Test::RPC::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::ExchangeRates qw/populate_exchange_rates populate_exchange_rates_db/;
use BOM::Platform::Token;
use Email::Stuffer::TestLinks;
use BOM::Config::RedisReplicated;
use BOM::Config::Runtime;
use BOM::Config::CurrencyConfig;

use utf8;

my $test_binary_user_id = 65000;
my ($t, $rpc_ct);

my $redis = BOM::Config::RedisReplicated::redis_exchangerates_write();

# In the weekend the account transfers will be suspended. So we mock a valid day here
set_absolute_time(Date::Utility->new('2018-02-15')->epoch);
scope_guard { restore_time() };

# unlimit daily transfer
BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->between_accounts(999);

subtest 'Initialization' => sub {
    lives_ok {
        $t = Test::Mojo->new('BOM::RPC::Transport::HTTP');
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

my (
    $email,         $client_vr,     $client_cr,     $cr_dummy,         $client_mlt,       $client_mf, $client_cr_usd,
    $client_cr_btc, $client_cr_ust, $client_cr_eur, $client_cr_pa_usd, $client_cr_pa_btc, $user,      $token
);
my $method = 'transfer_between_accounts';

my $btc_usd_rate = 4000;
my $custom_rates = {
    'BTC' => $btc_usd_rate,
    'UST' => 1
};

populate_exchange_rates();
populate_exchange_rates($custom_rates);

my $tmp_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
    email       => 'tmp@abcdfef.com'
});

populate_exchange_rates_db($tmp_client->db->dbic, $custom_rates);

subtest 'call params validation' => sub {
    $email = 'dummy' . rand(999) . '@binary.com';

    $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
        email       => $email
    });

    $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        place_of_birth => 'id'
    });

    $client_mlt = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'MLT',
        email          => $email,
        place_of_birth => 'id'
    });

    $client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'MF',
        email          => $email,
        place_of_birth => 'id'
    });

    $user = BOM::User->create(
        email          => $email,
        password       => BOM::User::Password::hashpw('jskjd8292922'),
        email_verified => 1,
    );

    $user->add_client($client_cr);
    $user->add_client($client_mlt);
    $user->add_client($client_mf);

    $token = BOM::Database::Model::AccessToken->new->create_token($client_cr->loginid, 'test token');
    $params->{token} = $token;

    my $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is @{$result->{accounts}}, 3, 'if no loginid from or to passed then it returns accounts';

    $params->{args} = {
        account_from => $client_cr->loginid,
        account_to   => $client_mlt->loginid,
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

    $params->{args}->{amount}   = 1;
    $params->{args}->{currency} = 'XXX';
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code},              'TransferBetweenAccountsError',   'Correct error code for invalid currency';
    is $result->{error}->{message_to_client}, 'Please provide valid currency.', 'Correct error message for invalid amount';

    $params->{args}->{currency}     = 'EUR';
    $params->{args}->{account_from} = $client_vr->loginid;

    $params->{token} = BOM::Database::Model::AccessToken->new->create_token($client_vr->loginid, 'test token');

    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code},              'PermissionDenied',   'Correct error code for virtual account';
    is $result->{error}->{message_to_client}, 'Permission denied.', 'Correct error message for virtual account';

    $params->{token} = $token;
    $params->{args}->{account_from} = $client_cr->loginid;

    $client_cr->status->set('cashier_locked', 'system', 'testing something');

    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'TransferBetweenAccountsError', 'Correct error code for cashier locked';
    is $result->{error}->{message_to_client}, 'You cannot perform this action, as your account is cashier locked.',
        'Correct error message for cashier locked';

    $client_cr->status->clear_cashier_locked;
    $client_cr->status->set('withdrawal_locked', 'system', 'testing something');

    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'TransferBetweenAccountsError', 'Correct error code for withdrawal locked';
    is $result->{error}->{message_to_client}, 'You cannot perform this action, as your account is withdrawal locked.',
        'Correct error message for withdrawal locked';

    $client_cr->status->clear_withdrawal_locked;
};

subtest 'validation' => sub {

    #populate exchange reates for BOM::TEST redis server to be used on validation_transfer_between_accounts
    populate_exchange_rates();

    # random loginid to make it fail
    $params->{token} = $token;
    $params->{args}->{account_from} = 'CR123';
    my $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'TransferBetweenAccountsError', 'Correct error code for loginid that does not exists';
    is $result->{error}->{message_to_client}, 'Transfers between accounts are not available for your account.',
        'Correct error message for loginid that does not exists';

    $cr_dummy = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email
    });

    # send loginid that is not linked to used
    $params->{args}->{account_from} = $cr_dummy->loginid;

    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'TransferBetweenAccountsError', 'Correct error code for loginid not in siblings';
    is $result->{error}->{message_to_client}, 'Transfers between accounts are not available for your account.',
        'Correct error message for loginid not in siblings';

    $params->{args}->{account_from} = $client_mlt->loginid;
    $params->{args}->{account_to}   = $client_mlt->loginid;

    $params->{token} = BOM::Database::Model::AccessToken->new->create_token($client_mlt->loginid, 'test token');

    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'TransferBetweenAccountsError', 'Correct error code if from and to are same';
    is $result->{error}->{message_to_client}, 'Account transfers are not available within same account.',
        'Correct error message if from and to are same';

    $params->{token} = BOM::Database::Model::AccessToken->new->create_token($client_cr->loginid, 'test token');
    $params->{args}->{account_from} = $client_cr->loginid;

    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'TransferBetweenAccountsError', 'Correct error code';
    is $result->{error}->{message_to_client}, 'Transfers between accounts are not available for your account.',
        'Correct error message for different landing companies';

    $params->{args}->{account_from} = $client_mf->loginid;

    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'TransferBetweenAccountsError', 'Correct error code for no default currency';
    is $result->{error}->{message_to_client}, 'From account provided should be same as current authorized client.',
        'Correct error message if from is not same as authorized client';

    $params->{token} = BOM::Database::Model::AccessToken->new->create_token($client_mf->loginid, 'test token');
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code},              'TransferBetweenAccountsError',    'Correct error code for no default currency';
    is $result->{error}->{message_to_client}, 'Please deposit to your account.', 'Correct error message for no default currency';

    $client_mf->set_default_account('EUR');

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
        ->error_message_is('Account transfers are not available for accounts with different currencies.', 'Different currency error message');

    $email    = 'new_email' . rand(999) . '@binary.com';
    $cr_dummy = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        place_of_birth => 'id'
    });

    $user = BOM::User->create(
        email          => $email,
        password       => BOM::User::Password::hashpw('jskjd8292922'),
        email_verified => 1,
    );

    $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        place_of_birth => 'id'
    });

    $user->add_client($cr_dummy);
    $user->add_client($client_cr);

    $client_cr->set_default_account('BTC');
    $cr_dummy->set_default_account('BTC');

    $params->{token} = BOM::Database::Model::AccessToken->new->create_token($client_cr->loginid, 'test token');
    $params->{args}->{currency}     = 'BTC';
    $params->{args}->{account_from} = $client_cr->loginid;
    $params->{args}->{account_to}   = $cr_dummy->loginid;

    $params->{args}->{amount} = 0.400000001;

    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'TransferBetweenAccountsError', 'Correct error code for invalid amount';
    like $result->{error}->{message_to_client},
        qr/Invalid amount. Amount provided can not have more than/,
        'Correct error message for amount with decimal places more than allowed per currency';

    $params->{args}->{amount} = 0.02;
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'TransferBetweenAccountsError', 'Correct error code crypto to crypto';
    is $result->{error}->{message_to_client}, 'Account transfers are not available within accounts with cryptocurrency as default currency.',
        'Correct error message for crypto to crypto';

    # min/max should be calculated for transfer between different currency (fiat to crypto and vice versa)
    $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        place_of_birth => 'id'
    });

    $user->add_client($client_cr);
    $client_cr->set_default_account('USD');

    $params->{token} = BOM::Database::Model::AccessToken->new->create_token($client_cr->loginid, 'test token');
    $params->{args}->{currency}     = 'USD';
    $params->{args}->{account_from} = $client_cr->loginid;
    $params->{args}->{account_to}   = $cr_dummy->loginid;

    my $min = BOM::Config::CurrencyConfig::transfer_between_accounts_limits(1)->{'USD'}->{min};
    $params->{args}->{amount} = financialrounding('amount', 'USD', $min - 0.01);
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;

    is $result->{error}->{code}, 'TransferBetweenAccountsError', 'Correct error code crypto to crypto';
    like $result->{error}->{message_to_client},
        qr/Provided amount is not within permissible limits. Minimum transfer amount for USD currency is/,
        'Correct error message for invalid minimum amount';

    my $max = BOM::Config::CurrencyConfig::transfer_between_accounts_limits(1)->{'USD'}->{max};
    $params->{args}->{amount} = financialrounding('amount', 'USD', $max * 2);
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'TransferBetweenAccountsError', 'Correct error code crypto to crypto';
    like $result->{error}->{message_to_client},
        qr/Provided amount is not within permissible limits. Maximum transfer amount for USD currency is/,
        'Correct error message for invalid maximum amount';

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

            $client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code => 'MF',
                email       => $email,
            });

            $user = BOM::User->create(
                email          => $email,
                password       => BOM::User::Password::hashpw('jskjd8292922'),
                email_verified => 1,
            );

            $user->add_client($client_mlt);
            $user->add_client($client_mf);
        }
        'Initial users and clients setup';
    };

    subtest 'Validate transfers' => sub {
        $params->{token} = BOM::Database::Model::AccessToken->new->create_token($client_mlt->loginid, 'test token');
        $params->{args} = {
            account_from => $client_mlt->loginid,
            account_to   => $client_mf->loginid,
            currency     => "EUR",
            amount       => 100
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
            ->error_message_is('Transfers between accounts are not available for your account.',
            'Correct error message for transfering to random client');

        $params->{args}->{account_to} = $client_mf->loginid;
        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', 'Transfer error as no money in account')
            ->error_message_is('The maximum amount you may transfer is: EUR 0.00.', 'Correct error message for account with no money');

        $params->{args}->{amount} = -1;
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', "Invalid amount")
            ->error_message_is('Please provide valid amount.', 'Correct error message for transfering invalid amount');

        $params->{args}->{amount} = 0;
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', "Invalid amount")
            ->error_message_is('Please provide valid amount.', 'Correct error message for transfering invalid amount');

        $params->{args}->{amount} = 1;
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

        $client_mlt->status->clear_cashier_locked;    # clear locked

        $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
        is scalar(@{$result->{accounts}}), 2, 'two accounts';
        ($tmp) = grep { $_->{loginid} eq $client_mlt->loginid } @{$result->{accounts}};
        is $tmp->{balance}, "5000.00", 'balance is 5000';
        ($tmp) = grep { $_->{loginid} eq $client_mf->loginid } @{$result->{accounts}};
        is $tmp->{balance}, "0.00", 'balance is 0.00 for other account';

        $params->{args} = {
            account_from => $client_mlt->loginid,
            account_to   => $client_mf->loginid,
            currency     => "EUR",
            amount       => 10,
        };
        $params->{token} = BOM::Database::Model::AccessToken->new->create_token($client_mlt->loginid, 'test token');
        $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
        is $result->{client_to_loginid},   $client_mf->loginid,   'transfer_between_accounts to client is ok';
        is $result->{client_to_full_name}, $client_mf->full_name, 'transfer_between_accounts to client name is ok';

        ## after withdraw, check both balance
        $client_mlt = BOM::User::Client->new({loginid => $client_mlt->loginid});
        $client_mf  = BOM::User::Client->new({loginid => $client_mf->loginid});
        ok $client_mlt->default_account->balance == 4990, '-10';
        ok $client_mf->default_account->balance == 10,    '+10';
    };

    subtest 'test limit from mlt to mf' => sub {
        $client_mlt->payment_free_gift(
            currency => 'EUR',
            amount   => -2000,
            remark   => 'free gift',
        );
        ok $client_mlt->default_account->balance == 2990, '-2000';

        $params->{args} = {
            account_from => $client_mlt->loginid,
            account_to   => $client_mf->loginid,
            currency     => "EUR",
            amount       => 110
        };
        my $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
        is($result->{error}{message_to_client}, 'The maximum amount you may transfer is: EUR -10.00.', 'error for limit');
        is($result->{error}{code}, 'TransferBetweenAccountsError', 'error code for limit');
    };
};

subtest 'transfer with fees' => sub {
    populate_exchange_rates($custom_rates);

    $email         = 'new_transfer_email' . rand(999) . '@sample.com';
    $client_cr_usd = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        binary_user_id => $test_binary_user_id,
        place_of_birth => 'id',
    });

    $client_cr_btc = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        binary_user_id => $test_binary_user_id,
        place_of_birth => 'id',
    });

    $client_cr_ust = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        binary_user_id => $test_binary_user_id,
        place_of_birth => 'id',
    });

    $client_cr_eur = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        binary_user_id => $test_binary_user_id,
        place_of_birth => 'id',
    });

    # create an unauthorised pa
    $client_cr_pa_btc = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        binary_user_id => $test_binary_user_id,
        place_of_birth => 'id',
    });

    $client_cr_pa_btc->payment_agent({
        payment_agent_name    => 'Joe',
        url                   => 'http://www.example.com/',
        email                 => 'joe@example.com',
        phone                 => '+12345678',
        information           => 'Test Info',
        summary               => 'Test Summary',
        commission_deposit    => 0,
        commission_withdrawal => 0,
        is_authenticated      => 'f',
        currency_code         => 'BTC',
        target_country        => 'id',
    });

    $client_cr_pa_btc->payment_free_gift(
        currency => 'BTC',
        amount   => 1,
        remark   => 'free gift',
    );
    cmp_ok $client_cr_pa_btc->default_account->balance, '==', 1, 'correct balance';

    $client_cr_usd->set_default_account('USD');
    $client_cr_btc->set_default_account('BTC');
    $client_cr_pa_btc->set_default_account('BTC');
    $client_cr_ust->set_default_account('UST');
    $client_cr_eur->set_default_account('EUR');

    $user = BOM::User->create(
        email          => $email,
        password       => BOM::User::Password::hashpw('jskjd8292922'),
        email_verified => 1,
    );

    $user->add_client($client_cr_usd);
    $user->add_client($client_cr_btc);
    $user->add_client($client_cr_pa_btc);
    $user->add_client($client_cr_ust);
    $user->add_client($client_cr_eur);

    $client_cr_pa_btc->save;

    $client_cr_usd->payment_free_gift(
        currency       => 'USD',
        amount         => 1000,
        remark         => 'free gift',
        place_of_birth => 'id',
    );

    cmp_ok $client_cr_usd->default_account->balance, '==', 1000, 'correct balance';

    $client_cr_btc->payment_free_gift(
        currency       => 'BTC',
        amount         => 1,
        remark         => 'free gift',
        place_of_birth => 'id',
    );

    cmp_ok $client_cr_btc->default_account->balance, '==', 1, 'correct balance';

    $client_cr_ust->payment_free_gift(
        currency       => 'UST',
        amount         => 1000,
        remark         => 'free gift',
        place_of_birth => 'id',
    );

    cmp_ok $client_cr_ust->default_account->balance, '==', 1000, 'correct balance';

    $params->{token} = BOM::Database::Model::AccessToken->new->create_token($client_cr_usd->loginid, 'test token');
    my $amount = 10;
    $params->{args} = {
        account_from => $client_cr_usd->loginid,
        account_to   => $client_cr_btc->loginid,
        currency     => "USD",
        amount       => $amount
    };

    BOM::Config::Runtime->instance->app_config->system->suspend->transfer_between_accounts(1);
    $rpc_ct->call_ok($method, $params)->has_error('error as all transfer_between_accounts are suspended in system config')
        ->error_code_is('TransferBetweenAccountsError', 'error code is TransferBetweenAccountsError')
        ->error_message_is('Transfers between fiat and crypto accounts are currently disabled.')->result;
    BOM::Config::Runtime->instance->app_config->system->suspend->transfer_between_accounts(0);

    my ($usd_btc_fee, $btc_usd_fee, $usd_ust_fee, $ust_usd_fee, $ust_eur_fee) = (2, 3, 4, 5, 6);
    my $mock_fees = Test::MockModule->new('BOM::Config::CurrencyConfig', no_auto => 1);
    $mock_fees->mock(
        transfer_between_accounts_fees => sub {
            return {
                'USD' => {
                    'UST' => $usd_ust_fee,
                    'BTC' => $usd_btc_fee,
                },
                'UST' => {
                    'USD' => $ust_usd_fee,
                    'EUR' => $ust_eur_fee
                },
                'BTC' => {'USD' => $btc_usd_fee},
            };
        },
        transfer_between_accounts_limits => sub {
            my $force_refresh = shift;
            my $limits        = $mock_fees->original('transfer_between_accounts_limits')->($force_refresh);
            #It ensures that instead of fake values below, actual limits will be retrieved in error handling, where update to transfer limits is requested.
            unless ($force_refresh) {
                $limits->{USD}->{min} = 0.01;
                $limits->{UST}->{min} = 0.01;
            }
            return $limits;
        });

    $params->{args}->{amount} = 0.01;
    # The amount will be accepted initially, but rejected when getting the recieved amount in BTC.
    $rpc_ct->call_ok($method, $params)->has_error->error_code_is('TransferBetweenAccountsError')
        ->error_message_is("This amount is too low. Please enter a minimum of 1 USD.");

    $params->{args}->{amount} = $amount;
    my $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{client_to_loginid}, $client_cr_btc->loginid, 'Transaction successful';

    # fiat to crypto. exchange rate is 4000 for BTC
    my $fee_percent     = $usd_btc_fee;
    my $transfer_amount = ($amount - $amount * $fee_percent / 100) / 4000;
    my $current_balance = $client_cr_btc->default_account->balance;
    cmp_ok $current_balance, '==', 1 + $transfer_amount, 'correct balance after transfer including fees';
    cmp_ok $client_cr_usd->default_account->balance, '==', 1000 - $amount, 'non-pa to non-pa(USD to BTC), correct balance, exact amount deducted';

    $params->{token} = BOM::Database::Model::AccessToken->new->create_token($client_cr_btc->loginid, 'test token');
    $amount          = 0.1;
    $params->{args}  = {
        account_from => $client_cr_btc->loginid,
        account_to   => $client_cr_usd->loginid,
        currency     => "BTC",
        amount       => $amount
    };
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{client_to_loginid}, $client_cr_usd->loginid, 'Transaction successful';

    # crypto to fiat is 1%
    $fee_percent     = $btc_usd_fee;
    $transfer_amount = ($amount - $amount * $fee_percent / 100) * 4000;
    cmp_ok $client_cr_usd->default_account->balance, '==', 990 + $transfer_amount, 'correct balance after transfer including fees';
    is(
        financialrounding('price', 'BTC', $client_cr_btc->account->balance),
        financialrounding('price', 'BTC', $current_balance - $amount),
        'non-pa to non-pa (BTC to USD), correct balance after transfer including fees'
    );

    $amount = 0.1;
    $params->{token} = BOM::Database::Model::AccessToken->new->create_token($client_cr_pa_btc->loginid, 'test token');
    $params->{args} = {
        account_from => $client_cr_pa_btc->loginid,
        account_to   => $client_cr_usd->loginid,
        currency     => "BTC",
        amount       => $amount
    };

    my $previous_amount     = $client_cr_pa_btc->default_account->balance;
    my $previous_amount_usd = $client_cr_usd->default_account->balance;

    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{client_to_loginid}, $client_cr_usd->loginid, 'Transaction successful';

    # crypto to fiat is 1% and fiat to crypto is 1%
    $fee_percent     = $btc_usd_fee;
    $transfer_amount = ($amount - $amount * $fee_percent / 100) * 4000;
    cmp_ok $client_cr_pa_btc->default_account->balance, '==', $previous_amount - $amount, 'correct balance after transfer including fees';
    $current_balance = $client_cr_usd->default_account->balance;
    cmp_ok $current_balance, '==', $previous_amount_usd + $transfer_amount,
        'unauthorised pa to non-pa transfer (BTC to USD) correct balance after transfer including fees';

    # database function throw error if same transaction happens
    # in 2 seconds
    sleep(2);

    #The minimum fee 0.01 UST is applied on the total of 0.02. The reamining 0.01 is less than 0.01 EUR (minimum allowed)
    #Similar to the case of 0.01 USD transfer above.
    $amount = 0.02;
    $params->{token} = BOM::Database::Model::AccessToken->new->create_token($client_cr_ust->loginid, 'test token');
    $params->{args} = {
        account_from => $client_cr_ust->loginid,
        account_to   => $client_cr_eur->loginid,
        currency     => "UST",
        amount       => $amount
    };
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->error_code_is('TransferBetweenAccountsError')
        ->error_message_is('This amount is too low. Please enter a minimum of 1 UST.');

    #No transfer fee for BTC-EUR
    $amount = 0.02;
    $params->{token} = BOM::Database::Model::AccessToken->new->create_token($client_cr_btc->loginid, 'test token');
    $params->{args} = {
        account_from => $client_cr_btc->loginid,
        account_to   => $client_cr_eur->loginid,
        currency     => "BTC",
        amount       => $amount
    };
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->error_code_is('TransferBetweenAccountsError')
        ->error_message_is('Account transfers are not possible between BTC and EUR.');

    $amount = 100;
    $params->{token} = BOM::Database::Model::AccessToken->new->create_token($client_cr_usd->loginid, 'test token');
    $params->{args} = {
        account_from => $client_cr_usd->loginid,
        account_to   => $client_cr_pa_btc->loginid,
        currency     => "USD",
        amount       => $amount
    };

    $previous_amount_usd = $client_cr_usd->default_account->balance;
    my $previous_amount_btc = $client_cr_pa_btc->default_account->balance;
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{client_to_loginid}, $client_cr_pa_btc->loginid, 'Transaction successful';

    $fee_percent     = $usd_btc_fee;
    $transfer_amount = ($amount - $amount * $fee_percent / 100) / 4000;
    cmp_ok $client_cr_usd->default_account->balance, '==', $previous_amount_usd - $amount, 'correct balance after transfer including fees';
    $current_balance = $client_cr_pa_btc->default_account->balance;

    is(
        financialrounding('price', 'BTC', $current_balance),
        financialrounding('price', 'BTC', $previous_amount_btc + $transfer_amount),
        'non-pa to unauthorised pa transfer (USD to BTC) correct balance after transfer including fees'
    );

    subtest 'Correct commission charged for fiat -> stablecoin crypto' => sub {
        my $previous_amount_usd = $client_cr_usd->account->balance;
        my $previous_amount_ust = $client_cr_ust->account->balance;

        my $amount                   = 100;
        my $expected_fee_percent     = $usd_ust_fee;
        my $expected_transfer_amount = ($amount - $amount * $expected_fee_percent / 100);

        $params->{token} = BOM::Database::Model::AccessToken->new->create_token($client_cr_usd->loginid, 'test token');
        $params->{args} = {
            account_from => $client_cr_usd->loginid,
            account_to   => $client_cr_ust->loginid,
            currency     => "USD",
            amount       => $amount
        };

        $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
        is $result->{client_to_loginid}, $client_cr_ust->loginid, 'Transaction successful';

        cmp_ok $client_cr_usd->account->balance, '==', $previous_amount_usd - $amount, 'From account deducted correctly';
        cmp_ok $client_cr_ust->account->balance, '==', $previous_amount_ust + $expected_transfer_amount, 'To account credited correctly';
    };

    subtest 'Correct commission charged for stablecoin crypto -> fiat' => sub {
        my $previous_amount_usd = $client_cr_usd->account->balance;
        my $previous_amount_ust = $client_cr_ust->account->balance;

        my $amount                   = 100;
        my $expected_fee_percent     = $ust_usd_fee;
        my $expected_transfer_amount = ($amount - $amount * $expected_fee_percent / 100);

        $params->{token} = BOM::Database::Model::AccessToken->new->create_token($client_cr_ust->loginid, 'test token');
        $params->{args} = {
            account_from => $client_cr_ust->loginid,
            account_to   => $client_cr_usd->loginid,
            currency     => "UST",
            amount       => $amount
        };

        $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
        is $result->{client_to_loginid}, $client_cr_usd->loginid, 'Transaction successful';

        cmp_ok $client_cr_ust->account->balance, '==', $previous_amount_ust - $amount, 'From account deducted correctly';
        cmp_ok $client_cr_usd->account->balance, '==', $previous_amount_usd + $expected_transfer_amount, 'To account credited correctly';

    };

    subtest 'Minimum commission enforced for stablecoin crypto -> fiat' => sub {
        my $previous_amount_usd = $client_cr_usd->account->balance;
        my $previous_amount_ust = $client_cr_ust->account->balance;

        my $amount                   = 1;
        my $expected_fee_percent     = $ust_usd_fee;
        my $expected_transfer_amount = ($amount - $amount * $expected_fee_percent / 100);

        $params->{token} = BOM::Database::Model::AccessToken->new->create_token($client_cr_ust->loginid, 'test token');
        $params->{args} = {
            account_from => $client_cr_ust->loginid,
            account_to   => $client_cr_usd->loginid,
            currency     => "UST",
            amount       => $amount
        };

        $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
        is $result->{client_to_loginid}, $client_cr_usd->loginid, 'Transaction successful';

        cmp_ok $client_cr_ust->account->balance, '==', $previous_amount_ust - $amount, 'From account deducted correctly';
        cmp_ok $client_cr_usd->account->balance, '==', $previous_amount_usd + $expected_transfer_amount, 'To account credited correctly';
    };

    $mock_fees->unmock_all();
};

subtest 'transfer with no fee' => sub {

    $email            = 'new_transfer_email' . rand(999) . '@sample.com';
    $client_cr_pa_btc = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        binary_user_id => $test_binary_user_id,
        place_of_birth => 'id',
    });

    $client_cr_usd = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        binary_user_id => $test_binary_user_id,
        place_of_birth => 'id',
    });

    $client_cr_pa_usd = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        binary_user_id => $test_binary_user_id,
        place_of_birth => 'id',
    });

    $user->add_client($client_cr_pa_btc);
    $user->add_client($client_cr_usd);
    $user->add_client($client_cr_pa_usd);

    $client_cr_pa_usd->set_default_account('USD');
    $client_cr_usd->set_default_account('USD');
    $client_cr_pa_btc->set_default_account('BTC');

    $client_cr_pa_btc->payment_free_gift(
        currency => 'BTC',
        amount   => 1,
        remark   => 'free gift',
    );

    cmp_ok $client_cr_pa_btc->default_account->balance + 0, '==', 1, 'correct balance';

    $client_cr_pa_usd->payment_free_gift(
        currency => 'USD',
        amount   => 1000,
        remark   => 'free gift',
    );
    cmp_ok $client_cr_pa_usd->default_account->balance + 0, '==', 1000, 'correct balance';

    $client_cr_usd->payment_free_gift(
        currency => 'USD',
        amount   => 1000,
        remark   => 'free gift',
    );
    cmp_ok $client_cr_usd->default_account->balance + 0, '==', 1000, 'correct balance';

    my $pa_args = {
        payment_agent_name    => 'Joe',
        url                   => 'http://www.example.com/',
        email                 => 'joe@example.com',
        phone                 => '+12345678',
        information           => 'Test Info',
        summary               => 'Test Summary',
        commission_deposit    => 0,
        commission_withdrawal => 0,
        is_authenticated      => 't',
        currency_code         => 'BTC',
        target_country        => 'id',
    };

    $client_cr_pa_btc->payment_agent($pa_args);
    $client_cr_pa_btc->save();

    $pa_args->{is_authenticated} = 'f';
    $pa_args->{currency_code}    = 'USD';
    $client_cr_pa_usd->payment_agent($pa_args);
    $client_cr_pa_usd->save();

    my $amount = 0.1;
    $params->{token} = BOM::Database::Model::AccessToken->new->create_token($client_cr_pa_btc->loginid, 'test token');
    $params->{args} = {
        account_from => $client_cr_pa_btc->loginid,
        account_to   => $client_cr_usd->loginid,
        currency     => "BTC",
        amount       => $amount
    };

    my $previous_to_amt = $client_cr_usd->default_account->balance;
    my $previous_fm_amt = $client_cr_pa_btc->default_account->balance;

    my $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{client_to_loginid}, $client_cr_usd->loginid, 'Transaction successful';

    my $fee_percent     = 0;
    my $transfer_amount = ($amount - $amount * $fee_percent / 100) * 4000;
    cmp_ok $client_cr_pa_btc->default_account->balance, '==', $previous_fm_amt - $amount, 'correct balance after transfer excluding fees';
    cmp_ok $client_cr_usd->default_account->balance, '==', $previous_to_amt + $transfer_amount,
        'authorised pa to non-pa transfer (BTC to USD), no fees will be charged';

    sleep(2);
    $params->{args}->{account_to} = $client_cr_pa_usd->loginid;

    $previous_fm_amt = $client_cr_pa_btc->default_account->balance;
    $previous_to_amt = $client_cr_pa_usd->default_account->balance;
    $result          = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{client_to_loginid}, $client_cr_pa_usd->loginid, 'Transaction successful';

    $transfer_amount = ($amount - $amount * $fee_percent / 100) * 4000;
    cmp_ok($client_cr_pa_btc->default_account->balance + 0, '==', ($previous_fm_amt - $amount), 'correct balance after transfer excluding fees');
    cmp_ok $client_cr_pa_usd->default_account->balance + 0, '==', $previous_to_amt + $transfer_amount,
        'authorised pa to unauthrised pa (BTC to USD), one pa is authorised so no transaction fee charged';

    sleep(2);
    $amount = 10;
    $params->{token} = BOM::Database::Model::AccessToken->new->create_token($client_cr_usd->loginid, 'test token');
    $params->{args} = {
        account_from => $client_cr_usd->loginid,
        account_to   => $client_cr_pa_btc->loginid,
        currency     => "USD",
        amount       => $amount
    };

    $previous_to_amt = $client_cr_pa_btc->default_account->balance;
    $previous_fm_amt = $client_cr_usd->default_account->balance;

    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{client_to_loginid}, $client_cr_pa_btc->loginid, 'Transaction successful';

    $fee_percent     = 0;
    $transfer_amount = ($amount - $amount * $fee_percent / 100) / 4000;
    cmp_ok $client_cr_usd->default_account->balance, '==', $previous_fm_amt - $amount, 'correct balance after transfer excluding fees';
    cmp_ok $client_cr_pa_btc->default_account->balance, '==', $previous_to_amt + $transfer_amount,
        'non pa to authorised pa transfer (USD to BTC), no fees will be charged';

};

subtest 'multi currency transfers' => sub {
    $client_cr_eur = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        binary_user_id => $test_binary_user_id,
        place_of_birth => 'id',
    });
    $user->add_client($client_cr_eur);
    $client_cr_eur->set_default_account('EUR');

    $client_cr_eur->payment_free_gift(
        currency => 'EUR',
        amount   => 1000,
        remark   => 'free gift',
    );

    $params->{token} = BOM::Database::Model::AccessToken->new->create_token($client_cr_eur->loginid, 'test token');
    $params->{args} = {
        account_from => $client_cr_eur->loginid,
        account_to   => $client_cr_usd->loginid,
        currency     => "EUR",
        amount       => 10
    };

    my $result =
        $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', "fiat->fiat not allowed - correct error code")
        ->error_message_is('Account transfers are not available for accounts with different currencies.',
        'fiat->fiat not allowed - correct error message');

    $params->{args}->{account_to} = $client_cr_btc->loginid;

    # currency conversion is always via USD, so EUR->BTC needs to use the EUR->USD pair
    $redis->hmset(
        'exchange_rates::EUR_USD',
        quote => 1.1,
        epoch => time
    );

    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{client_to_loginid}, $client_cr_btc->loginid, 'fiat->cryto allowed';

    sleep 2;
    $redis->hmset(
        'exchange_rates::EUR_USD',
        quote => 1.1,
        epoch => time - 3595
    );
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{client_to_loginid}, $client_cr_btc->loginid, 'fiat->cryto allowed with a slightly old rate (<1 hour)';

    sleep 2;
    $redis->hmset(
        'exchange_rates::EUR_USD',
        quote => 1.1,
        epoch => time - 3605
    );
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError',
        "fiat->cryto when rate older than 1 hour - correct error code")
        ->error_message_is('Sorry, transfers are currently unavailable. Please try again later.',
        'fiat->cryto when rate older than 1 hour - correct error message');

    BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->between_accounts(2);
    $redis->hmset(
        'exchange_rates::EUR_USD',
        quote => 1.1,
        epoch => time
    );
    $result =
        $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', "Daily Transfer limit - correct error code")
        ->error_message_is('Maximum of 2 transfers allowed per day.', 'Daily Transfer Limit - correct error message');
};

subtest 'suspended currency transfers' => sub {

    $user = BOM::User->create(
        email          => $email,
        password       => BOM::User::Password::hashpw('jskjd8292922'),
        email_verified => 1,
    );

    my $client_cr_btc = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        place_of_birth => 'id',
    });
    $client_cr_btc->set_default_account('BTC');
    $client_cr_btc->payment_free_gift(
        currency => 'BTC',
        amount   => 10,
        remark   => 'free gift',
    );

    my $client_cr_usd = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        place_of_birth => 'id',
    });
    $client_cr_usd->set_default_account('USD');
    $client_cr_usd->payment_free_gift(
        currency => 'USD',
        amount   => 1000,
        remark   => 'free gift',
    );

    my $client_mf_eur = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'MF'});
    $client_mf_eur->set_default_account('EUR');
    $client_mf_eur->payment_free_gift(
        currency => 'EUR',
        amount   => 1000,
        remark   => 'free gift',
    );

    my $client_mlt_eur = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'MLT'});
    $client_mlt_eur->set_default_account('EUR');

    $user->add_client($client_cr_btc);
    $user->add_client($client_cr_usd);
    $user->add_client($client_mf_eur);
    $user->add_client($client_mlt_eur);

    my $token_cr_usd = BOM::Database::Model::AccessToken->new->create_token($client_cr_usd->loginid, 'test token');
    my $token_cr_btc = BOM::Database::Model::AccessToken->new->create_token($client_cr_btc->loginid, 'test token');
    my $token_mf_eur = BOM::Database::Model::AccessToken->new->create_token($client_mf_eur->loginid, 'test token');

    subtest 'it should stop transfers to suspended currency' => sub {
        $params->{token} = $token_cr_usd;
        $params->{args}  = {
            account_from => $client_cr_usd->loginid,
            account_to   => $client_cr_btc->loginid,
            currency     => "USD",
            amount       => 10
        };
        BOM::Config::Runtime->instance->app_config->system->suspend->transfer_currencies(['BTC']);
        my $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError',
            "Transfer to suspended currency not allowed - correct error code")
            ->error_message_is('Account transfers are not available between USD and BTC',
            'Transfer to suspended currency not allowed - correct error message');
    };

    subtest 'it should stop transfers from suspended currency' => sub {
        $params->{token} = $token_cr_btc;
        $params->{args}  = {
            account_from => $client_cr_btc->loginid,
            account_to   => $client_cr_usd->loginid,
            currency     => "BTC",
            amount       => 1
        };

        my $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError',
            "Transfer from suspended currency not allowed - correct error code")
            ->error_message_is('Account transfers are not available between BTC and USD',
            'Transfer from suspended currency not allowed - correct error message');
    };

    subtest 'it should not stop transfer between the same currncy' => sub {
        $params->{token} = $token_mf_eur;
        BOM::Config::Runtime->instance->app_config->system->suspend->transfer_currencies(['EUR']);
        $params->{args} = {
            account_from => $client_mf_eur->loginid,
            account_to   => $client_mlt_eur->loginid,
            currency     => "EUR",
            amount       => 10
        };

        $rpc_ct->call_ok($method, $params);
    };

    # reset the config
    BOM::Config::Runtime->instance->app_config->system->suspend->transfer_currencies([]);
};

subtest 'MT5' => sub {

    @BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');
    my $mt5_mgr_suspend = BOM::Config::Runtime->instance->app_config->system->suspend->mt5_manager_api;
    BOM::Config::Runtime->instance->app_config->system->suspend->mt5_manager_api(1);
    my $mock_account = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $mock_account->mock(
        _is_financial_assessment_complete => sub { return 1 },
        _throttle                         => sub { return 0 });
    my $mock_client = Test::MockModule->new('BOM::User::Client');
    $mock_client->mock(fully_authenticated => sub { return 1 });

    $email = 'mt5_user_for_transfer@test.com';

    # Mocked MT5 account details
    # %ACCOUNTS and %DETAILS are shared between four files, and should be kept in-sync to avoid test failures
    #   t/BOM/RPC/30_mt5.t
    #   t/BOM/RPC/05_accounts.t
    #   t/BOM/RPC/Cashier/20_transfer_between_accounts.t
    #   t/lib/mock_binary_mt5.pl

    my %ACCOUNTS = (
        'demo\vanuatu_standard'         => '00000001',
        'demo\vanuatu_advanced'         => '00000002',
        'demo\labuan_standard'          => '00000003',
        'demo\labuan_advanced'          => '00000004',
        'real\malta'                    => '00000010',
        'real\maltainvest_standard'     => '00000011',
        'real\maltainvest_standard_GBP' => '00000012',
        'real\svg'                      => '00000013',
        'real\vanuatu_standard'         => '00000014',
        'real\labuan_advanced'          => '00000015',
    );

    my %DETAILS = (
        password       => 'Efgh4567',
        investPassword => 'Abcd1234',
        name           => 'Meta traderman',
        balance        => '1234',
    );

    $user = BOM::User->create(
        email          => $email,
        password       => $DETAILS{password},
        email_verified => 1
    );

    my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        place_of_birth => 'id'
    });

    $test_client->set_default_account('USD');
    $test_client->payment_free_gift(
        currency => 'USD',
        amount   => 1000,
        remark   => 'free gift',
    );

    $test_client->status->set('crs_tin_information', 'system', 'testing something');

    my $test_client_btc = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        place_of_birth => 'id'
    });

    $test_client_btc->set_default_account('BTC');
    $test_client_btc->payment_free_gift(
        currency => 'USD',
        amount   => 10,
        remark   => 'free gift',
    );

    $test_client_btc->status->set('crs_tin_information', 'system', 'testing something');

    $user->add_client($test_client);
    $user->add_client($test_client_btc);

    my $token = BOM::Database::Model::AccessToken->new->create_token($test_client->loginid, 'test token');

    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type     => 'demo',
            mt5_account_type => 'standard',
            investPassword   => $DETAILS{investPassword},
            mainPassword     => $DETAILS{password},
        },
    };
    $rpc_ct->call_ok('mt5_new_account', $params)->has_no_error('no error for demo mt5_new_account');

    $params->{args}{account_type}     = 'financial';
    $params->{args}{mt5_account_type} = 'standard';
    $rpc_ct->call_ok('mt5_new_account', $params)->has_no_error('no error for standard mt5_new_account');

    $params->{args}{account_type}     = 'financial';
    $params->{args}{mt5_account_type} = 'advanced';
    $rpc_ct->call_ok('mt5_new_account', $params)->has_no_error('no error for advanced mt5_new_account');

    $params->{args} = {};
    $rpc_ct->call_ok($method, $params)->has_no_error("no error for $method with no params");

    my @accounts = map { $_->{loginid} } @{$rpc_ct->result->{accounts}};
    cmp_bag(
        $rpc_ct->result->{accounts},
        [{
                loginid  => $test_client->loginid,
                balance  => num(1000),
                currency => 'USD'
            },
            {
                loginid  => $test_client_btc->loginid,
                balance  => num(10),
                currency => 'BTC'
            },
            {
                loginid  => 'MT' . $ACCOUNTS{'real\vanuatu_standard'},
                balance  => $DETAILS{balance},
                currency => 'USD'
            },
            {
                loginid  => 'MT' . $ACCOUNTS{'real\labuan_advanced'},
                balance  => $DETAILS{balance},
                currency => 'USD'
            },
        ],
        "all real money accounts by empty $method call"
    );

    $params->{args} = {
        account_from => 'MT' . $ACCOUNTS{'real\vanuatu_standard'},
        account_to   => 'MT' . $ACCOUNTS{'real\labuan_advanced'},
        currency     => "USD",
        amount       => 180                                          # this is the only deposit amount allowed by mock MT5
    };
    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', 'MT5->MT5 transfer error code')
        ->error_message_is('Transfer between two MT5 accounts is not allowed.', 'MT5->MT5 transfer error message');

    $params->{args}{account_from} = 'MT' . $ACCOUNTS{'demo\vanuatu_standard'};
    $params->{args}{account_to}   = $test_client->loginid;
    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', 'MT5 demo -> real account transfer error code')
        ->error_message_is('Transfers between accounts are not available for your account.', 'MT5 demo -> real account transfer error message');

    # real -> MT5
    $params->{args}{account_from} = $test_client->loginid;
    $params->{args}{account_to}   = 'MT' . $ACCOUNTS{'real\vanuatu_standard'};
    $rpc_ct->call_ok($method, $params)->has_no_error("Real account -> real MT5 ok");
    cmp_deeply(
        $rpc_ct->result,
        {
            status              => 1,
            transaction_id      => ignore(),
            client_to_full_name => $DETAILS{name},
            client_to_loginid   => $params->{args}{account_to},
            stash               => ignore()
        },
        'expected data in result'
    );
    cmp_ok $test_client->default_account->balance, '==', 820, 'real money account balance decreased';

    # MT5 -> real
    $params->{args}{account_from} = 'MT' . $ACCOUNTS{'real\vanuatu_standard'};
    $params->{args}{account_to}   = $test_client->loginid;
    $params->{args}{amount}       = 150;                                         # this is the only withdrawal amount allowed by mock MT5
    $rpc_ct->call_ok($method, $params)->has_no_error("Real MT5 -> real account ok");
    cmp_deeply(
        $rpc_ct->result,
        {
            status              => 1,
            transaction_id      => ignore(),
            client_to_full_name => $test_client->full_name,
            client_to_loginid   => $params->{args}{account_to},
            stash               => ignore()
        },
        'expected data in result'
    );
    cmp_ok $test_client->default_account->balance, '==', 970, 'real money account balance increased';

    {
        $mock_client->mock(fully_authenticated => sub { return 0 });
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', 'Correct error code')
            ->error_message_is('There was an error processing the request. Please authenticate your account.',
            'Error message returned from inner MT5 sub');
    }

    $params->{args}{account_from} = $test_client_btc->loginid;
    $params->{args}{account_to}   = 'MT' . $ACCOUNTS{'real\vanuatu_standard'};
    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', 'Correct error code')
        ->error_message_is('From account provided should be same as current authorized client.', 'Account from must be authenticated account');

    $params->{args}{account_from}   = 'MT' . $ACCOUNTS{'real\vanuatu_standard'};
    $params->{args}{account_to} = $test_client_btc->loginid;
    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', 'Correct error code')
        ->error_message_is('To account provided should be same as current authorized client.', 'To from must be authenticated account');

    $params->{args}{account_from} = $test_client->loginid;
    $params->{args}{account_to}   = 'MT' . $ACCOUNTS{'real\vanuatu_standard'};
    $params->{args}{currency}     = 'EUR';
    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', 'Correct error code')
        ->error_message_is('Currency provided is different from account currency.', 'Correct message for wrong currency for real account_from');

    $params->{args}{account_from} = 'MT' . $ACCOUNTS{'real\vanuatu_standard'};
    $params->{args}{account_to}   = $test_client->loginid;
    $params->{args}{curency}      = 'EUR';
    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', 'Correct error code')
        ->error_message_is('Currency provided is different from account currency.', 'Correct message for wrong currency for MT5 account_from');

    # restore config
    BOM::Config::Runtime->instance->app_config->system->suspend->mt5_manager_api($mt5_mgr_suspend);
};

done_testing();
