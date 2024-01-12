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
use POSIX                            qw/ ceil /;
use ExchangeRates::CurrencyConverter qw(in_usd convert_currency);
use Format::Util::Numbers            qw/financialrounding get_min_unit formatnumber/;
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

# disable routing to demo p01_ts02
my $p01_ts02_load = BOM::Config::Runtime->instance->app_config->system->mt5->load_balance->demo->all->p01_ts02;
BOM::Config::Runtime->instance->app_config->system->mt5->load_balance->demo->all->p01_ts02(0);

# disable routing to demo p01_ts03
my $p01_ts03_load = BOM::Config::Runtime->instance->app_config->system->mt5->load_balance->demo->all->p01_ts03;
BOM::Config::Runtime->instance->app_config->system->mt5->load_balance->demo->all->p01_ts03(0);

my $test_binary_user_id = 65000;
my $rpc_ct;

my $redis = BOM::Config::Redis::redis_exchangerates_write();

sub _offer_to_clients {
    my $value         = shift;
    my $from_currency = shift;
    my $to_currency   = shift // 'USD';

    $redis->hmset("exchange_rates::${from_currency}_${to_currency}", offer_to_clients => $value);
}
_offer_to_clients(1, $_) for qw/BTC LTC USDC USD ETH UST EUR/;

# In the weekend the account transfers will be suspended. So we mock a valid day here
set_absolute_time(Date::Utility->new('2018-02-15')->epoch);
scope_guard { restore_time() };

# unlimit daily transfer
BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->between_accounts(999);
BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->MT5(999);

my $documents_mock = Test::MockModule->new('BOM::User::Client::AuthenticationDocuments');
my $has_valid_documents;
my $expired_documents;
$documents_mock->mock(
    'valid',
    sub {
        my ($self) = @_;

        return $has_valid_documents if defined $has_valid_documents;
        return $documents_mock->original('valid')->(@_);
    });
$documents_mock->mock(
    'expired',
    sub {
        my ($self) = @_;

        return $expired_documents if defined $expired_documents;
        return $documents_mock->original('expired')->(@_);
    });

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
    $email,            $client_vr,        $client_cr,     $cr_dummy,      $client_mlt,
    $client_mf,        $client_cr_usd,    $client_cr_btc, $client_cr_ust, $client_cr_eur,
    $client_cr_pa_usd, $client_cr_pa_btc, $user,          $token,         $client_cr2
);

