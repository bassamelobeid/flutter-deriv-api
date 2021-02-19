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
use Format::Util::Numbers qw/financialrounding get_min_unit formatnumber/;
use JSON::MaybeUTF8;

use BOM::User::Client;
use BOM::RPC::v3::MT5::Account;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::RPC::QueueClient;
use BOM::Test::Helper::ExchangeRates qw/populate_exchange_rates populate_exchange_rates_db/;
use BOM::Platform::Token;
use Email::Stuffer::TestLinks;
use BOM::Config::Redis;
use BOM::Config::Runtime;
use BOM::Config::CurrencyConfig;
use Test::BOM::RPC::Accounts;

use utf8;

my $test_binary_user_id = 65000;
my $rpc_ct;

my $redis = BOM::Config::Redis::redis_exchangerates_write();

sub _offer_to_clients {
    my $value         = shift;
    my $from_currency = shift;
    my $to_currency   = shift // 'USD';

    $redis->hmset("exchange_rates::${from_currency}_${to_currency}", offer_to_clients => $value);
}
_offer_to_clients(1, $_) for qw/BTC USD ETH UST EUR/;

# In the weekend the account transfers will be suspended. So we mock a valid day here
set_absolute_time(Date::Utility->new('2018-02-15')->epoch);
scope_guard { restore_time() };

# unlimit daily transfer
BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->between_accounts(999);
BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->MT5(999);

my $emit_data;
my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_events->mock(
    'emit',
    sub {
        my ($type, $data) = @_;
        $emit_data->{$type}{count}++;
        $emit_data->{$type}{last} = $data;
    });

