use strict;
use warnings;

use Test::Most;
use Test::Mojo;
use Test::MockModule;
use Test::FailWarnings;
use Test::Warn;

use MojoX::JSON::RPC::Client;
use POSIX qw/ ceil /;
use Postgres::FeedDB::CurrencyConverter qw(in_USD amount_from_to_currency);

use Client::Account;

use BOM::Test::RPC::Client;
use BOM::Test::Data::Utility::UnitTestDatabase;
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Platform::Token;

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

my ($method, $email, $client_vr, $client_cr, $client_cr1, $client_mlt, $client_mf, $user, $token) = ('transfer_between_accounts');

my $mocked_CurrencyConverter = Test::MockModule->new('Postgres::FeedDB::CurrencyConverter');
$mocked_CurrencyConverter->mock(
    'in_USD',
    sub {
        my $price         = shift;
        my $from_currency = shift;

        $from_currency eq 'BTC' and return 4000 * $price;
        $from_currency eq 'USD' and return 1 * $price;

        return 0;
    });

subtest 'call params validation' => sub {
    $email = 'dummy' . rand(999) . '@binary.com';

    $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
        email       => $email
    });

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

    $token = BOM::Database::Model::AccessToken->new->create_token($client_cr->loginid, 'test token');
    $params->{token} = $token;

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

    $client_cr->set_status('cashier_locked', 'system', 'testing something');
    $client_cr->save;

    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'TransferBetweenAccountsError', 'Correct error code for cashier locked';
    is $result->{error}->{message_to_client}, 'You cannot perform this action, as your account is cashier locked.',
        'Correct error message for cashier locked';

    $client_cr->clr_status('cashier_locked');
    $client_cr->set_status('withdrawal_locked', 'system', 'testing something');
    $client_cr->save;

    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'TransferBetweenAccountsError', 'Correct error code for withdrawal locked';
    is $result->{error}->{message_to_client}, 'You cannot perform this action, as your account is withdrawal locked.',
        'Correct error message for withdrawal locked';

    $client_cr->clr_status('withdrawal_locked');
    $client_cr->save;
};

subtest 'validation' => sub {
    # random loginid to make it fail
    $params->{token} = $token;
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

    $params->{token} = BOM::Database::Model::AccessToken->new->create_token($client_mlt->loginid, 'test token');

    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'TransferBetweenAccountsError', 'Correct error code if from and to are same';
    is $result->{error}->{message_to_client}, 'Account transfer is not available within same account.',
        'Correct error message if from and to are same';

    $params->{token} = BOM::Database::Model::AccessToken->new->create_token($client_cr->loginid, 'test token');
    $params->{args}->{account_from} = $client_cr->loginid;

    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'TransferBetweenAccountsError', 'Correct error code';
    is $result->{error}->{message_to_client}, 'Account transfer is not available for your account.',
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
        ->error_message_is('Account transfer is not available for accounts with different currency.', 'Different currency error message');

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

    $params->{args}->{amount} = 0.0002;
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'TransferBetweenAccountsError', 'Correct error code crypto to crypto';
    like $result->{error}->{message_to_client},
        qr/Provided amount is not within permissible limits. Minimum transfer amount for provided currency is/,
        'Correct error message for invalid amount';

    $params->{args}->{amount} = 0.500000001;
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'TransferBetweenAccountsError', 'Correct error code for invalid amount';
    like $result->{error}->{message_to_client},
        qr/Invalid amount. Amount provided can not have more than/,
        'Correct error message for amount with decimal places more than allowed per currency';

    $params->{args}->{amount} = 0.002;
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
            "amount"       => 10,
        };
        $params->{token} = BOM::Database::Model::AccessToken->new->create_token($client_mlt->loginid, 'test token');
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
    };
};