my $btc_usd_rate = 4000;
my $custom_rates = {
    'BTC'  => $btc_usd_rate,
    'LTC'  => 1000,
    'ETH'  => 1000,
    'USDC' => 1,
    'UST'  => 1,
    'USD'  => 1,
    'EUR'  => 1.1888,
    'GBP'  => 1.3333,
    'JPY'  => 0.0089,
    'AUD'  => 1,
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

    $client_cr2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
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
    $user->add_client($client_cr2);
    $user->add_client($client_mlt);
    $user->add_client($client_mf);
    $user->add_client($client_vr);

    $token                = BOM::Platform::Token::API->new->create_token($client_cr->loginid, _get_unique_display_name());
    $params->{token}      = $token;
    $params->{token_type} = 'oauth_token';
    my $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is @{$result->{accounts}}, 2, 'if no loginid from or to passed then it returns real accounts within same landing company';

    $params->{args} = {
        account_from => $client_cr->loginid,
        account_to   => $client_mlt->loginid,
    };

    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{error}->{code},              'IncompatibleCurrencyType',       'Correct error code for no currency';
    is $result->{error}->{message_to_client}, 'Please provide valid currency.', 'Correct error message for no currency';

    $params->{args}->{currency} = 'EUR';

    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{error}->{code},              'TransferInvalidAmount',        'Correct error code for invalid amount';
    is $result->{error}->{message_to_client}, 'Please provide valid amount.', 'Correct error message for invalid amount';

    $params->{args}->{amount} = 'NA';

    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{error}->{code},              'TransferInvalidAmount',        'Correct error code for invalid amount';
    is $result->{error}->{message_to_client}, 'Please provide valid amount.', 'Correct error message for invalid amount';

    $params->{args}->{amount}   = 1;
    $params->{args}->{currency} = 'XXX';
    $result                     = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{error}->{code},              'IncompatibleCurrencyType',       'Correct error code for invalid currency';
    is $result->{error}->{message_to_client}, 'Please provide valid currency.', 'Correct error message for invalid currency code';

    $params->{token_type}       = 'oauth_token';
    $params->{args}->{currency} = 'EUR';
    $params->{token}            = BOM::Platform::Token::API->new->create_token($client_vr->loginid, _get_unique_display_name());
    $result                     = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_error->result;
    is_deeply $result->{error},
        {
        code              => 'TransferBlockedClientIsVirtual',
        message_to_client => 'The authorized account cannot be used to perform transfers.',
        },
        'Correct error for real transfer with a virtual token';

    $params->{args}->{account_from} = $client_vr->loginid;
    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_error->result;
    is_deeply $result->{error},
        {
        code              => 'RealToVirtualNotAllowed',
        message_to_client => 'Transfer between real and virtual accounts is not allowed.',
        },
        'Correct error for virtual to real transfer';

    $params->{token} = $token;

    $params->{args}->{account_from} = $client_cr->loginid;
    $client_cr->status->set('cashier_locked', 'system', 'testing something');
    $rpc_ct->call_ok('transfer_between_accounts', $params)
        ->has_no_system_error->error_code_is('CashierLocked', 'Correct error code for cashier locked')
        ->error_message_is("Your account cashier is locked. Please contact us for more information.", 'Correct error message for cashier locked');
    $client_cr->status->clear_cashier_locked;

    $params->{args}->{account_to} = $client_mlt->loginid;
    $client_mlt->status->set('cashier_locked', 'system', 'testing something');
    $rpc_ct->call_ok('transfer_between_accounts', $params)
        ->has_no_system_error->error_code_is('CashierLocked', 'Correct error code for cashier locked')
        ->error_message_is("Your account cashier is locked. Please contact us for more information.", 'Correct error message for cashier locked');
    $client_mlt->status->clear_cashier_locked;

    $client_cr->status->set('withdrawal_locked', 'system', 'testing something');

    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'WithdrawalLockedStatus', 'Correct error code for withdrawal locked';
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
    is $result->{error}->{code}, 'PermissionDenied', 'Correct error code for loginid that does not exists';
    is $result->{error}->{message_to_client}, "You are not allowed to transfer from this account.",
        'Correct error message for loginid that does not exists';

    $cr_dummy = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email
    });

    # send loginid that is not linked to used
    $params->{args}->{account_from} = $cr_dummy->loginid;

    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'PermissionDenied', 'Correct error code for loginid not in siblings';
    is $result->{error}->{message_to_client}, 'You are not allowed to transfer from this account.',
        'Correct error message for loginid not in siblings';

    $params->{args}->{account_from} = $client_mlt->loginid;
    $params->{args}->{account_to}   = $client_mlt->loginid;

    $params->{token} = BOM::Platform::Token::API->new->create_token($client_mlt->loginid, _get_unique_display_name());

    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'SameAccountNotAllowed', 'Correct error code if from and to are same';
    is $result->{error}->{message_to_client}, 'Account transfers are not available within same account.',
        'Correct error message if from and to are same';

    $params->{token}                = BOM::Platform::Token::API->new->create_token($client_cr->loginid, _get_unique_display_name());
    $params->{args}->{account_from} = $client_cr->loginid;
    $params->{args}->{currency}     = $client_cr->currency;

    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'IncompatibleLandingCompanies', 'Correct error code';
    is $result->{error}->{message_to_client}, 'Transfers between accounts are not available for your account.',
        'Correct error message for different landing companies';

    $params->{args}->{account_from} = $client_mf->loginid;
    $params->{args}->{currency}     = 'EUR';

    $params->{token} = BOM::Platform::Token::API->new->create_token($client_mf->loginid, _get_unique_display_name());
    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'SetExistingAccountCurrency', 'Correct error code for no default currency';
    is $result->{error}->{message_to_client}, 'Please set the currency for your existing account MF90000000, in order to create more accounts.',
        'Correct error message for no default currency';

    $client_mf->set_default_account('EUR');
    $params->{args}->{currency} = 'BTC';

    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'CurrencyShouldMatch', 'Currency does not match either account';
    is $result->{error}->{message_to_client}, 'Currency provided is different from account currency.',
        'Correct error message for invalid currency for landing company';

    $params->{args}->{currency} = 'USD';

    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{error}->{code},              'CurrencyShouldMatch',                                   'Ccurrency does not match sending account';
    is $result->{error}->{message_to_client}, 'Currency provided is different from account currency.', 'Correct error message';

    $params->{args}->{currency} = 'EUR';

    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{error}->{code}, 'SetExistingAccountCurrency', 'Correct error code';
    is $result->{error}->{message_to_client},
        'Please set the currency for your existing account ' . $client_mlt->loginid . ', in order to create more accounts.',
        'Correct error message';

    $client_mlt->set_default_account('USD');

    $params->{token} = BOM::Platform::Token::API->new->create_token($client_mf->loginid, _get_unique_display_name());
    $params->{args}->{account_from} = $client_mf->loginid;
    $rpc_ct->call_ok('transfer_between_accounts', $params)
        ->has_no_system_error->has_error->error_code_is('DifferentFiatCurrencies', 'Transfer error as no different currency')
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
    is $result->{error}->{message_to_client}, 'This transaction cannot be done because your ' . $client_cr->loginid . ' account has zero balance.',
        'Correct error message for an empty account';

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
    is $result->{error}->{code}, 'TransferBetweenAccountsError', 'Correct error code insufficient balance';
    is $result->{error}->{message_to_client}, 'This transaction cannot be done because your ' . $client_cr->loginid . ' account has zero balance.',
        'Correct error message for an empty account';

    $client_cr->payment_free_gift(
        currency       => 'USD',
        amount         => $limits->{USD}->{max} + $limits->{USD}->{min},
        remark         => 'free gift',
        place_of_birth => 'id',
    );

    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_no_error->result;
    cmp_deeply $result,
        {
        'client_to_loginid'   => $cr_dummy->loginid,
        'client_to_full_name' => $cr_dummy->full_name,
        'accounts'            => bag({
                'account_type'     => 'binary',
                'account_category' => 'trading',
                'loginid'          => $client_cr->loginid,
                'balance'          => ignore(),
                'currency'         => 'USD',
                'transfers'        => 'all',
                'demo_account'     => bool(0),
            },
            {
                'currency'         => 'BTC',
                'balance'          => ignore(),
                'loginid'          => $cr_dummy->loginid,
                'account_type'     => 'binary',
                'account_category' => 'trading',
                'transfers'        => 'all',
                'demo_account'     => bool(0),
            }
        ),
        'stash'          => ignore(),
        'status'         => 1,
        'transaction_id' => ignore(),
        },
        'Result structure is fine';

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