subtest 'Initialization' => sub {
    lives_ok {
        $rpc_ct = BOM::Test::RPC::QueueClient->new();
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

my $btc_usd_rate = 4000;
my $custom_rates = {
    'BTC' => $btc_usd_rate,
    'UST' => 1,
    'USD' => 1,
    'EUR' => 1.1888,
    'GBP' => 1.3333,
    'JPY' => 0.0089,
    'AUD' => 1,
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

    $token                = BOM::Platform::Token::API->new->create_token($client_cr->loginid, _get_unique_display_name());
    $params->{token}      = $token;
    $params->{token_type} = 'oauth_token';
    my $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is @{$result->{accounts}}, 3, 'if no loginid from or to passed then it returns accounts';

    $params->{args} = {
        account_from => $client_cr->loginid,
        account_to   => $client_mlt->loginid,
    };

    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{error}->{code},              'TransferBetweenAccountsError',   'Correct error code for no currency';
    is $result->{error}->{message_to_client}, 'Please provide valid currency.', 'Correct error message for no currency';

    $params->{args}->{currency} = 'EUR';

    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{error}->{code},              'TransferBetweenAccountsError', 'Correct error code for invalid amount';
    is $result->{error}->{message_to_client}, 'Please provide valid amount.', 'Correct error message for invalid amount';

    $params->{args}->{amount} = 'NA';

    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{error}->{code},              'TransferBetweenAccountsError', 'Correct error code for invalid amount';
    is $result->{error}->{message_to_client}, 'Please provide valid amount.', 'Correct error message for invalid amount';

    $params->{args}->{amount}   = 1;
    $params->{args}->{currency} = 'XXX';
    $result                     = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{error}->{code},              'TransferBetweenAccountsError',   'Correct error code for invalid currency';
    is $result->{error}->{message_to_client}, 'Please provide valid currency.', 'Correct error message for invalid amount';

    $params->{args}->{currency}     = 'EUR';
    $params->{args}->{account_from} = $client_vr->loginid;

    $params->{token} = BOM::Platform::Token::API->new->create_token($client_vr->loginid, _get_unique_display_name());

    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{error}->{code},              'PermissionDenied',   'Correct error code for virtual account';
    is $result->{error}->{message_to_client}, 'Permission denied.', 'Correct error message for virtual account';

    $params->{token} = $token;
    $params->{args}->{account_from} = $client_cr->loginid;

    $client_cr->status->set('cashier_locked', 'system', 'testing something');

    $rpc_ct->call_ok('transfer_between_accounts', $params)
        ->has_no_system_error->error_code_is('TransferBetweenAccountsError', 'Correct error code for cashier locked')
        ->error_message_like(qr/cashier is locked/, 'Correct error message for cashier locked');

    $client_cr->status->clear_cashier_locked;
    $client_cr->status->set('withdrawal_locked', 'system', 'testing something');

    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'TransferBetweenAccountsError', 'Correct error code for withdrawal locked';
    is $result->{error}->{message_to_client}, 'You cannot perform this action, as your account is withdrawal locked.',
        'Correct error message for withdrawal locked';

    $client_cr->status->clear_withdrawal_locked;
};

subtest 'validation' => sub {

    #populate exchange reates for BOM::TEST redis server to be used on validation_transfer_between_accounts

    # random loginid to make it fail
    $params->{token} = $token;
    $params->{args}->{account_from} = 'CR123';
    my $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{error}->{code},              'PermissionDenied',   'Correct error code for loginid that does not exists';
    is $result->{error}->{message_to_client}, 'Permission denied.', 'Correct error message for loginid that does not exists';

    $cr_dummy = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email
    });

    # send loginid that is not linked to used
    $params->{args}->{account_from} = $cr_dummy->loginid;

    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{error}->{code},              'PermissionDenied',   'Correct error code for loginid not in siblings';
    is $result->{error}->{message_to_client}, 'Permission denied.', 'Correct error message for loginid not in siblings';

    $params->{args}->{account_from} = $client_mlt->loginid;
    $params->{args}->{account_to}   = $client_mlt->loginid;

    $params->{token} = BOM::Platform::Token::API->new->create_token($client_mlt->loginid, _get_unique_display_name());

    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'TransferBetweenAccountsError', 'Correct error code if from and to are same';
    is $result->{error}->{message_to_client}, 'Account transfers are not available within same account.',
        'Correct error message if from and to are same';

    $params->{token} = BOM::Platform::Token::API->new->create_token($client_cr->loginid, _get_unique_display_name());
    $params->{args}->{account_from} = $client_cr->loginid;

    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'TransferBetweenAccountsError', 'Correct error code';
    is $result->{error}->{message_to_client}, 'Transfers between accounts are not available for your account.',
        'Correct error message for different landing companies';

    $params->{args}->{account_from} = $client_mf->loginid;

    $params->{token} = BOM::Platform::Token::API->new->create_token($client_mf->loginid, _get_unique_display_name());
    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{error}->{code},              'TransferBetweenAccountsError',    'Correct error code for no default currency';
    is $result->{error}->{message_to_client}, 'Please deposit to your account.', 'Correct error message for no default currency';

    $client_mf->set_default_account('EUR');

    $params->{args}->{currency} = 'BTC';

    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'TransferBetweenAccountsError', 'Correct error code for invalid currency for landing company';
    is $result->{error}->{message_to_client}, 'Currency provided is not valid for your account.',
        'Correct error message for invalid currency for landing company';

    $params->{args}->{currency} = 'USD';

    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{error}->{code},              'TransferBetweenAccountsError',                          'Correct error code';
    is $result->{error}->{message_to_client}, 'Currency provided is different from account currency.', 'Correct error message';

    $params->{args}->{currency} = 'EUR';

    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'TransferBetweenAccountsError', 'Correct error code';
    is $result->{error}->{message_to_client}, 'Please set the currency for your existing account ' . $client_mlt->loginid . '.',
        'Correct error message';

    $client_mlt->set_default_account('USD');

    $params->{token} = BOM::Platform::Token::API->new->create_token($client_mf->loginid, _get_unique_display_name());
    $params->{args}->{account_from} = $client_mf->loginid;
    $rpc_ct->call_ok('transfer_between_accounts', $params)
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

    $params->{token}                = BOM::Platform::Token::API->new->create_token($client_cr->loginid, _get_unique_display_name());
    $params->{args}->{currency}     = 'BTC';
    $params->{args}->{account_from} = $client_cr->loginid;
    $params->{args}->{account_to}   = $cr_dummy->loginid;

    $params->{args}->{amount} = 0.400000001;

    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'TransferBetweenAccountsError', 'Correct error code for invalid amount';
    like $result->{error}->{message_to_client},
        qr/Invalid amount. Amount provided can not have more than/,
        'Correct error message for amount with decimal places more than allowed per currency';

    $params->{args}->{amount} = 0.02;
    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
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

    $params->{token}                = BOM::Platform::Token::API->new->create_token($client_cr->loginid, _get_unique_display_name());
    $params->{args}->{currency}     = 'USD';
    $params->{args}->{account_from} = $client_cr->loginid;
    $params->{args}->{account_to}   = $cr_dummy->loginid;

    my $limits = BOM::Config::CurrencyConfig::transfer_between_accounts_limits();
    $params->{args}->{amount} = $limits->{USD}->{min} - get_min_unit('USD');
    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;

    is $result->{error}->{code}, 'TransferBetweenAccountsError', 'Correct error code crypto to crypto';
    like $result->{error}->{message_to_client},
        qr/Provided amount is not within permissible limits. Minimum transfer amount for USD currency is $limits->{USD}->{min}/,
        'Correct error message for a value less than minimum limit';

    $params->{args}->{amount} = $limits->{USD}->{min};
    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    like $result->{error}->{message_to_client}, qr/The maximum amount you may transfer is: USD 0.00/, 'Correct error message for an empty account';

    $client_cr->payment_free_gift(
        currency       => 'USD',
        amount         => $limits->{USD}->{min},
        remark         => 'free gift',
        place_of_birth => 'id',
    );

    $params->{args}->{amount} = $limits->{USD}->{min};
    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_no_error->result;

    $params->{args}->{amount} = 10;
    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{error}->{code},                'TransferBetweenAccountsError',                       'Correct error code insufficient balance';
    like $result->{error}->{message_to_client}, qr/The maximum amount you may transfer is: USD 0.00/, 'Correct error message for an empty account';

    $client_cr->payment_free_gift(
        currency       => 'USD',
        amount         => $limits->{USD}->{max} + $limits->{USD}->{min},
        remark         => 'free gift',
        place_of_birth => 'id',
    );

    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_no_error->result;

    cmp_deeply(
        _get_transaction_details($client_cr, $result->{transaction_id}),
        {
            from_login                => $client_cr->loginid,
            to_login                  => $cr_dummy->loginid,
            fees                      => num(0.1),
            fee_calculated_by_percent => num(0.1),
            fees_currency             => 'USD',
            fees_percent              => num(1),
            min_fee                   => num(0.01),
        },
        'metadata saved correctly in transaction_details table'
    );

    # set an invalid value to minimum
    my $invalid_min = 0.01;
    my $mock_fees   = Test::MockModule->new('BOM::Config::CurrencyConfig', no_auto => 1);
    $mock_fees->mock(
        transfer_between_accounts_limits => sub {
            my $force_refresh = shift;
            my $limits        = $mock_fees->original('transfer_between_accounts_limits')->($force_refresh);
            #fetching fake limits conditionally
            unless ($force_refresh) {
                $limits->{USD}->{min} = $invalid_min;
            }
            return $limits;
        });
    $params->{args}->{amount} = $invalid_min;

    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    my $elevated_minimum = formatnumber('amount', 'USD', BOM::Config::CurrencyConfig::transfer_between_accounts_limits(1)->{USD}->{min});
    cmp_ok $elevated_minimum, '>', $invalid_min, 'Transfer minimum is automatically elevated to the lower bound';
    is $result->{error}->{code}, 'TransferBetweenAccountsError', 'Correct error code crypto to crypto';
    like $result->{error}->{message_to_client},
        qr/This amount is too low. Please enter a minimum of $elevated_minimum USD./,
        'A different error message containing the elevated (lower bound) minimum value included.';
    $mock_fees->unmock_all;
};