subtest 'transfer with fees' => sub {
    $email     = 'new_transfer_email' . rand(999) . '@sample.com';
    $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email
    });

    $client_cr1 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email
    });

    $client_cr->set_default_account('USD');
    $client_cr1->set_default_account('BTC');

    $user = BOM::Platform::User->create(
        email    => $email,
        password => BOM::Platform::Password::hashpw('jskjd8292922'));
    $user->email_verified(1);

    $user->add_loginid({loginid => $client_cr->loginid});
    $user->add_loginid({loginid => $client_cr1->loginid});
    $user->save;

    $client_cr->payment_free_gift(
        currency => 'USD',
        amount   => 1000,
        remark   => 'free gift',
    );
    cmp_ok $client_cr->default_account->load->balance, '==', 1000, 'correct balance';

    $client_cr1->payment_free_gift(
        currency => 'BTC',
        amount   => 1,
        remark   => 'free gift',
    );
    cmp_ok $client_cr1->default_account->load->balance, '==', 1, 'correct balance';

    $params->{token} = BOM::Database::Model::AccessToken->new->create_token($client_cr->loginid, 'test token omnibus');
    my $amount = 10;
    $params->{args} = {
        "account_from" => $client_cr->loginid,
        "account_to"   => $client_cr1->loginid,
        "currency"     => "USD",
        "amount"       => $amount
    };
    my $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{client_to_loginid}, $client_cr1->loginid, 'Transaction successful';

    # fiat to crypto to is 1% and exchange rate is 4000 for BTC
    my $transfer_amount = ($amount - $amount * 1 / 100) / 4000;
    my $current_balance = $client_cr1->default_account->load->balance;
    cmp_ok $current_balance, '==', 1 + $transfer_amount, 'correct balance after transfer including fees';
    cmp_ok $client_cr->default_account->load->balance, '==', 1000 - $amount, 'correct balance, exact amount deducted';

    $params->{token} = BOM::Database::Model::AccessToken->new->create_token($client_cr1->loginid, 'test token omnibus');
    $amount          = 0.1;
    $params->{args}  = {
        "account_from" => $client_cr1->loginid,
        "account_to"   => $client_cr->loginid,
        "currency"     => "BTC",
        "amount"       => $amount
    };
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{client_to_loginid}, $client_cr->loginid, 'Transaction successful';

    $transfer_amount = ($amount - $amount * 0.5 / 100) * 4000;
    cmp_ok $client_cr->default_account->load->balance, '==', 990 + $transfer_amount, 'correct balance after transfer including fees';
    cmp_ok $client_cr1->default_account->load->balance, '==', $current_balance - $amount, 'correct balance after transfer including fees';
};

subtest 'paymentagent transfer' => sub {
    $email     = 'new_pa_email' . rand(999) . '@sample.com';
    $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email
    });

    $client_cr1 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email
    });

    $client_cr->set_default_account('BTC');
    $client_cr->payment_agent({
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
        currency_code_2       => 'BTC',
        target_country        => 'id',
    });
    $client_cr->save;

    $client_cr1->set_default_account('USD');

    $user = BOM::Platform::User->create(
        email    => $email,
        password => BOM::Platform::Password::hashpw('jskjd8292922'));
    $user->email_verified(1);

    $user->add_loginid({loginid => $client_cr->loginid});
    $user->add_loginid({loginid => $client_cr1->loginid});
    $user->save;

    $client_cr->payment_free_gift(
        currency => 'BTC',
        amount   => 1,
        remark   => 'free gift',
    );
    cmp_ok $client_cr->default_account->load->balance, '==', 1, 'correct balance';

    $client_cr1->payment_free_gift(
        currency => 'USD',
        amount   => 1000,
        remark   => 'free gift',
    );
    cmp_ok $client_cr1->default_account->load->balance, '==', 1000, 'correct balance';

    my $amount = 0.1;
    $params->{token} = BOM::Database::Model::AccessToken->new->create_token($client_cr->loginid, 'test token omnibus');
    $params->{args} = {
        "account_from" => $client_cr->loginid,
        "account_to"   => $client_cr1->loginid,
        "currency"     => "BTC",
        "amount"       => $amount
    };
    my $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{client_to_loginid}, $client_cr1->loginid, 'Transaction successful';

    my $transfer_amount = ($amount - $amount * 0.5 / 100) * 4000;
    cmp_ok $client_cr->default_account->load->balance, '==', 1 - $amount, 'correct balance after transfer including fees';
    my $current_balance = $client_cr1->default_account->load->balance;
    cmp_ok $current_balance, '==', 1000 + $transfer_amount, 'correct balance after transfer including fees as payment agent is not authenticated';

    # database function throw error if same transaction happens
    # in 2 seconds
    sleep(2);

    $client_cr->payment_agent({
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
        currency_code_2       => 'BTC',
        target_country        => 'id',
    });
    $client_cr->save;

    $params->{args}->{account_from} = $client_cr->loginid;
    $params->{args}->{account_to}   = $client_cr1->loginid;
    $params->{token} = BOM::Database::Model::AccessToken->new->create_token($client_cr->loginid, 'test token omnibus');

    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is $result->{client_to_loginid}, $client_cr1->loginid, 'Transaction successful';

    $transfer_amount = ($amount - $amount * 0 / 100) * 4000;
    cmp_ok $client_cr->default_account->load->balance, '==', 0.9 - $amount, 'correct balance after transfer including fees';
    cmp_ok $client_cr1->default_account->load->balance, '==', $current_balance + $transfer_amount,
        'correct balance after transfer excluding fees as payment agent is authenticated';
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