subtest 'transfer_between_crypto_to_crypto_accounts' => sub {
    my $email = 'dummy_2' . rand(999) . '@binary.com';

    my $user = BOM::User->create(
        email          => $email,
        password       => BOM::User::Password::hashpw('jskjd8292922'),
        email_verified => 1,
    );

    my $client_cr_btc = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        place_of_birth => 'id'
    });

    my $client_cr_eth = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        place_of_birth => 'id'
    });

    my $client_cr_ltc = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        place_of_birth => 'id'
    });

    my $client_cr_usdc = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        place_of_birth => 'id'
    });

    my $client_cr_ust = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        place_of_birth => 'id'
    });

    $client_cr_btc->set_default_account('BTC');
    $client_cr_eth->set_default_account('ETH');
    $client_cr_ltc->set_default_account('LTC');
    $client_cr_usdc->set_default_account('USDC');
    $client_cr_ust->set_default_account('UST');

    $user->add_client($client_cr_btc);
    $user->add_client($client_cr_eth);
    $user->add_client($client_cr_ltc);
    $user->add_client($client_cr_usdc);
    $user->add_client($client_cr_ust);

    my $api_token_btc  = BOM::Platform::Token::API->new->create_token($client_cr_btc->loginid,  _get_unique_display_name());
    my $api_token_eth  = BOM::Platform::Token::API->new->create_token($client_cr_eth->loginid,  _get_unique_display_name());
    my $api_token_usdc = BOM::Platform::Token::API->new->create_token($client_cr_usdc->loginid, _get_unique_display_name());

    my $params = {
        token_type => 'oauth_token',
    };

    subtest 'crypto to crypto' => sub {
        $client_cr_eth->payment_free_gift(
            currency => 'ETH',
            amount   => 1,
            remark   => 'free gift',
        );

        $params->{token} = $api_token_eth;
        $params->{args}  = {
            account_from => $client_cr_eth->loginid,
            account_to   => $client_cr_ltc->loginid,
            amount       => 0.1,
            currency     => 'ETH'
        };

        my $expected_result = {
            'client_to_loginid'   => $client_cr_ltc->loginid,
            'client_to_full_name' => $client_cr_ltc->full_name,
            'accounts'            => bag({
                    'loginid'          => $client_cr_ltc->loginid,
                    'balance'          => ignore(),
                    'currency'         => 'LTC',
                    'account_type'     => 'binary',
                    'account_category' => 'trading',
                    'demo_account'     => bool(0),
                    'transfers'        => 'all',
                },
                {
                    'currency'         => 'ETH',
                    'balance'          => ignore(),
                    'loginid'          => $client_cr_eth->loginid,
                    'account_type'     => 'binary',
                    'account_category' => 'trading',
                    'demo_account'     => bool(0),
                    'transfers'        => 'all',
                }
            ),
            'stash'          => ignore(),
            'status'         => 1,
            'transaction_id' => ignore(),
        };

        my $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;

        cmp_deeply $result, $expected_result, 'Result structure is fine for crypto to crypto transfer';

        cmp_deeply(
            _get_transaction_details($client_cr_eth, $result->{transaction_id}),
            {
                from_login                => $client_cr_eth->loginid,
                to_login                  => $client_cr_ltc->loginid,
                fees                      => num(0.002),
                fee_calculated_by_percent => num(0.002),
                fees_currency             => 'ETH',
                fees_percent              => num(2),
                min_fee                   => num(0.00000001),
            },
            'metadata saved correctly in transaction_details table for crypto to crypto transfer'
        );
    };

    subtest 'crypto to stable' => sub {

        $client_cr_btc->payment_free_gift(
            currency => 'BTC',
            amount   => 1,
            remark   => 'free gift',
        );

        $params->{token} = $api_token_btc;
        $params->{args}  = {
            account_from => $client_cr_btc->loginid,
            account_to   => $client_cr_usdc->loginid,
            amount       => 0.1,
            currency     => 'BTC'
        };

        my $expected_result = {
            'client_to_loginid'   => $client_cr_usdc->loginid,
            'client_to_full_name' => $client_cr_usdc->full_name,
            'accounts'            => bag({
                    'loginid'          => $client_cr_usdc->loginid,
                    'balance'          => ignore(),
                    'currency'         => 'USDC',
                    'account_type'     => 'binary',
                    'account_category' => 'trading',
                    'demo_account'     => bool(0),
                    'transfers'        => 'all',
                },
                {
                    'currency'         => 'BTC',
                    'balance'          => ignore(),
                    'loginid'          => $client_cr_btc->loginid,
                    'account_type'     => 'binary',
                    'account_category' => 'trading',
                    'demo_account'     => bool(0),
                    'transfers'        => 'all',
                }
            ),
            'stash'          => ignore(),
            'status'         => 1,
            'transaction_id' => ignore(),
        };

        my $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;

        cmp_deeply $result, $expected_result, 'Result structure is fine for crypto to stable transfer';

        cmp_deeply(
            _get_transaction_details($client_cr_btc, $result->{transaction_id}),
            {
                from_login                => $client_cr_btc->loginid,
                to_login                  => $client_cr_usdc->loginid,
                fees                      => num(0.002),
                fee_calculated_by_percent => num(0.002),
                fees_currency             => 'BTC',
                fees_percent              => num(2),
                min_fee                   => num(0.00000001),
            },
            'metadata saved correctly in transaction_details table for crypto to stable transfer'
        );
    };

    subtest 'stable to crypto' => sub {
        $client_cr_usdc->payment_free_gift(
            currency => 'USDC',
            amount   => 1000,
            remark   => 'free gift',
        );

        $params->{token} = $api_token_usdc;
        $params->{args}  = {
            account_from => $client_cr_usdc->loginid,
            account_to   => $client_cr_eth->loginid,
            amount       => 150,
            currency     => 'USDC'
        };

        my $expected_result = {
            'client_to_loginid'   => $client_cr_eth->loginid,
            'client_to_full_name' => $client_cr_eth->full_name,
            'accounts'            => bag({
                    'loginid'          => $client_cr_usdc->loginid,
                    'balance'          => ignore(),
                    'currency'         => 'USDC',
                    'account_type'     => 'binary',
                    'account_category' => 'trading',
                    'demo_account'     => bool(0),
                    'transfers'        => 'all',
                },
                {
                    'currency'         => 'ETH',
                    'balance'          => ignore(),
                    'loginid'          => $client_cr_eth->loginid,
                    'account_type'     => 'binary',
                    'account_category' => 'trading',
                    'demo_account'     => bool(0),
                    'transfers'        => 'all',
                }
            ),
            'stash'          => ignore(),
            'status'         => 1,
            'transaction_id' => ignore(),
        };

        my $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;

        cmp_deeply $result, $expected_result, 'Result structure is fine for stable to crypto transfer';

        cmp_deeply(
            _get_transaction_details($client_cr_usdc, $result->{transaction_id}),
            {
                from_login                => $client_cr_usdc->loginid,
                to_login                  => $client_cr_eth->loginid,
                fees                      => num(3),
                fee_calculated_by_percent => num(3),
                fees_currency             => 'USDC',
                fees_percent              => num(2),
                min_fee                   => num(0.01),
            },
            'metadata saved correctly in transaction_details table for stable to crypto transfer'
        );
    };

    subtest 'stable to stable' => sub {
        $client_cr_usdc->payment_free_gift(
            currency => 'USDC',
            amount   => 1000,
            remark   => 'free gift',
        );

        $params->{token} = $api_token_usdc;
        $params->{args}  = {
            account_from => $client_cr_usdc->loginid,
            account_to   => $client_cr_ust->loginid,
            amount       => 150,
            currency     => 'USDC'
        };

        my $expected_result = {
            'client_to_loginid'   => $client_cr_ust->loginid,
            'client_to_full_name' => $client_cr_ust->full_name,
            'accounts'            => bag({
                    'loginid'          => $client_cr_usdc->loginid,
                    'balance'          => ignore(),
                    'currency'         => 'USDC',
                    'account_type'     => 'binary',
                    'account_category' => 'trading',
                    'demo_account'     => bool(0),
                    'transfers'        => 'all',
                },
                {
                    'currency'         => 'UST',
                    'balance'          => ignore(),
                    'loginid'          => $client_cr_ust->loginid,
                    'account_type'     => 'binary',
                    'account_category' => 'trading',
                    'demo_account'     => bool(0),
                    'transfers'        => 'all',
                }
            ),
            'stash'          => ignore(),
            'status'         => 1,
            'transaction_id' => ignore(),
        };

        my $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;

        cmp_deeply $result, $expected_result, 'Result structure is fine for stable to stable transfer';

        cmp_deeply(
            _get_transaction_details($client_cr_usdc, $result->{transaction_id}),
            {
                from_login                => $client_cr_usdc->loginid,
                to_login                  => $client_cr_ust->loginid,
                fees                      => num(3),
                fee_calculated_by_percent => num(3),
                fees_currency             => 'USDC',
                fees_percent              => num(2),
                min_fee                   => num(0.01),
            },
            'metadata saved correctly in transaction_details table for stable to stable transfer'
        );
    };
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
            ->has_no_system_error->has_error->error_code_is('SetExistingAccountCurrency', 'Transfer error as no deposit done')
            ->error_message_is('Please set the currency for your existing account ' . $client_mlt->loginid . ', in order to create more accounts.',
            'Please deposit before transfer.');

        $client_mf->set_default_account('EUR');
        $client_mlt->set_default_account('EUR');

        # some random clients
        $params->{args}->{account_to} = 'MLT999999';
        $rpc_ct->call_ok('transfer_between_accounts', $params)
            ->has_no_system_error->has_error->error_code_is('PermissionDenied', 'Transfer error as wrong to client')
            ->error_message_is('You are not allowed to transfer to this account.', 'Correct error message for transfering to random client');

        $params->{args}->{account_to} = $client_mf->loginid;
        $rpc_ct->call_ok('transfer_between_accounts', $params)
            ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', 'Transfer error as no money in account')
            ->error_message_is('This transaction cannot be done because your ' . $client_mlt->loginid . ' account has zero balance.',
            'Correct error message for account with no money');

        $params->{args}->{amount} = -1;
        $rpc_ct->call_ok('transfer_between_accounts', $params)
            ->has_no_system_error->has_error->error_code_is('TransferInvalidAmount', "Invalid amount")
            ->error_message_is('Please provide valid amount.', 'Correct error message for transfering invalid amount');

        $params->{args}->{amount} = 0;
        $rpc_ct->call_ok('transfer_between_accounts', $params)
            ->has_no_system_error->has_error->error_code_is('TransferInvalidAmount', "Invalid amount")
            ->error_message_is('Please provide valid amount.', 'Correct error message for transfering invalid amount');

        $params->{args}->{amount} = 1;
        $rpc_ct->call_ok('transfer_between_accounts', $params)
            ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', "Invalid amount")
            ->error_message_is('This transaction cannot be done because your ' . $client_mlt->loginid . ' account has zero balance.',
            'Correct error message for transfering invalid amount');
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
        email                 => 'joe@example.com',
        information           => 'Test Info',
        summary               => 'Test Summary',
        commission_deposit    => 0,
        commission_withdrawal => 0,
        status                => 'suspended',
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
        ->error_message_like(qr/Transfers between accounts are currently unavailable/);
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
        cmp_ok $transfer_amount,                         '>=', get_min_unit('BTC'),  'Transfered amount is not less than minimum unit';
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

        cmp_ok $client_cr_usd->account->balance, '==', $previous_amount_usd - $amount,                   'From account deducted correctly';
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

        cmp_ok $client_cr_ust->account->balance, '==', $previous_amount_ust - $amount,                   'From account deducted correctly';
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
        email                 => 'joe@example.com',
        information           => 'Test Info',
        summary               => 'Test Summary',
        commission_deposit    => 0,
        commission_withdrawal => 0,
        currency_code         => 'BTC',
        status                => 'authorized',
    };

    $client_cr_pa_btc->payment_agent($pa_args);
    $client_cr_pa_btc->save();
    #save target countries for PA
    $client_cr_pa_btc->get_payment_agent->set_countries(['id', 'in']);

    $pa_args->{status}        = 'suspended';
    $pa_args->{currency_code} = 'USD';
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

    my $result =
        $rpc_ct->call_ok('transfer_between_accounts', $params)
        ->has_no_system_error->has_error->error_message_is('You are not allowed to transfer to this account.',
        'Transfer from a PA to a non-pa sibling is impossible');

    my $mock_client = Test::MockModule->new('BOM::User::Client');
    $mock_client->redefine(
        get_payment_agent => sub {
            my $mock_pa = Test::MockObject->new;
            $mock_pa->mock(status       => sub { 'authorized' });
            $mock_pa->mock(tier_details => sub { {} });
            return $mock_pa;
        });
    $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_no_error('PA to PA transfer is allowed');

    my $fee_percent     = 0;
    my $transfer_amount = ($amount - $amount * $fee_percent / 100) * 4000;
    cmp_ok $client_cr_pa_btc->default_account->balance, '==', $previous_fm_amt - $amount, 'correct balance after transfer excluding fees';
    cmp_ok $client_cr_usd->default_account->balance, '==', $previous_to_amt + $transfer_amount,
        'authorised pa to pa transfer (BTC to USD), no fees will be charged';
    $mock_client->unmock('get_payment_agent');

    sleep(2);
    $params->{args}->{account_to} = $client_cr_pa_usd->loginid;

    $previous_fm_amt = $client_cr_pa_btc->default_account->balance;
    $previous_to_amt = $client_cr_pa_usd->default_account->balance;

    $rpc_ct->call_ok('transfer_between_accounts', $params)
        ->has_no_system_error->has_error->error_message_is('You are not allowed to transfer to this account.',
        'Transfer from a PA to a non-authorized pa sibling is impossible');

    my $mock_pa = Test::MockModule->new('BOM::User::Client::PaymentAgent');
    $mock_pa->redefine(status => 'authorized');

    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    is $result->{client_to_loginid}, $client_cr_pa_usd->loginid, 'Transaction successful if both sides are payment agents';

    $transfer_amount = ($amount - $amount * $fee_percent / 100) * 4000;
    cmp_ok($client_cr_pa_btc->default_account->balance + 0, '==', ($previous_fm_amt - $amount), 'correct balance after transfer excluding fees');
    cmp_ok $client_cr_pa_usd->default_account->balance + 0, '==', $previous_to_amt + $transfer_amount,
        'authorised pa to authrised pa (BTC to USD), no transaction fee charged';

    $mock_pa->unmock_all;

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
        ->has_no_system_error->has_error->error_code_is('DifferentFiatCurrencies', "fiat->fiat not allowed - correct error code")
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
    BOM::Config::Runtime->instance->app_config->system->suspend->transfer_currency_pair('{"currency_pairs":[["USD","BTC"]]}');
    subtest 'it should stop transfers from suspended currency pairs' => sub {
        $params->{token} = $token_cr_btc;
        $params->{args}  = {
            account_from => $client_cr_btc->loginid,
            account_to   => $client_cr_usd->loginid,
            currency     => "BTC",
            amount       => 0.001
        };

        my $result =
            $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError',
            "Transfer from suspended currency not allowed - correct error code")
            ->error_message_is('Account transfers are not available between BTC and USD',
            'Transfer from suspended currency not allowed - correct error message');

    };
    BOM::Config::Runtime->instance->app_config->system->suspend->transfer_currency_pair('{"currency_pairs":[["BTC","USD"]]}');
    subtest 'it should stop transfers from suspended currency pairs' => sub {
        $params->{token} = $token_cr_btc;
        $params->{args}  = {
            account_from => $client_cr_btc->loginid,
            account_to   => $client_cr_usd->loginid,
            currency     => "BTC",
            amount       => 0.001
        };

        my $result =
            $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError',
            "Transfer from suspended currency not allowed - correct error code")
            ->error_message_is('Account transfers are not available between BTC and USD',
            'Transfer from suspended currency not allowed - correct error message');

    };
    BOM::Config::Runtime->instance->app_config->system->suspend->transfer_currency_pair('{"currency_pairs":[]}');

};