subtest 'Validation for transfer from incomplete account' => sub {
    $email = 'new_email' . rand(999) . '@binary.com';
    my $client_cr1 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        place_of_birth => 'ID',
        address_city   => '',
    });

    my $client_cr2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        place_of_birth => 'ID',
    });

    $user = BOM::User->create(
        email          => $email,
        password       => BOM::User::Password::hashpw('hello'),
        email_verified => 1,
    );

    for ($client_cr1, $client_cr2) {
        $user->add_client($_);
        $_->set_default_account('USD');
    }

    $client_cr1->payment_free_gift(
        currency => 'EUR',
        amount   => 1000,
        remark   => 'free gift',
    );

    $params->{token}      = BOM::Platform::Token::API->new->create_token($client_cr1->loginid, 'test token');
    $params->{token_type} = 'oauth_token';
    $params->{args}       = {
        account_from => $client_cr1->loginid,
        account_to   => $client_cr2->loginid,
        currency     => 'USD',
        amount       => 10
    };

    $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_error->error_code_is('ASK_FIX_DETAILS', 'Error code is correct')
        ->error_message_is('Your profile appears to be incomplete. Please update your personal details to continue.',
        'Error msg for client is correct')->error_details_is({fields => ['address_city']}, 'Error details is correct');

    $client_cr1->address_city('Test City');
    $client_cr1->address_line_1('');
    $client_cr1->save;
    $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_error->error_code_is('ASK_FIX_DETAILS', 'Error code is correct')
        ->error_message_is('Your profile appears to be incomplete. Please update your personal details to continue.',
        'Error msg for client is correct')->error_details_is({fields => ['address_line_1']}, 'Error details is correct');

    $client_cr1->address_city('');
    $client_cr1->address_line_1('');
    $client_cr1->save;
    $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_error->error_code_is('ASK_FIX_DETAILS', 'Error code is correct')
        ->error_message_is('Your profile appears to be incomplete. Please update your personal details to continue.',
        'Error msg for client is correct')->error_details_is({fields => ['address_city', 'address_line_1']}, 'Error details is correct');

};

subtest 'transfer_between_accounts' => sub {
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
        $params->{token} = BOM::Platform::Token::API->new->create_token($client_mlt->loginid, _get_unique_display_name());
        $params->{args}  = {
            account_from => $client_mlt->loginid,
            account_to   => $client_mf->loginid,
            currency     => "EUR",
            amount       => 100
        };

        $rpc_ct->call_ok('transfer_between_accounts', $params)
            ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', 'Transfer error as no deposit done')
            ->error_message_is('Please deposit to your account.', 'Please deposit before transfer.');

        $client_mf->set_default_account('EUR');
        $client_mlt->set_default_account('EUR');

        # some random clients
        $params->{args}->{account_to} = 'MLT999999';
        $rpc_ct->call_ok('transfer_between_accounts', $params)
            ->has_no_system_error->has_error->error_code_is('PermissionDenied', 'Transfer error as wrong to client')
            ->error_message_is('Permission denied.', 'Correct error message for transfering to random client');

        $params->{args}->{account_to} = $client_mf->loginid;
        $rpc_ct->call_ok('transfer_between_accounts', $params)
            ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', 'Transfer error as no money in account')
            ->error_message_is('The maximum amount you may transfer is: EUR 0.00.', 'Correct error message for account with no money');

        $params->{args}->{amount} = -1;
        $rpc_ct->call_ok('transfer_between_accounts', $params)
            ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', "Invalid amount")
            ->error_message_is('Please provide valid amount.', 'Correct error message for transfering invalid amount');

        $params->{args}->{amount} = 0;
        $rpc_ct->call_ok('transfer_between_accounts', $params)
            ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', "Invalid amount")
            ->error_message_is('Please provide valid amount.', 'Correct error message for transfering invalid amount');

        $params->{args}->{amount} = 1;
        $rpc_ct->call_ok('transfer_between_accounts', $params)
            ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', "Invalid amount")
            ->error_message_is('The maximum amount you may transfer is: EUR 0.00.', 'Correct error message for transfering invalid amount');
    };

    subtest 'Transfer between mlt and mf' => sub {
        $params->{args} = {};
        my $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
        is scalar(@{$result->{accounts}}), 2, 'two accounts';
        my ($tmp) = grep { $_->{loginid} eq $client_mlt->loginid } @{$result->{accounts}};
        is $tmp->{balance}, "0.00", 'balance is 0';

        $client_mlt->payment_free_gift(
            currency => 'EUR',
            amount   => 5000,
            remark   => 'free gift',
        );

        $client_mlt->status->clear_cashier_locked;    # clear locked

        $client_mf->set_authentication('ID_DOCUMENT', {status => 'pass'});
        $client_mf->status->set('financial_risk_approval', 'system', 'Accepted approval');
        $client_mf->tax_residence('de');
        $client_mf->tax_identification_number('111-222-333');
        $client_mf->save;

        $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
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
        $params->{token} = BOM::Platform::Token::API->new->create_token($client_mlt->loginid, _get_unique_display_name());
        $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
        is $result->{client_to_loginid},   $client_mf->loginid,   'transfer_between_accounts to client is ok';
        is $result->{client_to_full_name}, $client_mf->full_name, 'transfer_between_accounts to client name is ok';

        cmp_deeply(
            $rpc_ct->result->{accounts},
            bag({
                    loginid      => $client_mf->loginid,
                    balance      => $client_mf->default_account->balance,
                    currency     => $client_mf->default_account->currency_code,
                    account_type => 'binary'
                },
                {
                    loginid      => $client_mlt->loginid,
                    balance      => $client_mlt->default_account->balance,
                    currency     => $client_mf->default_account->currency_code,
                    account_type => 'binary'
                }
            ),
            'affected accounts returned in result'
        );

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
        $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_error('no withdrawal limit');
    };
};

