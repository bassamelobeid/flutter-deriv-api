use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Test::MockModule;
use Format::Util::Numbers qw/financialrounding get_min_unit/;
use JSON::MaybeUTF8;
use Date::Utility;
use LandingCompany::Registry;
use BOM::Test::RPC::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Helper::Client qw(create_client top_up);
use BOM::MT5::User::Async;
use BOM::Platform::Token;
use BOM::User;
use BOM::Config::Runtime;
use BOM::Config::Redis;
use BOM::Config::CurrencyConfig;

use Test::BOM::RPC::Accounts;

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC::Transport::HTTP')->app->ua);

my $redis = BOM::Config::Redis::redis_exchangerates_write();

my $manager_module = Test::MockModule->new('BOM::MT5::User::Async');
$manager_module->mock(
    'deposit',
    sub {
        return Future->done({success => 1});
    });

$manager_module->mock(
    'withdrawal',
    sub {
        return Future->done({success => 1});
    });

@BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');

my %ACCOUNTS = %Test::BOM::RPC::Accounts::MT5_ACCOUNTS;
my %DETAILS  = %Test::BOM::RPC::Accounts::ACCOUNT_DETAILS;

# Setup a test user
my $test_client = create_client('CR');
$test_client->email($DETAILS{email});
$test_client->set_default_account('USD');
$test_client->binary_user_id(1);
$test_client->tax_residence('mt');
$test_client->tax_identification_number('111222333');
$test_client->set_authentication('ID_DOCUMENT')->status('pass');
$test_client->save;

my $user = BOM::User->create(
    email    => $DETAILS{email},
    password => 's3kr1t',
);
$user->add_client($test_client);

my $m = BOM::Platform::Token::API->new;
my $token = $m->create_token($test_client->loginid, 'test token');

# Throttle function limits requests to 1 per minute which may cause
# consecutive tests to fail without a reset.
BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

my $params = {
    language => 'EN',
    token    => $token,
    args     => {
        account_type => 'gaming',
        country      => 'mt',
        email        => $DETAILS{email},
        name         => $DETAILS{name},
        mainPassword => $DETAILS{password}{main},
        leverage     => 100,
    },
};
$c->call_ok('mt5_new_account', $params)->has_no_error('no error for mt5_new_account');

sub _get_mt5transfer_from_transaction {
    my ($dbic, $transaction_id) = @_;

    my $result = $dbic->run(
        fixup => sub {
            $_->selectrow_hashref(
                "Select mt.* FROM payment.mt5_transfer mt JOIN transaction.transaction tt
                ON mt.payment_id = tt.payment_id where tt.id = ?",
                undef,
                $transaction_id,
            );
        });
    return $result;
}