subtest 'MT5' => sub {

    @BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');
    my $mock_account   = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    my $is_fa_complete = 1;
    $mock_account->mock(_is_financial_assessment_complete => sub { return $is_fa_complete });
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
    $user->update_trading_password($DETAILS{password}{main});

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

    $params->{token_type} = 'oauth_token';
    $params->{args}       = {
        account_from => 'MTR' . $ACCOUNTS{'real\p01_ts01\financial\svg_std_usd'},
        account_to   => 'MTR' . $ACCOUNTS{'real\p01_ts01\financial\labuan_stp_usd'},
        currency     => "USD",
        amount       => 180                                                            # this is the only deposit amount allowed by mock MT5
    };

    $rpc_ct->call_ok('transfer_between_accounts', $params)
        ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', 'MT5->MT5 transfer error code')
        ->error_message_is('Transfer between two MT5 accounts is not allowed.', 'MT5->MT5 transfer error message');

    $params->{args}{account_from} = 'MTD' . $ACCOUNTS{'demo\p01_ts01\financial\svg_std_usd'};
    $params->{args}{account_to}   = $test_client->loginid;
    $rpc_ct->call_ok('transfer_between_accounts', $params)
        ->has_no_system_error->has_error->error_code_is('RealToVirtualNotAllowed', 'MT5 demo -> real account transfer error code')
        ->error_message_like(qr/virtual accounts/, 'MT5 demo -> real account transfer error message');

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
        ->has_no_system_error->has_error->error_code_is('WithdrawalLockedStatus', 'Correct error code')->error_message_like(
        qr/You cannot perform this action, as your account is withdrawal locked./,
        'Correct error message returned because Real BTC account is withdrawal locked.'
        );

    #remove withdrawal_locked
    $test_client_btc->status->clear_withdrawal_locked;
    #set cashier_locked status to make sure for Real  -> MT5 transfer is not allowed
    $test_client_btc->status->set('cashier_locked', 'system', 'test');
    ok $test_client_btc->status->cashier_locked, "Real BTC account is cashier_locked";

    $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_error->error_code_is('CashierLocked', 'Correct error code')
        ->error_message_like(
        qr/Your account cashier is locked. Please contact us for more information./,
        'Correct error message returned because Real BTC account is cashier_locked.'
        );
    #remove cashier_locked
    $test_client_btc->status->clear_cashier_locked;

    $params->{args}{account_from} = $test_client->loginid;
    $params->{args}{currency}     = 'USD';
    $params->{args}{amount}       = 180;
    _test_events_prepare();

    $test_client->status->set('disabled', 'system', 'test');
    $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_error->error_code_is('DisabledClient', 'Correct error code')
        ->error_message_like(qr/This account is unavailable./, 'Correct error message for disabled account.');
    $test_client->status->clear_disabled;

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
                    loginid          => 'MTR' . $ACCOUNTS{'real\p01_ts01\financial\svg_std_usd'},
                    balance          => num($DETAILS{balance}),
                    currency         => 'USD',
                    account_type     => 'mt5',
                    account_category => 'trading',
                    demo_account     => 0,
                    mt5_group        => 'real\p01_ts01\financial\svg_std_usd',
                    transfers        => 'all',
                },
                {
                    loginid          => $test_client->loginid,
                    balance          => num(1000 - 180),
                    currency         => 'USD',
                    account_type     => 'binary',
                    account_category => 'trading',
                    demo_account     => 0,
                    transfers        => 'all',
                })});

    cmp_ok $test_client->default_account->balance, '==', 820, 'real money account balance decreased';

    # MT5 -> real
    $mock_client->mock(fully_authenticated => sub { return 0 });

    $params->{args}{account_from} = 'MTR' . $ACCOUNTS{'real\p01_ts01\financial\svg_std_usd'};
    $params->{args}{account_to}   = $test_client->loginid;
    $params->{args}{amount}       = 150;                                                      # this is the only withdrawal amount allowed by mock MT5

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
                    loginid          => 'MTR' . $ACCOUNTS{'real\p01_ts01\financial\svg_std_usd'},
                    balance          => num($DETAILS{balance}),
                    currency         => 'USD',
                    account_type     => 'mt5',
                    demo_account     => 0,
                    mt5_group        => 'real\p01_ts01\financial\svg_std_usd',
                    account_category => 'trading',
                    transfers        => 'all',
                },
                {
                    loginid          => $test_client->loginid,
                    balance          => num(1000 - 30),
                    currency         => 'USD',
                    account_type     => 'binary',
                    demo_account     => 0,
                    account_category => 'trading',
                    transfers        => 'all',
                })
        },
        'expected data in result'
    );

    $test_client->status->clear_transfers_blocked;

    cmp_ok $test_client->default_account->balance, '==', 970, 'real money account balance increased';
    #set cashier locked status to make sure for MT5 -> Real transfer it is failed.
    $test_client->status->set('cashier_locked', 'system', 'test');
    ok $test_client->status->cashier_locked, "Real account is cashier_locked";

    $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_error->error_code_is('CashierLocked', 'Correct error code')
        ->error_message_like(qr/Your account cashier is locked. Please contact us for more information./,
        'Correct error message returned because Real account is cashier_locked so no deposit/withdrawal allowed.');
    #remove cashier_locked
    $test_client->status->clear_cashier_locked;

    $params->{args}{account_from} = 'MTR' . $ACCOUNTS{'real\p01_ts01\financial\labuan_stp_usd'};
    $rpc_ct->call_ok('transfer_between_accounts', $params)
        ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', 'Correct error code')
        ->error_message_like(qr/Proof of Identity or Address requirements not met. Operation rejected./,
        'Error message returned from inner MT5 sub when regulated account has expired documents (labuan case)');

    $expired_documents = 0;

    $rpc_ct->call_ok('transfer_between_accounts', $params)
        ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', 'Correct error code')
        ->error_message_like(qr/Proof of Identity or Address requirements not met. Operation rejected./,
        'Error message returned from inner MT5 sub when regulated binary has no expired documents but does not have valid documents (labuan case)');

    $has_valid_documents = 1;
    $mock_client->mock(fully_authenticated => sub { return 1 });

    $params->{args}{account_from} = $test_client->loginid;
    $params->{args}{account_to}   = 'MTR' . $ACCOUNTS{'real\p01_ts01\financial\labuan_stp_usd'};
    $params->{args}{currency}     = 'EUR';
    $rpc_ct->call_ok('transfer_between_accounts', $params)
        ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', 'Correct error code')
        ->error_message_is('Currency provided is different from account currency.', 'Correct message for wrong currency for real account_from');

    $mock_client->mock(get_poi_status_jurisdiction => sub { return 'verified' });
    $mock_client->mock(get_poa_status              => sub { return 'verified' });

    $params->{args}{account_from} = 'MTR' . $ACCOUNTS{'real\p01_ts01\financial\labuan_stp_usd'};
    $params->{args}{account_to}   = $test_client->loginid;
    $rpc_ct->call_ok('transfer_between_accounts', $params)
        ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', 'Correct error code')
        ->error_message_is('Currency provided is different from account currency.', 'Correct message for wrong currency for MT5 account_from');

    $is_fa_complete = 0;
    $mock_client->mock(has_mt5_deposits => sub { return 1 });    # need this to create the error
    $params->{args}{currency}     = 'USD';
    $params->{args}{account_from} = $test_client->loginid;
    $params->{args}{account_to}   = 'MTR' . $ACCOUNTS{'real\p01_ts01\financial\labuan_stp_usd'};
    $is_fa_complete               = 1;

    subtest 'transfers using an account other than authenticated client' => sub {
        $params->{token} = BOM::Platform::Token::API->new->create_token($test_client_btc->loginid, 'test token');

        $params->{args}{amount}       = 180;
        $params->{args}{account_from} = $test_client->loginid;
        $params->{args}{account_to}   = 'MTR' . $ACCOUNTS{'real\p01_ts01\financial\svg_std_usd'};

        $params->{token_type} = 'oauth_token';
        $rpc_ct->call_ok('transfer_between_accounts', $params)
            ->has_no_system_error->has_no_error('with oauth token, ok if account_from is not the authenticated client');
        $params->{token_type} = 'api_token';
        $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_error->error_message_is(
            "You can only transfer from the current authorized client's account.",
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
            "You can only transfer to the current authorized client's account.",
            'with api token, NOT ok if account_to is not the authenticated client'
        );
    };

    subtest 'transfers using an account less than minimum fee' => sub {
        my $app_config = BOM::Config::Runtime->instance->app_config();

        $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

        $app_config->set({
                'payments.transfer_between_accounts.minimum.MT5' => '{"default":{"currency":"USD","amount":0.01}}',

        });
        $params->{args} = {
            currency     => 'BTC',
            amount       => 0.00000228,
            account_from => $test_client_btc->loginid,
            account_to   => 'MTR' . $ACCOUNTS{'real\p01_ts01\financial\svg_std_usd'}};

        $rpc_ct->call_ok('transfer_between_accounts', $params)
            ->has_no_system_error->has_error->error_message_is(
            "The minimum amount for transfers is 0.00000250 BTC after conversion fees are deducted. Please adjust the amount.",
            'amount not allowed and the amount is not in scientific mode');

        $app_config->set({
            'payments.transfer_between_accounts.minimum.MT5' => '{"default":{"currency":"USD","amount":1}}',
        });

    };

    subtest 'transfer between virtual wallet and demo account is allowed' => sub {
        my $test_wallet_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'VRW',
        });
        $test_wallet_vr->set_default_account('USD');
        $user->add_client($test_wallet_vr);

        my $test_client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'VRTC',
        });
        $test_client_vr->set_default_account('USD');
        $user->add_client($test_client_vr);

        $params->{token}              = BOM::Platform::Token::API->new->create_token($test_client_vr->loginid, _get_unique_display_name());
        $params->{args}{account_from} = $test_client_vr->loginid;
        $params->{args}{account_to}   = 'MTD' . $ACCOUNTS{'demo\p01_ts01\financial\svg_std_usd'};
        $params->{args}{amount}       = 180;
        $params->{args}{currency}     = 'USD';
        $params->{token_type}         = 'api_token';

        $rpc_ct->call_ok('transfer_between_accounts', $params)
            ->has_no_system_error->has_error->error_code_is('TransferBlockedClientIsVirtual', 'virtual account -> MT5 demo transfer error code')
            ->error_message_is('The authorized account cannot be used to perform transfers.', 'virtual account -> MT5 demo transfer error message');

        $params->{args}{account_to}   = $test_client_vr->loginid;
        $params->{args}{account_from} = 'MTD' . $ACCOUNTS{'demo\p01_ts01\financial\svg_std_usd'};

        $rpc_ct->call_ok('transfer_between_accounts', $params)
            ->has_no_system_error->has_error->error_code_is('TransferBlockedClientIsVirtual', 'MT5 demo -> virtual account transfer error code')
            ->error_message_is('The authorized account cannot be used to perform transfers.', 'MT5 demo -> virtual account transfer error message');

        # switch to demo account
        $params->{token}              = BOM::Platform::Token::API->new->create_token($test_wallet_vr->loginid, _get_unique_display_name());
        $params->{args}{account_from} = $test_wallet_vr->loginid;
        $params->{args}{account_to}   = 'MTD' . $ACCOUNTS{'demo\p01_ts01\financial\svg_std_usd'};

        $rpc_ct->call_ok('transfer_between_accounts', $params)
            ->has_no_system_error->has_error->error_code_is('TransferBlockedWalletNotLinked', 'unlinked account error code');

        $user->link_wallet_to_trading_account({
                wallet_id => $test_wallet_vr->loginid,
                client_id => 'MTD' . $ACCOUNTS{'demo\p01_ts01\financial\svg_std_usd'}});

        $rpc_ct->call_ok('transfer_between_accounts', $params)
            ->has_no_system_error->has_error->error_code_is('TransferBetweenAccountsError', 'insufficient virtual balance transfer error code')
            ->error_message_is('This transaction cannot be done because your ' . $test_wallet_vr->loginid . ' account has zero balance.',
            'insufficient virtual balance transfer error message');

        $test_wallet_vr->payment_free_gift(
            currency => 'USD',
            amount   => 180,
            remark   => 'free gift',
        );

        cmp_deeply(
            $rpc_ct->call_ok('transfer_between_accounts', $params)->result,
            {
                status              => 1,
                transaction_id      => ignore(),
                client_to_full_name => $DETAILS{name},
                client_to_loginid   => $params->{args}{account_to},
                stash               => ignore(),
                accounts            => bag({
                        loginid          => 'MTD' . $ACCOUNTS{'demo\p01_ts01\financial\svg_std_usd'},
                        balance          => num($DETAILS{balance}),
                        currency         => 'USD',
                        account_type     => 'mt5',
                        demo_account     => 1,
                        mt5_group        => 'demo\p01_ts01\financial\svg_std_usd',
                        account_category => 'trading',
                        transfers        => 'all',
                    },
                    {
                        loginid          => $test_wallet_vr->loginid,
                        balance          => num(0),
                        currency         => 'USD',
                        account_type     => 'virtual',
                        demo_account     => 1,
                        account_category => 'wallet',
                        transfers        => 'all',
                    })
            },
            'expected data in result'
        );

        $params->{args}{account_to}   = $test_wallet_vr->loginid;
        $params->{args}{account_from} = 'MTD' . $ACCOUNTS{'demo\p01_ts01\financial\svg_std_usd'};
        $params->{args}{amount}       = 150;
        $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_no_error->result;
        cmp_deeply(
            $rpc_ct->result,
            {
                status              => 1,
                transaction_id      => ignore(),
                client_to_full_name => $test_wallet_vr->full_name,
                client_to_loginid   => $test_wallet_vr->loginid,
                stash               => ignore(),
                accounts            => bag({
                        loginid          => 'MTD' . $ACCOUNTS{'demo\p01_ts01\financial\svg_std_usd'},
                        balance          => num($DETAILS{balance}),
                        currency         => 'USD',
                        account_type     => 'mt5',
                        demo_account     => 1,
                        mt5_group        => 'demo\p01_ts01\financial\svg_std_usd',
                        account_category => 'trading',
                        transfers        => 'all',
                    },
                    {
                        loginid          => $test_wallet_vr->loginid,
                        balance          => num(150),
                        currency         => 'USD',
                        account_type     => 'virtual',
                        demo_account     => 1,
                        account_category => 'wallet',
                        transfers        => 'all',
                    })
            },
            'expected data in result'
        );

        subtest 'transfer between virtual wallet and real mt5 will fail' => sub {
            $params->{args}{account_from} = $test_wallet_vr->loginid;
            $params->{args}{account_to}   = 'MTR' . $ACCOUNTS{'real\p01_ts01\financial\svg_std_usd'};

            $rpc_ct->call_ok('transfer_between_accounts', $params)
                ->has_no_system_error->has_error->error_code_is('RealToVirtualNotAllowed', 'virtual walllet -> MT5 real transfer error code')
                ->error_message_is('Transfer between real and virtual accounts is not allowed.',
                'virtual walllet -> MT5 real  transfer error message');

            $params->{args}{account_to}   = $test_wallet_vr->loginid;
            $params->{args}{account_from} = 'MTR' . $ACCOUNTS{'real\p01_ts01\financial\svg_std_usd'};
            $rpc_ct->call_ok('transfer_between_accounts', $params)
                ->has_no_system_error->has_error->error_code_is('RealToVirtualNotAllowed', 'MT5 real -> virtual wallet transfer error code')
                ->error_message_is('Transfer between real and virtual accounts is not allowed.', 'MT5 real -> virtual wallet transfer error message');
        }

    };

};

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
    is $result->{error}->{code}, 'ExchangeRatesUnavailable', 'Correct error code when offer_to_clients fails';
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