subtest 'transfer with fees' => sub {

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
    #save target countries for PA
    $client_cr_pa_btc->get_payment_agent->set_countries(['id', 'in']);

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

    $params->{token} = BOM::Platform::Token::API->new->create_token($client_cr_usd->loginid, _get_unique_display_name());
    my $amount = 10;
    $params->{args} = {
        account_from => $client_cr_usd->loginid,
        account_to   => $client_cr_btc->loginid,
        currency     => "USD",
        amount       => 10
    };

    BOM::Config::Runtime->instance->app_config->system->suspend->transfer_between_accounts(1);
    $rpc_ct->call_ok('transfer_between_accounts', $params)->has_error('error as all transfer_between_accounts are suspended in system config')
        ->error_code_is('TransferBetweenAccountsError', 'error code is TransferBetweenAccountsError')
        ->error_message_like(qr/Transfers between fiat and crypto accounts/);
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
        });

    my $transfer_limits = BOM::Config::CurrencyConfig::transfer_between_accounts_limits();

    $amount          = $transfer_limits->{BTC}->{min};
    $params->{token} = BOM::Platform::Token::API->new->create_token($client_cr_btc->loginid, _get_unique_display_name());
    $params->{args}  = {
        account_from => $client_cr_btc->loginid,
        account_to   => $client_cr_eur->loginid,
        currency     => "BTC",
        amount       => $amount
    };
    $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->error_code_is('TransferBetweenAccountsError')
        ->error_message_is('Account transfers are not possible between BTC and EUR.');

    subtest 'non-pa to non-pa transfers' => sub {
        my $previous_balance_btc = $client_cr_btc->default_account->balance;
        my $previous_balance_usd = $client_cr_usd->default_account->balance;

        $params->{args} = {
            account_from => $client_cr_usd->loginid,
            account_to   => $client_cr_btc->loginid,
            currency     => "USD",
            amount       => $transfer_limits->{USD}->{min}};

        my $amount = $transfer_limits->{USD}->{min};
        $params->{args}->{amount} = $amount;
        my $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_no_error->result;
        is $result->{client_to_loginid}, $client_cr_btc->loginid, 'Transaction successful';

        # fiat to crypto. exchange rate is 4000 for BTC
        my $fee_percent     = $usd_btc_fee;
        my $transfer_amount = ($amount - $amount * $fee_percent / 100) / 4000;
        cmp_ok $transfer_amount, '>=', get_min_unit('BTC'), 'Transfered amount is not less than minimum unit';
        cmp_ok $client_cr_btc->default_account->balance, '==', 1 + $transfer_amount, 'correct balance after transfer including fees';
        cmp_ok $client_cr_usd->default_account->balance, '==', 1000 - $amount, 'non-pa to non-pa(USD to BTC), correct balance, exact amount deducted';

        $previous_balance_btc = $client_cr_btc->default_account->balance;
        $previous_balance_usd = $client_cr_usd->default_account->balance;
        $params->{token}      = BOM::Platform::Token::API->new->create_token($client_cr_btc->loginid, _get_unique_display_name());
        $amount               = $transfer_limits->{BTC}->{min};
        $params->{args}       = {
            account_from => $client_cr_btc->loginid,
            account_to   => $client_cr_usd->loginid,
            currency     => "BTC",
            amount       => $amount
        };
        $params->{args}->{amount} = $amount;
        $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_no_error->result;
        is $result->{client_to_loginid}, $client_cr_usd->loginid, 'Transaction successful';
        # crypto to fiat is 1%
        $fee_percent     = $btc_usd_fee;
        $transfer_amount = ($amount - $amount * $fee_percent / 100) * 4000;
        cmp_ok $transfer_amount, '>=', get_min_unit('USD'), 'Transfered amount is not less than minimum unit';
        cmp_ok $client_cr_usd->default_account->balance, '==', $previous_balance_usd + $transfer_amount,
            'correct balance after transfer including fees';
        is(
            financialrounding('price', 'BTC', $client_cr_btc->account->balance),
            financialrounding('price', 'BTC', $previous_balance_btc - $amount),
            'non-pa to non-pa (BTC to USD), correct balance after transfer including fees'
        );
    };

    subtest 'unauthorised pa to non-pa transfer' => sub {
        my $previous_balance_btc = $client_cr_pa_btc->default_account->balance;
        my $previous_balance_usd = $client_cr_usd->default_account->balance;
        $params->{token} = BOM::Platform::Token::API->new->create_token($client_cr_pa_btc->loginid, _get_unique_display_name());
        my $amount = $transfer_limits->{BTC}->{min};
        $params->{args} = {
            account_from => $client_cr_pa_btc->loginid,
            account_to   => $client_cr_usd->loginid,
            currency     => "BTC",
            amount       => $amount
        };

        # crypto to fiat is 1% and fiat to crypto is 1%
        my $fee_percent = $btc_usd_fee;
        my $result      = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_no_error->result;
        cmp_ok my $transfer_amount = ($amount - $amount * $fee_percent / 100) * 4000, '>=', get_min_unit('USD'), 'Valid transfered amount';
        cmp_ok $client_cr_pa_btc->default_account->balance, '==', financialrounding('amount', 'BTC', $previous_balance_btc - $amount),
            'correct balance after transfer including fees';
        cmp_ok $client_cr_usd->default_account->balance, '==', financialrounding('amount', 'BTC', $previous_balance_usd + $transfer_amount),
            'unauthorised pa to non-pa transfer (BTC to USD) correct balance after transfer including fees';
    };

    # database function throw error if same transaction happens
    # in 2 seconds
    sleep(2);

    subtest 'non-pa to unauthorised pa transfer' => sub {
        my $previous_balance_btc = $client_cr_pa_btc->default_account->balance;
        my $previous_balance_usd = $client_cr_usd->default_account->balance;
        my $amount               = $transfer_limits->{USD}->{min};

        $params->{token} = BOM::Platform::Token::API->new->create_token($client_cr_usd->loginid, _get_unique_display_name());
        $params->{args}  = {
            account_from => $client_cr_usd->loginid,
            account_to   => $client_cr_pa_btc->loginid,
            currency     => "USD",
            amount       => $amount
        };

        my $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_no_error->result;
        is $result->{client_to_loginid}, $client_cr_pa_btc->loginid, 'Transaction successful';

        my $fee_percent = $usd_btc_fee;
        cmp_ok my $transfer_amount = ($amount - $amount * $fee_percent / 100) / 4000, '>=', get_min_unit('BTC'), 'Valid received amound';
        cmp_ok $client_cr_usd->default_account->balance, '==', $previous_balance_usd - $amount, 'correct balance after transfer including fees';

        is(
            financialrounding('price', 'BTC', $client_cr_pa_btc->default_account->balance),
            financialrounding('price', 'BTC', $previous_balance_btc + $transfer_amount),
            'non-pa to unauthorised pa transfer (USD to BTC) correct balance after transfer including fees'
        );
    };

    subtest 'Correct commission charged for fiat -> stablecoin crypto' => sub {
        my $previous_amount_usd = $client_cr_usd->account->balance;
        my $previous_amount_ust = $client_cr_ust->account->balance;

        my $amount                   = 100;
        my $expected_fee_percent     = $usd_ust_fee;
        my $expected_transfer_amount = ($amount - $amount * $expected_fee_percent / 100);

        $params->{token} = BOM::Platform::Token::API->new->create_token($client_cr_usd->loginid, _get_unique_display_name());
        $params->{args}  = {
            account_from => $client_cr_usd->loginid,
            account_to   => $client_cr_ust->loginid,
            currency     => "USD",
            amount       => $amount
        };

        my $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_no_error->result;
        is $result->{client_to_loginid}, $client_cr_ust->loginid, 'Transaction successful';

        cmp_ok $client_cr_usd->account->balance, '==', $previous_amount_usd - $amount, 'From account deducted correctly';
        cmp_ok $client_cr_ust->account->balance, '==', $previous_amount_ust + $expected_transfer_amount, 'To account credited correctly';
    };

    subtest 'Correct commission charged for stablecoin crypto -> fiat' => sub {
        my $previous_amount_usd = $client_cr_usd->account->balance;
        my $previous_amount_ust = $client_cr_ust->account->balance;

        my $amount                   = 100;
        my $expected_fee_percent     = $ust_usd_fee;
        my $expected_transfer_amount = financialrounding('amount', 'USD', $amount - $amount * $expected_fee_percent / 100);

        $params->{token} = BOM::Platform::Token::API->new->create_token($client_cr_ust->loginid, _get_unique_display_name());
        $params->{args}  = {
            account_from => $client_cr_ust->loginid,
            account_to   => $client_cr_usd->loginid,
            currency     => "UST",
            amount       => $amount
        };

        my $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_no_error->result;
        is $result->{client_to_loginid}, $client_cr_usd->loginid, 'Transaction successful';

        cmp_ok $client_cr_ust->account->balance, '==', $previous_amount_ust - $amount, 'From account deducted correctly';
        cmp_ok $client_cr_usd->account->balance, '==', $previous_amount_usd + $expected_transfer_amount, 'To account credited correctly';

    };

    subtest 'Minimum commission enforced for stablecoin crypto -> fiat' => sub {
        my $previous_amount_usd = $client_cr_usd->account->balance;
        my $previous_amount_ust = $client_cr_ust->account->balance;

        my $amount                   = $transfer_limits->{UST}->{min};
        my $expected_fee_percent     = $ust_usd_fee;
        my $expected_transfer_amount = financialrounding('amount', 'UST', $amount - $amount * $expected_fee_percent / 100);

        $params->{token} = BOM::Platform::Token::API->new->create_token($client_cr_ust->loginid, _get_unique_display_name());
        $params->{args}  = {
            account_from => $client_cr_ust->loginid,
            account_to   => $client_cr_usd->loginid,
            currency     => "UST",
            amount       => $amount
        };

        my $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_no_error->result;
        is $result->{client_to_loginid}, $client_cr_usd->loginid, 'Transaction successful';

        cmp_ok $client_cr_ust->account->balance, '==', $previous_amount_ust - $amount, 'From account deducted correctly';
        my $amount_after_transaction = financialrounding('amount', 'USD', $previous_amount_usd + $expected_transfer_amount);
        cmp_ok $client_cr_usd->account->balance, '==', $amount_after_transaction, 'To account credited correctly';
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
    };

    $client_cr_pa_btc->payment_agent($pa_args);
    $client_cr_pa_btc->save();
    #save target countries for PA
    $client_cr_pa_btc->get_payment_agent->set_countries(['id', 'in']);

    $pa_args->{is_authenticated} = 'f';
    $pa_args->{currency_code}    = 'USD';
    $client_cr_pa_usd->payment_agent($pa_args);
    $client_cr_pa_usd->save();
    #save target countries for PA
    $client_cr_pa_usd->get_payment_agent->set_countries(['id', 'in']);

    my $amount = 0.1;
    $params->{token} = BOM::Platform::Token::API->new->create_token($client_cr_pa_btc->loginid, _get_unique_display_name());
    $params->{args}  = {
        account_from => $client_cr_pa_btc->loginid,
        account_to   => $client_cr_usd->loginid,
        currency     => "BTC",
        amount       => $amount
    };

    my $previous_to_amt = $client_cr_usd->default_account->balance;
    my $previous_fm_amt = $client_cr_pa_btc->default_account->balance;

    my $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
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
    $result          = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{client_to_loginid}, $client_cr_pa_usd->loginid, 'Transaction successful';

    $transfer_amount = ($amount - $amount * $fee_percent / 100) * 4000;
    cmp_ok($client_cr_pa_btc->default_account->balance + 0, '==', ($previous_fm_amt - $amount), 'correct balance after transfer excluding fees');
    cmp_ok $client_cr_pa_usd->default_account->balance + 0, '==', $previous_to_amt + $transfer_amount,
        'authorised pa to unauthrised pa (BTC to USD), one pa is authorised so no transaction fee charged';

    sleep(2);
    $amount          = 10;
    $params->{token} = BOM::Platform::Token::API->new->create_token($client_cr_usd->loginid, _get_unique_display_name());
    $params->{args}  = {
        account_from => $client_cr_usd->loginid,
        account_to   => $client_cr_pa_btc->loginid,
        currency     => "USD",
        amount       => $amount
    };

    $previous_to_amt = $client_cr_pa_btc->default_account->balance;
    $previous_fm_amt = $client_cr_usd->default_account->balance;

    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
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

    $params->{token} = BOM::Platform::Token::API->new->create_token($client_cr_eur->loginid, _get_unique_display_name());
    $params->{args}  = {
        account_from => $client_cr_eur->loginid,
        account_to   => $client_cr_usd->loginid,
        currency     => "EUR",
        amount       => 10
    };

    my $result =
        $rpc_ct->call_ok('transfer_between_accounts', $params)
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

    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{client_to_loginid}, $client_cr_btc->loginid, 'fiat->cryto allowed';

    sleep 2;
    $redis->hmset(
        'exchange_rates::EUR_USD',
        quote => 1.1,
        epoch => time - 3595
    );
    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{client_to_loginid}, $client_cr_btc->loginid, 'fiat->cryto allowed with a slightly old rate (<1 hour)';

    sleep 2;
    $redis->hmset(
        'exchange_rates::EUR_USD',
        quote => 1.1,
        epoch => time - 3605
    );
    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError',
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
        $rpc_ct->call_ok('transfer_between_accounts', $params)
        ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', "Daily Transfer limit - correct error code")
        ->error_message_like(qr/2 transfers a day/, 'Daily Transfer Limit - correct error message');
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

    my $token_cr_usd = BOM::Platform::Token::API->new->create_token($client_cr_usd->loginid, _get_unique_display_name());
    my $token_cr_btc = BOM::Platform::Token::API->new->create_token($client_cr_btc->loginid, _get_unique_display_name());
    my $token_mf_eur = BOM::Platform::Token::API->new->create_token($client_mf_eur->loginid, _get_unique_display_name());

    subtest 'it should stop transfers to suspended currency' => sub {
        $params->{token} = $token_cr_usd;
        $params->{args}  = {
            account_from => $client_cr_usd->loginid,
            account_to   => $client_cr_btc->loginid,
            currency     => "USD",
            amount       => 10
        };
        BOM::Config::Runtime->instance->app_config->system->suspend->transfer_currencies(['BTC']);
        my $result =
            $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError',
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

        my $result =
            $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError',
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

        $rpc_ct->call_ok('transfer_between_accounts', $params);
    };

    # reset the config
    BOM::Config::Runtime->instance->app_config->system->suspend->transfer_currencies([]);
};