subtest 'multi currency transfers' => sub {
    my $client_eur = create_client('CR', undef, {place_of_birth => 'id'});
    my $client_btc = create_client('CR', undef, {place_of_birth => 'id'});
    my $client_ust = create_client('CR', undef, {place_of_birth => 'id'});
    $client_eur->set_default_account('EUR');
    $client_btc->set_default_account('BTC');
    $client_ust->set_default_account('UST');
    top_up $client_eur, EUR => 1000;
    top_up $client_btc, BTC => 1;
    top_up $client_ust, UST => 1000;
    $user->add_client($client_eur);
    $user->add_client($client_btc);
    $user->add_client($client_ust);

    my $eur_test_amount = 100;
    my $btc_test_amount = 0.1;
    my $ust_test_amount = 100;
    my $usd_test_amount = 100;

    my $demo_account_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $demo_account_mock->mock('_fetch_mt5_lc', sub { return LandingCompany::Registry::get('svg'); });

    my $deposit_params = {
        language => 'EN',
        token    => $token,
        args     => {
            from_binary => $client_eur->loginid,
            to_mt5      => 'MTR' . $ACCOUNTS{'real\svg'},
            amount      => $eur_test_amount,
        },
    };

    my $withdraw_params = {
        language => 'EN',
        token    => $token,
        args     => {
            from_mt5  => 'MTR' . $ACCOUNTS{'real\svg'},
            to_binary => $client_eur->loginid,
            amount    => $usd_test_amount,
        },
    };

    my $prev_bal;
    my ($EUR_USD, $BTC_USD, $UST_USD) = (1.1, 5000, 1);

    my ($eur_usd_fee, $btc_usd_fee, $ust_usd_fee) = (0.02, 0.03, 0.04);

    my $after_fiat_fee   = 1 - $eur_usd_fee;
    my $after_crypto_fee = 1 - $btc_usd_fee;
    my $after_stable_fee = 1 - $ust_usd_fee;

    my $mock_fees = Test::MockModule->new('BOM::Config::CurrencyConfig', no_auto => 1);
    $mock_fees->mock(
        transfer_between_accounts_fees => sub {
            return {
                'USD' => {
                    'UST' => $ust_usd_fee * 100,
                    'BTC' => $btc_usd_fee * 100,
                    'EUR' => $eur_usd_fee * 100
                },
                'UST' => {'USD' => $ust_usd_fee * 100},
                'BTC' => {'USD' => $btc_usd_fee * 100},
                'EUR' => {'USD' => $eur_usd_fee * 100}

            };
        });

    subtest 'EUR tests' => sub {
        $manager_module->mock(
            'deposit',
            sub {
                is financialrounding('amount', 'USD', shift->{amount}),
                    financialrounding('amount', 'USD', $eur_test_amount * $EUR_USD * $after_fiat_fee),
                    'Correct forex fee for USD<->EUR';
                return Future->done({success => 1});
            });

        BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

        $client_eur->status->set('no_withdrawal_or_trading', 'system', '..dont like you, sorry.');
        $c->call_ok('mt5_deposit', $deposit_params)
            ->has_error->error_message_is('You cannot perform this action, as your account is withdrawal locked.');
        $client_eur->status->clear_no_withdrawal_or_trading;

        $redis->hmset(
            'exchange_rates::EUR_USD',
            quote => 0,
            epoch => time
        );

        my $mock_date = Test::MockModule->new('Date::Utility');
        $mock_date->mock(
            'is_a_weekend',
            sub {
                return 1;
            });

        $c->call_ok('mt5_deposit', $deposit_params)->has_error->error_message_like(qr/Transfers are unavailable on weekends/);
        $mock_date->mock(
            'is_a_weekend',
            sub {
                return 0;
            });
        $c->call_ok('mt5_deposit', $deposit_params)->has_error->error_message_like(qr/transfers are currently unavailable/);

        $redis->hmset(
            'exchange_rates::EUR_USD',
            quote => $EUR_USD,
            epoch => time
        );
        BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
        $c->call_ok('mt5_deposit', $deposit_params)->has_no_error('deposit EUR->USD with current rate - no error');
        ok(defined $c->result->{binary_transaction_id}, 'deposit EUR->USD with current rate - has transaction id');

        subtest multicurrency_mt5_transfer_deposit => sub {
            my $mt5_transfer = _get_mt5transfer_from_transaction($test_client->db->dbic, $c->result->{binary_transaction_id});
            # (100Eur  * 1%(fee)) * 1.1(Exchange Rate) = 108.9
            is($mt5_transfer->{mt5_amount}, -100 * $after_fiat_fee * $EUR_USD, 'Correct amount recorded');
        };

        $prev_bal = $client_eur->account->balance;
        BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

        $client_eur->status->set('unwelcome', 'system', '..dont like you, sorry.');
        $c->call_ok('mt5_withdrawal', $withdraw_params)->has_error->error_message_is('Your account is restricted to withdrawals only.');
        $client_eur->status->clear_unwelcome;

        $c->call_ok('mt5_withdrawal', $withdraw_params)->has_no_error('withdraw USD->EUR with current rate - no error');
        ok(defined $c->result->{binary_transaction_id}, 'withdraw USD->EUR with current rate - has transaction id');
        is financialrounding('amount', 'EUR', $client_eur->account->balance),
            financialrounding('amount', 'EUR', $prev_bal + ($usd_test_amount / $EUR_USD * $after_fiat_fee)),
            'Correct forex fee for USD<->EUR';

        subtest multicurrency_mt5_transfer_withdrawal => sub {
            my $mt5_transfer = _get_mt5transfer_from_transaction($test_client->db->dbic, $c->result->{binary_transaction_id});
            is($mt5_transfer->{mt5_amount}, 100, 'Correct amount recorded');
        };

        $redis->hmset(
            'exchange_rates::EUR_USD',
            quote => $EUR_USD,
            epoch => time - (3600 * 12));

        BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
        $c->call_ok('mt5_deposit', $deposit_params)->has_no_error('deposit EUR->USD with 12hr old rate - no error');
        ok(defined $c->result->{binary_transaction_id}, 'deposit EUR->USD with 12hr old rate - has transaction id');

        $prev_bal = $client_eur->account->balance;
        BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
        $c->call_ok('mt5_withdrawal', $withdraw_params)->has_no_error('withdraw USD->EUR with current rate - no error');
        ok(defined $c->result->{binary_transaction_id}, 'withdraw USD->EUR with 12hr old rate - has transaction id');
        is financialrounding('amount', 'EUR', $client_eur->account->balance),
            financialrounding('amount', 'EUR', $prev_bal + ($usd_test_amount / $EUR_USD * $after_fiat_fee)),
            'Correct forex fee for USD<->EUR';

        # Expiry date for exchange rates is different in holidays and regular days.
        my $reader   = BOM::Config::Chronicle::get_chronicle_reader;
        my $calendar = Quant::Framework->new->trading_calendar($reader);
        my $exchange = Finance::Exchange->create_exchange('FOREX');
        my $fiat_key = $calendar->is_open($exchange) ? 'fiat' : 'fiat_holidays';
        my $available_hours =
            BOM::Config::Runtime->instance->app_config()->get('payments.transfer_between_accounts.exchange_rate_expiry.' . $fiat_key);
        $redis->hmset(
            'exchange_rates::EUR_USD',
            quote => $EUR_USD,
            epoch => time - ((3600 * $available_hours) + 1));
        BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
        $c->call_ok('mt5_deposit', $deposit_params)->has_error("deposit EUR->USD with >" . $available_hours . " hours old rate - has error")
            ->error_code_is('MT5DepositError', "deposit EUR->USD with >" . $available_hours . " hours old rate - correct error code");

        BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
        $c->call_ok('mt5_withdrawal', $withdraw_params)->has_error("withdraw USD->EUR with >" . $available_hours . " hours old rate - has error")
            ->error_code_is('MT5WithdrawalError', "withdraw USD->EUR with >" . $available_hours . " hours old rate - correct error code");
    };

    subtest 'BTC tests' => sub {

        $manager_module->mock(
            'deposit',
            sub {
                is financialrounding('amount', 'USD', shift->{amount}),
                    financialrounding('amount', 'USD', $btc_test_amount * $BTC_USD * $after_crypto_fee),
                    'Correct forex fee for USD<->BTC';
                return Future->done({success => 1});
            });

        $deposit_params->{args}->{from_binary} = $withdraw_params->{args}->{to_binary} = $client_btc->loginid;
        $deposit_params->{args}->{amount} = $btc_test_amount;

        $redis->hmset(
            'exchange_rates::BTC_USD',
            quote => $BTC_USD,
            epoch => time
        );

        # clear the cache for previous test
        BOM::Config::CurrencyConfig::transfer_between_accounts_limits(1);

        BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
        $c->call_ok('mt5_deposit', $deposit_params)->has_no_error('deposit BTC->USD with current rate - no error');
        ok(defined $c->result->{binary_transaction_id}, 'deposit BTC->USD with current rate - has transaction id');

        $prev_bal = $client_btc->account->balance;
        BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
        $c->call_ok('mt5_withdrawal', $withdraw_params)->has_no_error('withdraw USD->BTC with current rate - no error');
        ok(defined $c->result->{binary_transaction_id}, 'withdraw USD->BTC with current rate - has transaction id');
        is financialrounding('amount', 'BTC', $client_btc->account->balance),
            financialrounding('amount', 'BTC', $prev_bal + ($usd_test_amount / $BTC_USD * $after_crypto_fee)),
            'Correct forex fee for USD<->BTC';

        $redis->hmset(
            'exchange_rates::BTC_USD',
            quote => $BTC_USD,
            epoch => time - 3595
        );

        BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
        $c->call_ok('mt5_deposit', $deposit_params)->has_no_error('deposit BTC->USD with older rate <1 hour - no error');
        ok(defined $c->result->{binary_transaction_id}, 'deposit BTC->USD with older rate <1 hour - has transaction id');

        $prev_bal = $client_btc->account->balance;
        BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
        $c->call_ok('mt5_withdrawal', $withdraw_params)->has_no_error('withdraw USD->BTC with older rate <1 hour - no error');
        ok(defined $c->result->{binary_transaction_id}, 'withdraw USD->BTC with older rate <1 hour - has transaction id');
        is financialrounding('amount', 'BTC', $client_btc->account->balance),
            financialrounding('amount', 'BTC', $prev_bal + ($usd_test_amount / $BTC_USD * $after_crypto_fee)),
            'Correct forex fee for USD<->BTC';

        $redis->hmset(
            'exchange_rates::BTC_USD',
            quote => $BTC_USD,
            epoch => time - 3605
        );

        BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
        $c->call_ok('mt5_deposit', $deposit_params)->has_error('deposit BTC->USD with rate >1 hour old - has error')
            ->error_code_is('MT5DepositError', 'deposit BTC->USD with rate >1 hour old - correct error code');

        BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
        $c->call_ok('mt5_withdrawal', $withdraw_params)->has_error('withdraw USD->BTC with rate >1 hour old - has error')
            ->error_code_is('MT5WithdrawalError', 'withdraw USD->BTC with rate >1 hour old - correct error code');
    };

    subtest 'UST tests' => sub {

        $manager_module->mock(
            'deposit',
            sub {
                is financialrounding('amount', 'USD', shift->{amount}),
                    financialrounding('amount', 'USD', $ust_test_amount * $UST_USD * $after_stable_fee),
                    'Correct forex fee for USD<->UST';
                return Future->done({success => 1});
            });

        $deposit_params->{args}->{from_binary} = $withdraw_params->{args}->{to_binary} = $client_ust->loginid;
        $deposit_params->{args}->{amount} = $ust_test_amount;

        $redis->hmset(
            'exchange_rates::UST_USD',
            quote => $UST_USD,
            epoch => time
        );

        BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
        $c->call_ok('mt5_deposit', $deposit_params)->has_no_error('deposit UST->USD with current rate - no error');
        ok(defined $c->result->{binary_transaction_id}, 'deposit UST->USD with current rate - has transaction id');

        $prev_bal = $client_ust->account->balance;
        BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
        $c->call_ok('mt5_withdrawal', $withdraw_params)->has_no_error('withdraw USD->UST with current rate - no error');
        ok(defined $c->result->{binary_transaction_id}, 'withdraw USD->UST with current rate - has transaction id');
        is financialrounding('amount', 'UST', $client_ust->account->balance),
            financialrounding('amount', 'UST', $prev_bal + ($usd_test_amount / $UST_USD * $after_stable_fee)),
            'Correct forex fee for USD<->UST';

        $redis->hmset(
            'exchange_rates::UST_USD',
            quote => $UST_USD,
            epoch => time - 3595
        );
        BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
        $c->call_ok('mt5_deposit', $deposit_params)->has_no_error('deposit UST->USD with older rate <1 hour - no error');
        ok(defined $c->result->{binary_transaction_id}, 'deposit UST->USD with older rate <1 hour - has transaction id');

        $prev_bal = $client_ust->account->balance;
        BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
        $c->call_ok('mt5_withdrawal', $withdraw_params)->has_no_error('withdraw USD->UST with older rate <1 hour - no error');
        ok(defined $c->result->{binary_transaction_id}, 'withdraw USD->UST with older rate <1 hour - has transaction id');
        is financialrounding('amount', 'UST', $client_ust->account->balance),
            financialrounding('amount', 'UST', $prev_bal + ($usd_test_amount / $UST_USD * $after_stable_fee)),
            'Correct forex fee for USD<->UST';

        $redis->hmset(
            'exchange_rates::UST_USD',
            quote => $UST_USD,
            epoch => time - 3605
        );

        BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
        $c->call_ok('mt5_deposit', $deposit_params)->has_error('deposit UST->USD with rate >1 hour old - has error')
            ->error_code_is('MT5DepositError', 'deposit UST->USD with rate >1 hour old - correct error code');

        BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
        $c->call_ok('mt5_withdrawal', $withdraw_params)->has_error('withdraw USD->UST with rate >1 hour old - has error')
            ->error_code_is('MT5WithdrawalError', 'withdraw USD->UST with rate >1 hour old - correct error code');
    };

    $mock_fees->unmock('transfer_between_accounts_fees');
    $demo_account_mock->unmock;
};