subtest 'crypto to crypto limits' => sub {
    my $email = 'new_crypto_to_crypto_transfer_email' . rand(999) . '@sample.com';
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

    my $client_cr_eth = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $email,
        binary_user_id => $test_binary_user_id,
        place_of_birth => 'id',
    });

    $user->add_client($client_cr_btc);
    $user->add_client($client_cr_eth);

    $client_cr_eth->set_default_account('ETH');
    $client_cr_btc->set_default_account('BTC');

    $client_cr_btc->payment_free_gift(
        currency => 'BTC',
        amount   => 2,
        remark   => 'free gift',
    );

    cmp_ok $client_cr_btc->default_account->balance + 0, '==', 2, 'correct balance';

    $client_cr_eth->payment_free_gift(
        currency => 'ETH',
        amount   => 1,
        remark   => 'free gift',
    );
    cmp_ok $client_cr_eth->default_account->balance + 0, '==', 1, 'correct balance';

    $params->{args} = {
        account_from => $client_cr_btc->loginid,
        account_to   => $client_cr_eth->loginid,
        currency     => 'BTC',
        amount       => 1
    };

    my $token = BOM::Platform::Token::API->new->create_token($client_cr_btc->loginid, _get_unique_display_name());
    $params->{token}      = $token;
    $params->{token_type} = 'oauth_token';

    my $mock_client = Test::MockModule->new('BOM::User::Client');
    my $mock_status = Test::MockModule->new('BOM::User::Client::Status');

    my $auth = 1;
    $mock_client->mock('fully_authenticated', sub { $auth; });
    $mock_status->mock(
        'age_verification',
        sub {
            return 0;
        });

    my $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    ok $result->{status}, 'Fully authenticated non age verified transfer is sucessful';

    $auth = 0;

    $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_error->error_code_is('Crypto2CryptoTransferOverLimit',
        'Not verified account should not pass the crypto to crypto limit')
        ->error_message_like(qr/You have exceeded [\d\.]+ BTC in cumulative transactions. To continue, you will need to verify your identity./,
        'Correct error message returned for a crypto to crypto transfer that reached the limit.');

    $mock_status->unmock_all;
    $mock_client->unmock_all;
};