subtest 'MT5' => sub {

    @BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');
    my $mock_account = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $mock_account->mock(
        _is_financial_assessment_complete => sub { return 1 },
        _throttle                         => sub { return 0 });
    my $mock_client = Test::MockModule->new('BOM::User::Client');
    $mock_client->mock(fully_authenticated => sub { return 1 });

    $email = 'mt5_user_for_transfer@test.com';

    my %ACCOUNTS = %Test::BOM::RPC::Accounts::MT5_ACCOUNTS;
    my %DETAILS  = %Test::BOM::RPC::Accounts::ACCOUNT_DETAILS;

    $user = BOM::User->create(
        email          => $email,
        password       => $DETAILS{password}{main},
        email_verified => 1
    );

    my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code            => 'CR',
        email                  => $email,
        place_of_birth         => 'id',
        account_opening_reason => 'no reason',
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
        currency => 'BTC',
        amount   => 10,
        remark   => 'free gift',
    );
    $test_client_btc->status->set('crs_tin_information', 'system', 'testing something');

    $user->add_client($test_client);
    $user->add_client($test_client_btc);

    my $token = BOM::Platform::Token::API->new->create_token($test_client->loginid, _get_unique_display_name());

    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type     => 'demo',
            mt5_account_type => 'financial',
            investPassword   => $DETAILS{investPassword},
            mainPassword     => $DETAILS{password}{main},
        },
    };
    $rpc_ct->call_ok('mt5_new_account', $params)->has_no_error('no error for demo mt5_new_account');

    $params->{args}{account_type}     = 'financial';
    $params->{args}{mt5_account_type} = 'financial';
    $rpc_ct->call_ok('mt5_new_account', $params)->has_no_error('no error for financial mt5_new_account');

    $params->{args}{account_type}     = 'financial';
    $params->{args}{mt5_account_type} = 'financial_stp';
    $rpc_ct->call_ok('mt5_new_account', $params)->has_no_error('no error for financial_stp mt5_new_account');

    $params->{args} = {
        account_from => 'MTR' . $ACCOUNTS{'real\p01_ts01\financial\svg_std_usd'},
        account_to   => 'MTR' . $ACCOUNTS{'real\p01_ts01\financial\labuan_stp_usd'},
        currency     => "USD",
        amount       => 180                                                     # this is the only deposit amount allowed by mock MT5
    };
    $rpc_ct->call_ok('transfer_between_accounts', $params)
        ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', 'MT5->MT5 transfer error code')
        ->error_message_is('Transfer between two MT5 accounts is not allowed.', 'MT5->MT5 transfer error message');

    $params->{args}{account_from} = 'MTD' . $ACCOUNTS{'demo\p01_ts01\financial\svg_std_usd'};
    $params->{args}{account_to}   = $test_client->loginid;
    $rpc_ct->call_ok('transfer_between_accounts', $params)
        ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', 'MT5 demo -> real account transfer error code')
        ->error_message_like(qr/demo accounts/, 'MT5 demo -> real account transfer error message');

    # real -> MT5
    # Token is used of USD account that is not withdrawal_locked but account_from is withdrawal_locked
    $params->{args}{account_from} = $test_client_btc->loginid;
    $params->{args}{currency}     = 'BTC';
    $params->{args}{amount}       = 1;
    $params->{args}{account_to}   = 'MTR' . $ACCOUNTS{'real\p01_ts01\financial\svg_std_usd'};
    #set withdrawal_locked status to make sure for Real  -> MT5 transfer is not allowed
    $test_client_btc->status->set('withdrawal_locked', 'system', 'test');
    ok $test_client_btc->status->withdrawal_locked, "Real BTC account is withdrawal_locked";
    $rpc_ct->call_ok('transfer_between_accounts', $params)
        ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', 'Correct error code')->error_message_like(
        qr/You cannot perform this action, as your account is withdrawal locked./,
        'Correct error message returned because Real BTC account is withdrawal locked.'
        );
    #remove withdrawal_locked
    $test_client_btc->status->clear_withdrawal_locked;
    #set cashier_locked status to make sure for Real  -> MT5 transfer is not allowed
    $test_client_btc->status->set('cashier_locked', 'system', 'test');
    ok $test_client_btc->status->cashier_locked, "Real BTC account is cashier_locked";
    $rpc_ct->call_ok('transfer_between_accounts', $params)
        ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', 'Correct error code')->error_message_like(
        qr/Your account cashier is locked. Please contact us for more information./,
        'Correct error message returned because Real BTC account is cashier_locked.'
        );
    #remove cashier_locked
    $test_client_btc->status->clear_cashier_locked;

    $params->{args}{account_from} = $test_client->loginid;
    $params->{args}{currency}     = 'USD';
    $params->{args}{amount}       = 180;
    _test_events_prepare();

    # MT5 (fiat) <=> CR (fiat) is allowed even if the client is transfers_blocked
    $test_client->status->set('transfers_blocked', 'system', 'testing transfers_blocked for real -> mt5');

    $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_error("Real account -> real MT5 ok");
    _test_events_tba(1, $test_client, $params->{args}{account_to});

    cmp_deeply(
        $rpc_ct->result,
        {
            status              => 1,
            transaction_id      => ignore(),
            client_to_full_name => $DETAILS{name},
            client_to_loginid   => $params->{args}{account_to},
            stash               => ignore(),
            accounts            => bag({
                    loginid      => 'MTR' . $ACCOUNTS{'real\p01_ts01\financial\svg_std_usd'},
                    balance      => num($DETAILS{balance}),
                    currency     => 'USD',
                    account_type => 'mt5',
                    'mt5_group'  => 'real\p01_ts01\financial\svg_std_usd'
                },
                {
                    loginid      => $test_client->loginid,
                    balance      => num(1000 - 180),
                    currency     => 'USD',
                    account_type => 'binary'
                })});
    cmp_ok $test_client->default_account->balance, '==', 820, 'real money account balance decreased';

    # MT5 -> real
    $mock_client->mock(fully_authenticated => sub { return 0 });

    $params->{args}{account_from} = 'MTR' . $ACCOUNTS{'real\p01_ts01\financial\svg_std_usd'};
    $params->{args}{account_to}   = $test_client->loginid;
    $params->{args}{amount}       = 150;                                                 # this is the only withdrawal amount allowed by mock MT5

    _test_events_prepare();

    $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_error("Real MT5 -> real account ok");
    _test_events_tba(
        0,
        $test_client,
        $params->{args}{account_from},
        (
            to_amount   => 150,
            from_amount => 150
        ));

    cmp_deeply(
        $rpc_ct->result,
        {
            status              => 1,
            transaction_id      => ignore(),
            client_to_full_name => $test_client->full_name,
            client_to_loginid   => $params->{args}{account_to},
            stash               => ignore(),
            accounts            => bag({
                    loginid      => 'MTR' . $ACCOUNTS{'real\p01_ts01\financial\svg_std_usd'},
                    balance      => num($DETAILS{balance}),
                    currency     => 'USD',
                    account_type => 'mt5',
                    'mt5_group'  => 'real\p01_ts01\financial\svg_std_usd'
                },
                {
                    loginid      => $test_client->loginid,
                    balance      => num(1000 - 30),
                    currency     => 'USD',
                    account_type => 'binary'
                })
        },
        'expected data in result'
    );

    $test_client->status->clear_transfers_blocked;

    cmp_ok $test_client->default_account->balance, '==', 970, 'real money account balance increased';
    #set cashier locked status to make sure for MT5 -> Real transfer it is failed.
    $test_client->status->set('cashier_locked', 'system', 'test');
    ok $test_client->status->cashier_locked, "Real account is cashier_locked";
    $rpc_ct->call_ok('transfer_between_accounts', $params)
        ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', 'Correct error code')
        ->error_message_like(qr/Your account cashier is locked. Please contact us for more information./,
        'Correct error message returned because Real account is cashier_locked so no deposit/withdrawal allowed.');
    #remove cashier_locked
    $test_client->status->clear_cashier_locked;

    $params->{args}{account_from} = 'MTR' . $ACCOUNTS{'real\p01_ts01\financial\labuan_stp_usd'};
    $rpc_ct->call_ok('transfer_between_accounts', $params)
        ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', 'Correct error code')
        ->error_message_like(
        qr/Your identity documents have expired. Visit your account profile to submit your valid documents and unlock your cashier./,
        'Error message returned from inner MT5 sub when regulated account has expired documents');

    $mock_client->mock(documents_expired => sub { return 0 });

    $rpc_ct->call_ok('transfer_between_accounts', $params)
        ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', 'Correct error code')->error_message_like(
        qr/Your identity documents have expired. Visit your account profile to submit your valid documents and unlock your cashier./,
        'Error message returned from inner MT5 sub when regulated binary has no expired documents but does not have valid documents'
        );

    $mock_client->mock(has_valid_documents => sub { return 1 });
    $mock_client->mock(fully_authenticated => sub { return 1 });

    $params->{args}{account_from} = $test_client->loginid;
    $params->{args}{account_to}   = 'MTR' . $ACCOUNTS{'real\p01_ts01\financial\labuan_stp_usd'};
    $params->{args}{currency}     = 'EUR';
    $rpc_ct->call_ok('transfer_between_accounts', $params)
        ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', 'Correct error code')
        ->error_message_is('Currency provided is different from account currency.', 'Correct message for wrong currency for real account_from');

    $params->{args}{account_from} = 'MTR' . $ACCOUNTS{'real\p01_ts01\financial\labuan_stp_usd'};
    $params->{args}{account_to}   = $test_client->loginid;
    $rpc_ct->call_ok('transfer_between_accounts', $params)
        ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', 'Correct error code')
        ->error_message_is('Currency provided is different from account currency.', 'Correct message for wrong currency for MT5 account_from');

    subtest 'transfers using an account other than authenticated client' => sub {
        $params->{token} = BOM::Platform::Token::API->new->create_token($test_client_btc->loginid, 'test token');
        $params->{args}{currency} = 'USD';

        $params->{args}{amount}       = 180;
        $params->{args}{account_from} = $test_client->loginid;
        $params->{args}{account_to}   = 'MTR' . $ACCOUNTS{'real\p01_ts01\financial\svg_std_usd'};

        $params->{token_type} = 'oauth_token';
        $rpc_ct->call_ok('transfer_between_accounts', $params)
            ->has_no_system_error->has_no_error('with oauth token, ok if account_from is not the authenticated client');
        $params->{token_type} = 'api_token';
        $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_error->error_message_is(
            'From account provided should be same as current authorized client.',
            'with api token, NOT ok if account_from is not the authenticated client'
        );

        $params->{args}{amount}       = 150;
        $params->{args}{account_from} = 'MTR' . $ACCOUNTS{'real\p01_ts01\financial\svg_std_usd'};
        $params->{args}{account_to}   = $test_client->loginid;

        $params->{token_type} = 'oauth_token';
        $rpc_ct->call_ok('transfer_between_accounts', $params)
            ->has_no_system_error->has_no_error('with oauth token, ok if account_to is not the authenticated client');
        $params->{token_type} = 'api_token';
        $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_error->error_message_is(
            'To account provided should be same as current authorized client.',
            'with api token, NOT ok if account_to is not the authenticated client'
        );
    };

};