subtest 'Transfers Limits' => sub {
    my $EUR_USD = 1.1;
    $redis->hmset(
        'exchange_rates::EUR_USD',
        quote => $EUR_USD,
        epoch => time
    );

    BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->MT5(0);
    my $client = create_client('CR');
    $client->set_default_account('EUR');
    top_up $client, EUR => 1000;
    $user->add_client($client);

    my $deposit_params = {
        language => 'EN',
        token    => $token,
        args     => {
            from_binary => $client->loginid,
            to_mt5      => 'MTR' . $ACCOUNTS{'real\svg'},
            amount      => 1
        },
    };

    my $demo_account_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $demo_account_mock->mock('_fetch_mt5_lc', sub { return LandingCompany::Registry::get('svg'); });

    $c->call_ok('mt5_deposit', $deposit_params)->has_error('Transfers should have been stopped')
        ->error_code_is('MT5DepositError', 'Transfers limit - correct error code')
        ->error_message_like(qr/0 transfers a day/, 'Transfers limit - correct error message');

    # unlimit the transfers again
    BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->MT5(999);

    $deposit_params->{args}->{amount} = 1 + get_min_unit('EUR') / 10.0;
    $c->call_ok('mt5_deposit', $deposit_params)->has_error('Transfers should have been stopped')
        ->error_code_is('MT5DepositError', 'Transfers limit - correct error code')->error_message_is(
        'Invalid amount. Amount provided can not have more than 2 decimal places.',
        'Transfers amount validation - correct extra decimal error message'
        );

    my $expected_eur_min = financialrounding('amount', 'EUR', 1 / $EUR_USD);    # it is 1 USD converted to EUR

    $deposit_params->{args}->{amount} = $expected_eur_min - get_min_unit('EUR');
    $c->call_ok('mt5_deposit', $deposit_params)->has_error('Transfers should have been stopped')
        ->error_code_is('MT5DepositError', 'Transfers limit - correct error code')
        ->error_message_like(qr/minimum amount for transfers is EUR $expected_eur_min/, 'Transfers minimum - correct error message');

    my $expected_usd_min = BOM::Config::CurrencyConfig::transfer_between_accounts_limits()->{USD}->{min};

    my $withdraw_params = {
        language => 'EN',
        token    => $token,
        args     => {
            from_mt5  => 'MTR' . $ACCOUNTS{'real\svg'},
            to_binary => $client->loginid,
            amount    => 0.5,
        },
    };

    $c->call_ok('mt5_withdrawal', $withdraw_params)->has_error('Transfers should have been stopped')
        ->error_code_is('MT5WithdrawalError', 'Less than minimum amount - correct error code')
        ->error_message_like(qr/minimum amount for transfers is USD $expected_usd_min/, 'InvalidMinAmount - correct error message');

    $demo_account_mock->unmock;
};