subtest 'crypto to fiat limits' => sub {
    my $email = 'new_crypto_to_fiat_transfer_email' . rand(999) . '@sample.com';
    BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->crypto_to_fiat(1000);
    my $user = BOM::User->create(
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

    $client_cr_btc->set_default_account('BTC');
    $client_cr_usd->set_default_account('USD');

    $client_cr_btc->payment_free_gift(
        currency => 'BTC',
        amount   => 2,
        remark   => 'free gift',
    );
    cmp_ok $client_cr_btc->default_account->balance + 0, '==', 2, 'correct balance';

    $client_cr_usd->payment_free_gift(
        currency => 'USD',
        amount   => 1000,
        remark   => 'free gift',
    );

    cmp_ok $client_cr_usd->default_account->balance + 0, '==', 1000, 'correct balance';

    $params->{args} = {
        account_from => $client_cr_btc->loginid,
        account_to   => $client_cr_usd->loginid,
        currency     => 'BTC',
        amount       => 0.6,
    };

    my $token = BOM::Platform::Token::API->new->create_token($client_cr_btc->loginid, _get_unique_display_name());
    $params->{token}      = $token;
    $params->{token_type} = 'oauth_token';

    my $mock_client = Test::MockModule->new('BOM::User::Client');
    my $mock_status = Test::MockModule->new('BOM::User::Client::Status');

    my $auth = 1;
    $mock_client->mock('fully_authenticated', sub { $auth; });
    $mock_status->mock(
        'age_verification',
        sub {
            return 0;
        });

    my $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;
    ok $result->{status}, 'Fully authenticated non age verified transfer is sucessful';

    $auth = 0;
    $params->{args} = {
        account_from => $client_cr_btc->loginid,
        account_to   => $client_cr_usd->loginid,
        currency     => 'BTC',
        amount       => 0.55,
    };
    $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->has_error->error_code_is('Crypto2FiatTransferOverLimit',
        'Not verified account should not pass the crypto to fiat limit')
        ->error_message_like(qr/You have exceeded [\d\.]+ BTC in cumulative transactions. To continue, you will need to verify your identity./,
        'Correct error message returned for a crypto to fiat transfer that reached the limit.');

    $mock_status->unmock_all;
    $mock_client->unmock_all;
};

subtest 'cumulative_limits limits' => sub {
    my $email = 'cumulative_limits' . rand(999) . '@sample.com';
    BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->between_accounts(2);
    BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->crypto_to_fiat(10000);
    restore_time();
    $redis->hmset(
        'exchange_rates::BTC_USD',
        quote => 1,
        epoch => time
    );
    $redis->hmset(
        'exchange_rates::BTC_USD',
        quote => 1,
        epoch => time
    );
    my $user = BOM::User->create(
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

    $client_cr_btc->set_default_account('BTC');
    $client_cr_usd->set_default_account('USD');

    $client_cr_btc->payment_free_gift(
        currency => 'BTC',
        amount   => 20,
        remark   => 'free gift',
    );
    cmp_ok $client_cr_btc->default_account->balance + 0, '==', 20, 'correct balance';

    $client_cr_usd->payment_free_gift(
        currency => 'USD',
        amount   => 1000,
        remark   => 'free gift',
    );

    cmp_ok $client_cr_usd->default_account->balance + 0, '==', 1000, 'correct balance';

    $params->{args} = {
        account_from => $client_cr_btc->loginid,
        account_to   => $client_cr_usd->loginid,
        currency     => 'BTC',
        amount       => 1.2,
    };

    my $token = BOM::Platform::Token::API->new->create_token($client_cr_btc->loginid, _get_unique_display_name());
    $params->{token}      = $token;
    $params->{token_type} = 'oauth_token';

    my $mock_client = Test::MockModule->new('BOM::User::Client');
    my $mock_status = Test::MockModule->new('BOM::User::Client::Status');

    my $auth = 1;
    $mock_client->mock('fully_authenticated', sub { $auth; });
    $mock_status->mock(
        'age_verification',
        sub {
            return 0;
        });

    my $app_config = BOM::Config::Runtime->instance->app_config();
    $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());
    $app_config->set({
            'payments.transfer_between_accounts.maximum.MT5' => '{"default":{"currency":"USD","amount":2500}}',

    });

    my $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;

    ok $result->{status}, 'Fully authenticated non age verified transfer is sucessful';

    sleep 2;

    $result = $rpc_ct->call_ok('transfer_between_accounts', $params)->has_no_system_error->result;

    sleep 2;
    $result =
        $rpc_ct->call_ok('transfer_between_accounts', $params)
        ->has_no_system_error->has_error->error_code_is('MaximumTransfers', "Daily Transfer limit - correct error code")
        ->error_message_like(qr/2 transfers a day/, 'Daily Transfer Limit - correct error message');

    set_absolute_time(Date::Utility->new('2018-02-15')->epoch);
    $mock_status->unmock_all;
    $mock_client->unmock_all;
};

$documents_mock->unmock_all;

#reset
BOM::Config::Runtime->instance->app_config->system->mt5->load_balance->demo->all->p01_ts02($p01_ts02_load);
BOM::Config::Runtime->instance->app_config->system->mt5->load_balance->demo->all->p01_ts03($p01_ts03_load);

done_testing();

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

sub _get_transaction_details {
    my ($client, $transaction_id) = @_;

    my ($result) = $client->db->dbic->run(
        fixup => sub {
            $_->selectrow_array('select details from transaction.transaction_details where transaction_id = ?', undef, $transaction_id,);
        });
    return JSON::MaybeUTF8::decode_json_utf8($result);
}