sub _get_unique_display_name {
    my @a = ('A' .. 'Z', 'a' .. 'z');
    return join '', map { $a[int(rand($#a))] } (1 .. 3);
}

sub _test_events_prepare {
    undef $emit_data;
}

sub _test_events_tba {
    my ($is_deposit_to_mt5, $client, $mt5, %optional) = @_;

    my $to_currency = $optional{to_currency} // 'USD';
    my $to_amount   = $optional{to_amount}   // '180';
    my $from_amount = $optional{from_amount} // '180';
    my $fees        = $optional{fees}        // 0;

    my $to_account   = $is_deposit_to_mt5 ? $mt5               : $client->{loginid};
    my $from_account = $is_deposit_to_mt5 ? $client->{loginid} : $mt5;
    my $remark       = $is_deposit_to_mt5 ? 'Client>MT5'       : 'MT5>Client';

    is $emit_data->{transfer_between_accounts}{count}, 1, "transfer_between_accounts event emitted only once";

    my $response = $emit_data->{transfer_between_accounts}{last};

    is_deeply(
        $response,
        {
            loginid    => $client->{loginid},
            properties => {
                fees               => $fees,
                from_account       => $from_account,
                from_amount        => $from_amount,
                from_currency      => "USD",
                gateway_code       => "mt5_transfer",
                source             => 1,
                to_account         => $to_account,
                to_amount          => $to_amount,
                to_currency        => $to_currency,
                is_from_account_pa => 0,
                is_to_account_pa   => 0,
                id                 => $response->{properties}->{id},
                time               => $response->{properties}->{time}}
        },
        "transfer_between_accounts event provides data properly. ($remark)"
    );
}

subtest 'offer_to_clients' => sub {

    my $cr_dummy = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email
    });
    $user->add_client($cr_dummy);

    $cr_dummy->set_default_account('BTC');

    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        place_of_birth => 'id'
    });

    $user->add_client($client_cr);
    $client_cr->set_default_account('USD');

    $params->{token} = BOM::Platform::Token::API->new->create_token($client_cr->loginid, _get_unique_display_name());

    my $limits = BOM::Config::CurrencyConfig::transfer_between_accounts_limits();

    $params->{args} = {
        account_from => $client_cr->loginid,
        account_to   => $cr_dummy->loginid,
        currency     => 'USD',
        amount       => $limits->{USD}->{min}};

    _offer_to_clients(0, 'BTC');
    my $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'TransferBetweenAccountsError', 'Correct error code when offer_to_clients fails';
    like $result->{error}->{message_to_client}, qr/Sorry, transfers are currently unavailable. Please try again later./;

    _offer_to_clients(1, 'BTC');

};