subtest 'Suspended Transfers Currencies' => sub {
    BOM::Config::Runtime->instance->app_config->system->suspend->transfer_currencies(['BTC']);
    my $client_cr_btc = create_client('CR');
    $client_cr_btc->set_default_account('BTC');
    top_up $client_cr_btc, BTC => 10;
    $user->add_client($client_cr_btc);

    my $demo_account_mock = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $demo_account_mock->mock('_fetch_mt5_lc', sub { return LandingCompany::Registry::get('svg'); });

    subtest 'it should stop transfer from suspended currency' => sub {
        my $deposit_params = {
            language => 'EN',
            token    => $token,
            args     => {
                from_binary => $client_cr_btc->loginid,
                to_mt5      => 'MTR' . $ACCOUNTS{'real\svg'},
                amount      => 1
            },
        };

        $c->call_ok('mt5_deposit', $deposit_params)->has_error('Transfers should have been stopped')
            ->error_code_is('MT5DepositError', 'Transfer from suspended currency not allowed - correct error code')
            ->error_message_like(qr/BTC and USD are currently unavailable/, 'Transfer from suspended currency not allowed - correct error message');

    };
    BOM::Config::Runtime->instance->app_config->system->suspend->transfer_currencies([]);
    $demo_account_mock->unmock;
};

done_testing();