subtest 'fiat to crypto limits' => sub {
    # For sake of convenience let's set a 20$ limit
    BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->fiat_to_crypto(20);

    my $email = 'new_fiat_to_crypto_transfer_email' . rand(999) . '@sample.com';
    my $user  = BOM::User->create(
        email          => $email,
        password       => BOM::User::Password::hashpw('jskjd8292922'),
        email_verified => 1,
    );
    my $client_cr_btc = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        binary_user_id => $test_binary_user_id,
        place_of_birth => 'id',
    });

    my $client_cr_usd = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        binary_user_id => $test_binary_user_id,
        place_of_birth => 'id',
    });

    $user->add_client($client_cr_btc);
    $user->add_client($client_cr_usd);

    $client_cr_usd->set_default_account('USD');
    $client_cr_btc->set_default_account('BTC');

    $client_cr_btc->payment_free_gift(
        currency => 'BTC',
        amount   => 1,
        remark   => 'free gift',
    );

    cmp_ok $client_cr_btc->default_account->balance + 0, '==', 1, 'correct balance';

    $client_cr_usd->payment_free_gift(
        currency => 'USD',
        amount   => 1000,
        remark   => 'free gift',
    );
    cmp_ok $client_cr_usd->default_account->balance + 0, '==', 1000, 'correct balance';

    $params->{args} = {
        account_from => $client_cr_usd->loginid,
        account_to   => $client_cr_btc->loginid,
        currency     => 'USD',
        amount       => 100
    };

    my $token = BOM::Platform::Token::API->new->create_token($client_cr_usd->loginid, _get_unique_display_name());
    $params->{token}      = $token;
    $params->{token_type} = 'oauth_token';

    my $mock_client = Test::MockModule->new('BOM::User::Client');
    my $mock_status = Test::MockModule->new('BOM::User::Client::Status');
    $mock_client->mock(
        'fully_authenticated',
        sub {
            return 1;
        });
    $mock_status->mock(
        'age_verification',
        sub {
            return 0;
        });

    my $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    ok $result->{status}, 'Fully authenticated non age verified transfer is sucessful';

    $mock_client->mock(
        'fully_authenticated',
        sub {
            return 0;
        });
    sleep(2);
    $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_error->error_code_is('Fiat2CryptoTransferOverLimit',
        'Not verified account should not pass the fiat to crypto limit')
        ->error_message_like(qr/You have exceeded 20.00 USD in cumulative transactions. To continue, you will need to verify your identity./,
        'Correct error message returned for a fiat to crypto transfer that reached the limit.');

    $mock_status->unmock_all;
    $mock_client->unmock_all;
};

done_testing();

sub _get_transaction_details {
    my ($client, $transaction_id) = @_;

    my ($result) = $client->db->dbic->run(
        fixup => sub {
            $_->selectrow_array('select details from transaction.transaction_details where transaction_id = ?', undef, $transaction_id,);
        });
    return JSON::MaybeUTF8::decode_json_utf8($result);
}
