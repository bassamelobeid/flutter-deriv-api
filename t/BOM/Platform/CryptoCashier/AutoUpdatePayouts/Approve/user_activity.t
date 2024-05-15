use strict;
use warnings;
no indirect;

use Test::More;
use Test::Exception;
use Test::Fatal;
use Test::MockModule;
use Test::Deep;

use Log::Any::Test;
use Log::Any qw($log);

use BOM::Config::Runtime;
use BOM::Platform::CryptoCashier::AutoUpdatePayouts::Approve;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Utility                 qw(random_email_address);
use BOM::User;

my $mock_user        = Test::MockModule->new('BOM::User');
my $mock_autoupdate  = Test::MockModule->new('BOM::Platform::CryptoCashier::AutoUpdatePayouts');
my $mock             = Test::MockModule->new('BOM::Platform::CryptoCashier::AutoUpdatePayouts::Approve');
my $auto_approve_obj = BOM::Platform::CryptoCashier::AutoUpdatePayouts::Approve->new(broker_code => 'CR');

my $app_config = BOM::Config::Runtime->instance->app_config;

my $default_lookback_time_trading_activity = $app_config->payments->crypto->auto_update->lookback_time_trading_activity;
my $default_max_profit_limit_day           = $app_config->payments->crypto->auto_update->max_profit_limit->day;
my $default_max_profit_limit_month         = $app_config->payments->crypto->auto_update->max_profit_limit->month;
my $default_max_cfd_net_transfer_limit     = $app_config->payments->crypto->auto_update->max_cfd_net_transfer_limit;
my $default_lookback_time_cfd_net_transfer = $app_config->payments->crypto->auto_update->lookback_time_cfd_net_transfer;

$app_config->payments->crypto->auto_update->lookback_time_trading_activity(180);
$app_config->payments->crypto->auto_update->max_profit_limit->day(1000);
$app_config->payments->crypto->auto_update->max_profit_limit->month(5000);
$app_config->payments->crypto->auto_update->max_cfd_net_transfer_limit(5000);
$app_config->payments->crypto->auto_update->lookback_time_cfd_net_transfer(180);

$mock_autoupdate->mock(
    get_client_balance    => sub { 9999 },
    get_net_cfd_transfers => sub { 1 });
my $user_email = random_email_address;
my $dummy_user = BOM::User->create(
    email    => $user_email,
    password => 'test',
);
my $clients = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code        => 'CR',
    email              => $user_email,
    date_joined        => '2000-01-02',
    myaffiliates_token => 'token1',
    residence          => 'id',
    binary_user_id     => $dummy_user->id,
});

$clients->account('BTC');
my $client_loginid = $clients->loginid;

sub mock_rule {
    my $mock  = shift;    #mocked ref for BOM::Platform::CryptoCashier::AutoUpdatePayouts::Approve
    my $rules = shift;    #rules array
    for my $rule ($rules->@*) {
        $mock->mock(
            "$rule" => sub {
                return undef;
            },
        );
    }
}

sub mock_all_rule_except_in_param {
    my $mock             = shift;    #mocked ref for BOM::Platform::CryptoCashier::AutoUpdatePayouts::Approve
    my $rule_not_to_mock = shift;    #rule not to mock, i.e being tested

    #todo: temporary work around, need more refractoring, all rules should be provided by a separate subroutine in Approve package.
    my @all_rules = (
        '_rule_insufficient_balance',
        '_rule_client_auto_approval_disabled',
        '_rule_empty_amount_no_exchange_rates',
        '_rule_amount_above_threshold',
        '_rule_client_status_restricted',
        '_rule_max_profit_limit',
        '_rule_low_trade_recent_deposit',
        '_rule_low_trade_recent_net_cfd_deposit',
        '_rule_low_trade_for_timerange',
        '_rule_cfd_net_transfers',
        '_rule_no_recent_payment',
        '_rule_no_crypto_currency_deposit',
        '_rule_acceptable_net_deposit'

    );

    for my $rule (@all_rules) {
        $mock->mock(
            "$rule" => sub {
                return undef;
            },
        ) unless $rule_not_to_mock eq $rule;
    }
}
# We are initially mocking this to a high value so that tests not related to trade should pass this.

subtest 'BOM::Platform::CryptoCashier::AutoUpdatePayouts::Approve->user_activity' => sub {
    subtest "ACCEPTABLE_NET_DEPOSIT" => sub {
        mock_rule($mock, ['_rule_low_trade_recent_deposit', '_rule_low_trade_recent_net_cfd_deposit']);
        $mock->mock(user_restricted => sub { return undef });
        $mock->mock(
            user_payment_details => sub {
                return {};
            });

        my $response = $auto_approve_obj->user_activity(
            binary_user_id          => $dummy_user->id,
            client_loginid          => $client_loginid,
            total_withdrawal_amount => undef
        );

        is_deeply(
            $response,
            {
                auto_approve                         => 0,
                tag                                  => 'EMPTY_AMOUNT_NO_EXCHANGE_RATES',
                total_withdrawal_amount_today_in_usd => 0,
            },
            "returns tag: EMPTY_AMOUNT_NO_EXCHANGE_RATES"
        );

        $mock->unmock_all();
    };
    subtest "CLIENT_STATUS_RESTRICTED" => sub {
        mock_rule($mock, ['_rule_low_trade_recent_deposit', '_rule_low_trade_recent_net_cfd_deposit']);

        for my $restricted_status (qw/cashier_locked disabled no_withdrawal_or_trading withdrawal_locked duplicate_account closed unwelcome/) {
            $mock->mock(
                user_restricted => sub {
                    return {status_code => $restricted_status};
                });

            is_deeply(
                $auto_approve_obj->user_activity(
                    binary_user_id                => $dummy_user->id,
                    client_loginid                => $client_loginid,
                    total_withdrawal_amount       => 2,
                    total_withdrawal_amount_today => 4
                ),
                {
                    auto_approve                         => 0,
                    tag                                  => 'CLIENT_STATUS_RESTRICTED',
                    restricted_status                    => $restricted_status,
                    total_withdrawal_amount_today_in_usd => 4,
                },
                "returns tag CLIENT_STATUS_RESTRICTED for status $restricted_status"
            );
        }

        $mock->unmock_all();
    };
    subtest "NO_CRYPTOCURRENCY_DEPOSIT" => sub {
        mock_rule($mock, ['_rule_low_trade_recent_deposit', '_rule_low_trade_recent_net_cfd_deposit']);

        $mock->mock(
            user_restricted => sub {
                return undef;
            },
            get_client_profit => sub {
                return 0;
            },
            get_client_trading_activity => sub {
                return 0;
            },
            get_crypto_account_total_deposit_amount => sub {
                return 0;
            },
        );

        $mock->mock(
            user_payment_details => sub {
                return {
                    count    => 1,
                    payments => [{
                            total_deposit_in_usd    => 34.59,
                            total_withdrawal_in_usd => -15.00,
                            net_deposit             => 19.59,
                            currency_code           => "USD",
                            is_reversible           => 0,
                            p_method                => 'payment_agent_transfer',
                            payment_time            => "2020-10-20 21:36:31",
                            is_stable_method        => 1
                        }
                    ],
                    total_crypto_deposits             => 35,
                    non_crypto_deposit_amount         => 34.59,
                    non_crypto_withdraw_amount        => -15,
                    currency_wise_crypto_net_deposits => {
                        ETH => 17.00,
                        BTC => 18.00,
                    },
                    method_wise_net_deposits => {payment_agent_transfer => 19.59}};
            });

        is_deeply(
            $auto_approve_obj->user_activity(
                binary_user_id                => $dummy_user->id,
                client_loginid                => $client_loginid,
                total_withdrawal_amount       => 1,
                total_withdrawal_amount_today => 4,
                currency_code                 => 'BTC'
            ),
            {
                auto_approve                         => 0,
                tag                                  => 'NO_CRYPTOCURRENCY_DEPOSIT',
                total_withdrawal_amount_today_in_usd => 4,
            },
            "returns tag: NO_CRYPTOCURRENCY_DEPOSIT as net deposit of payment_agent_transfer is greater than ETH deposit"
        );

        $mock->mock(
            user_payment_details => sub {
                return {
                    count    => 2,
                    payments => [{
                            total_deposit_in_usd    => 10.1,
                            total_withdrawal_in_usd => 0,
                            net_deposit             => 10.1,
                            currency_code           => "USD",
                            is_reversible           => 0,
                            p_method                => 'payment_agent_transfer',
                            payment_time            => "2020-10-20 21:36:31",
                            is_stable_method        => 1
                        },
                        {
                            total_deposit_in_usd    => 20,
                            total_withdrawal_in_usd => 0,
                            net_deposit             => 20,
                            currency_code           => "USD",
                            is_reversible           => 0,
                            p_method                => 'p2p',
                            payment_time            => "2020-10-20 21:36:31",
                            is_stable_method        => 1
                        }
                    ],
                    total_crypto_deposits             => 43,
                    non_crypto_deposit_amount         => 30.1,
                    non_crypto_withdraw_amount        => 0,
                    currency_wise_crypto_net_deposits => {
                        ETH => 25,
                        BTC => 18.00
                    },
                    method_wise_net_deposits => {
                        payment_agent_transfer => 10.1,
                        p2p                    => 20
                    }};
            });

        is_deeply(
            $auto_approve_obj->user_activity(
                binary_user_id                => $dummy_user->id,
                client_loginid                => $client_loginid,
                total_withdrawal_amount       => 1,
                total_withdrawal_amount_today => 4,
                currency_code                 => 'BTC'
            ),
            {
                auto_approve                         => 0,
                tag                                  => 'NO_CRYPTOCURRENCY_DEPOSIT',
                total_withdrawal_amount_today_in_usd => 4,
            },
            "returns tag: NO_CRYPTOCURRENCY_DEPOSIT as net deposit of p2p is greater than BTC deposit"
        );

        $mock->mock(
            user_payment_details => sub {
                return {
                    count    => 2,
                    payments => [{
                            total_deposit_in_usd    => 11,
                            total_withdrawal_in_usd => 0,
                            net_deposit             => 10.1,
                            currency_code           => "USD",
                            is_reversible           => 0,
                            p_method                => 'payment_agent_transfer',
                            payment_time            => "2020-10-20 21:36:31",
                            is_stable_method        => 1
                        },
                        {
                            total_deposit_in_usd    => 5,
                            total_withdrawal_in_usd => 0,
                            net_deposit             => 5,
                            currency_code           => "USD",
                            is_reversible           => 0,
                            p_method                => 'p2p',
                            payment_time            => "2020-10-20 21:36:31",
                            is_stable_method        => 1
                        },
                        {
                            total_deposit_in_usd    => 19,
                            total_withdrawal_in_usd => 0,
                            net_deposit             => 19,
                            currency_code           => "USD",
                            is_reversible           => 0,
                            p_method                => 'Skrill',
                            payment_time            => "2020-10-20 21:36:31",
                            is_stable_method        => 1
                        }
                    ],
                    total_crypto_deposits             => 34,
                    non_crypto_deposit_amount         => 35,
                    non_crypto_withdraw_amount        => 0,
                    currency_wise_crypto_net_deposits => {
                        ETH => 25,
                        BTC => 18.00
                    },
                    method_wise_net_deposits => {
                        payment_agent_transfer => 11,
                        p2p                    => 5,
                        Skrill                 => 19
                    }};
            });

        is_deeply(
            $auto_approve_obj->user_activity(
                binary_user_id                => $dummy_user->id,
                client_loginid                => $client_loginid,
                total_withdrawal_amount       => 1,
                total_withdrawal_amount_today => 4,
                currency_code                 => 'BTC'
            ),
            {
                auto_approve                         => 0,
                tag                                  => 'NO_CRYPTOCURRENCY_DEPOSIT',
                total_withdrawal_amount_today_in_usd => 4,
            },
            "returns tag: NO_CRYPTOCURRENCY_DEPOSIT as sum of doughflow deposits is greater than BTC deposit"
        );

        $mock->unmock_all();
    };
    subtest "NO_RECENT_PAYMENT" => sub {
        mock_rule($mock, ['_rule_low_trade_recent_deposit', '_rule_low_trade_recent_net_cfd_deposit']);

        $mock->mock(
            user_restricted => sub {
                return undef;
            },
            get_client_profit => sub {
                return 0;
            },
            get_client_trading_activity => sub {
                return 0;
            },
            get_crypto_account_total_deposit_amount => sub {
                return 0;
            },
        );

        $mock->mock(
            user_payment_details => sub {
                return {
                    count                             => 0,
                    total_crypto_deposits             => 43,
                    non_crypto_deposit_amount         => 0,
                    non_crypto_withdraw_amount        => 0,
                    currency_wise_crypto_net_deposits => {
                        ETH => 25,
                        BTC => 18.00
                    },
                    method_wise_net_deposits => {}};
            });

        is_deeply(
            $auto_approve_obj->user_activity(
                binary_user_id                => $dummy_user->id,
                client_loginid                => $client_loginid,
                total_withdrawal_amount       => 1,
                total_withdrawal_amount_today => 4,
                currency_code                 => 'BTC'
            ),
            {
                auto_approve                         => 1,
                tag                                  => 'NO_RECENT_PAYMENT',
                total_withdrawal_amount_today_in_usd => 4,
            },
            "returns tag: NO_RECENT_PAYMENT"
        );

        $mock->mock(
            user_payment_details => sub {
                return {
                    count                             => 0,
                    currency_wise_crypto_net_deposits => {},
                    total_crypto_deposits             => 0,
                    non_crypto_deposit_amount         => 0,
                    non_crypto_withdraw_amount        => 0,
                    method_wise_net_deposits          => {}};
            });

        is_deeply(
            $auto_approve_obj->user_activity(
                binary_user_id                => $dummy_user->id,
                client_loginid                => $client_loginid,
                total_withdrawal_amount       => 1,
                total_withdrawal_amount_today => 4,
                currency_code                 => 'BTC'
            ),
            {
                auto_approve                         => 1,
                tag                                  => 'NO_RECENT_PAYMENT',
                total_withdrawal_amount_today_in_usd => 4,
            },
            "returns tag: NO_RECENT_PAYMENT when no payments from all methods for last 6 months"
        );
        $mock->unmock_all();
    };
    $auto_approve_obj = BOM::Platform::CryptoCashier::AutoUpdatePayouts::Approve->new(
        broker_code              => 'CR',
        threshold_amount         => 1,
        threshold_amount_per_day => 2
    );
    subtest "does not approve with tag AMOUNT_ABOVE_THRESHOLD when the total withdrawal amount is > than the configured threshold amount" => sub {
        mock_rule($mock, ['_rule_low_trade_recent_deposit', '_rule_low_trade_recent_net_cfd_deposit']);

        $mock->mock(
            user_restricted                         => sub { return undef; },
            get_client_profit                       => sub { return 0; },
            get_client_trading_activity             => sub { return 0 },
            get_crypto_account_total_deposit_amount => sub { return 0 });
        $mock->mock(
            user_payment_details => sub {
                return {
                    count                   => 1,
                    has_reversible_payment  => 1,
                    last_reversible_deposit => {
                        total_deposit_in_usd    => 56,
                        total_withdrawal_in_usd => 0,
                        net_deposit             => 56,
                        currency_code           => "ETH",
                        is_reversible           => 1,
                        p_method                => 'WireCard',
                        payment_time            => "2020-10-20 21:36:31",
                        is_stable_method        => 0
                    },
                    reversible_deposit_amount  => 56,
                    reversible_withdraw_amount => 56
                };
            });

        is_deeply(
            $auto_approve_obj->user_activity(
                binary_user_id          => $dummy_user->id,
                client_loginid          => $client_loginid,
                total_withdrawal_amount => 2,
                currency_code           => 'BTC'
            ),
            {
                auto_approve                         => 0,
                tag                                  => 'AMOUNT_ABOVE_THRESHOLD',
                total_withdrawal_amount_today_in_usd => 0,
            },
            "returns tag: AMOUNT_ABOVE_THRESHOLD"
        );

        is_deeply(
            $auto_approve_obj->user_activity(
                binary_user_id                => $dummy_user->id,
                client_loginid                => $client_loginid,
                threshold_amount              => 1,
                threshold_amount_per_day      => 2,
                total_withdrawal_amount       => 1,
                total_withdrawal_amount_today => 4
            ),
            {
                auto_approve                         => 0,
                tag                                  => 'AMOUNT_ABOVE_THRESHOLD',
                total_withdrawal_amount_today_in_usd => 4,
            },
            "client exceeded total withdrawa amount per day returns tag: AMOUNT_ABOVE_THRESHOLD"
        );

        $mock->unmock_all();
    };
    $auto_approve_obj = BOM::Platform::CryptoCashier::AutoUpdatePayouts::Approve->new(
        broker_code              => 'CR',
        threshold_amount         => 1,
        threshold_amount_per_day => 2,
        allowed_above_threshold  => 1
    );

    subtest "does not check for amount above threshold when the flag `allowed_above_threshold` is 1" => sub {
        mock_rule($mock, ['_rule_low_trade_recent_deposit', '_rule_low_trade_recent_net_cfd_deposit']);

        $mock->mock(
            user_restricted                         => sub { return undef; },
            get_client_profit                       => sub { return 0; },
            get_client_trading_activity             => sub { return 0 },
            get_crypto_account_total_deposit_amount => sub { return 0 });
        $mock->mock(
            user_payment_details => sub {
                return {
                    count                      => 1,
                    has_reversible_payment     => 1,
                    total_crypto_deposits      => 0,
                    non_crypto_deposit_amount  => 0,
                    non_crypto_withdraw_amount => 0,
                    last_reversible_deposit    => {
                        payment_time  => undef,
                        amount        => 0.5,
                        amount_in_usd => 56,
                        currency_code => 'ETH'
                    },
                    reversible_deposit_amount  => 0.5,
                    reversible_withdraw_amount => 0.5
                };
            });

        my $response = $auto_approve_obj->user_activity(
            binary_user_id          => $dummy_user->id,
            client_loginid          => $client_loginid,
            total_withdrawal_amount => 2,
            currency_code           => 'BTC'
        );

        isnt($response->{tag}, 'AMOUNT_ABOVE_THRESHOLD');

        $mock->unmock_all();
    };

    subtest "ACCEPTABLE_NET_DEPOSITS" => sub {
        mock_rule($mock, ['_rule_low_trade_recent_deposit', '_rule_low_trade_recent_net_cfd_deposit']);

        $mock->mock(
            user_restricted                         => sub { return undef; },
            get_client_profit                       => sub { return 0; },
            get_client_trading_activity             => sub { return 0 },
            get_crypto_account_total_deposit_amount => sub { return 0 });
        $mock->mock(
            user_payment_details => sub {
                return {
                    count                      => 1,
                    total_crypto_deposits      => 0,
                    non_crypto_deposit_amount  => 50,
                    non_crypto_withdraw_amount => 0,
                    has_reversible_payment     => 1,
                    last_reversible_deposit    => {
                        total_deposit_in_usd    => 50,
                        total_withdrawal_in_usd => 0,
                        net_deposit             => 50,
                        currency_code           => "ETH",
                        is_reversible           => 1,
                        p_method                => 'WireCard',
                        payment_time            => "2020-10-20 21:36:31",
                        is_stable_method        => 0
                    },
                    reversible_deposit_amount  => 50,
                    reversible_withdraw_amount => 49
                };
            });

        my $response = $auto_approve_obj->user_activity(
            binary_user_id                => $dummy_user->id,
            client_loginid                => $client_loginid,
            total_withdrawal_amount       => 2,
            total_withdrawal_amount_today => 2,
            currency_code                 => 'BTC'
        );

        is_deeply(
            $response,
            {
                auto_approve                         => 1,
                last_reversible_deposit_currency     => "ETH",
                last_reversible_deposit_date         => "2020-10-20 21:36:31",
                reversible_deposit_amount            => 50,
                reversible_withdraw_amount           => 49,
                risk_percentage                      => 2,
                tag                                  => 'ACCEPTABLE_NET_DEPOSIT',
                total_withdrawal_amount_today_in_usd => 2,
            },
            "returns tag: ACCEPTABLE_NET_DEPOSITS"
        );

        $mock->unmock_all();
    };

    subtest "RISK_ABOVE_ACCEPTABLE_LIMIT" => sub {
        mock_rule($mock, ['_rule_low_trade_recent_deposit', '_rule_low_trade_recent_net_cfd_deposit']);

        $mock->mock(
            user_restricted                         => sub { return undef; },
            get_client_profit                       => sub { return 0; },
            get_client_trading_activity             => sub { return 0 },
            get_crypto_account_total_deposit_amount => sub { return 0 });
        $mock->mock(
            user_payment_details => sub {
                return {
                    count                      => 1,
                    total_crypto_deposits      => 0,
                    non_crypto_deposit_amount  => 50,
                    non_crypto_withdraw_amount => 0,
                    has_reversible_payment     => 1,
                    last_reversible_deposit    => {
                        total_deposit_in_usd    => 50,
                        total_withdrawal_in_usd => 0,
                        net_deposit             => 50,
                        currency_code           => "ETH",
                        is_reversible           => 1,
                        p_method                => 'MasterCard',
                        payment_time            => "2020-10-20 21:36:31",
                    },
                    reversible_deposit_amount  => 50,
                    reversible_withdraw_amount => 20
                };
            });

        my $response = $auto_approve_obj->user_activity(
            binary_user_id                => $dummy_user->id,
            client_loginid                => $client_loginid,
            total_withdrawal_amount       => 2,
            total_withdrawal_amount_today => 2,
            currency_code                 => 'BTC'
        );

        is_deeply(
            $response,
            {
                auto_approve                         => 0,
                last_reversible_deposit_currency     => "ETH",
                last_reversible_deposit_date         => "2020-10-20 21:36:31",
                reversible_deposit_amount            => 50,
                reversible_withdraw_amount           => 20,
                risk_percentage                      => 60,
                tag                                  => 'RISK_ABOVE_ACCEPTABLE_LIMIT',
                total_withdrawal_amount_today_in_usd => 2,
            },
            "returns tag: RISK_ABOVE_ACCEPTABLE_LIMIT"
        );

        $mock->unmock_all();
    };

    subtest "only payment agent transfers" => sub {
        mock_rule($mock, ['_rule_low_trade_recent_deposit', '_rule_low_trade_recent_net_cfd_deposit']);

        $mock->mock(
            user_restricted                         => sub { return undef; },
            get_client_profit                       => sub { return 0; },
            get_client_trading_activity             => sub { return 0 },
            get_crypto_account_total_deposit_amount => sub { return 0 });
        $mock->mock(
            user_payment_details => sub {
                return {
                    count                      => 1,
                    has_reversible_payment     => 0,
                    last_reversible_deposit    => undef,
                    reversible_deposit_amount  => 0,
                    reversible_withdraw_amount => 0,
                    non_crypto_deposit_amount  => 100,
                    non_crypto_withdraw_amount => 50,
                    total_crypto_deposits      => 0,

                };
            });
        my $response = $auto_approve_obj->user_activity(
            binary_user_id                => $dummy_user->id,
            client_loginid                => $client_loginid,
            total_withdrawal_amount       => 2,
            total_withdrawal_amount_today => 2,
            currency_code                 => 'BTC'
        );
        is_deeply(
            $response,
            {
                auto_approve                         => 0,
                tag                                  => 'RISK_ABOVE_ACCEPTABLE_LIMIT',
                risk_percentage                      => 50,
                total_withdrawal_amount_today_in_usd => 2,
            },
            "returns tag: RISK_ABOVE_ACCEPTABLE_LIMIT"
        );
        $auto_approve_obj = BOM::Platform::CryptoCashier::AutoUpdatePayouts::Approve->new(
            broker_code           => 'CR',
            acceptable_percentage => 60
        );
        $response = $auto_approve_obj->user_activity(
            binary_user_id                => $dummy_user->id,
            client_loginid                => $client_loginid,
            total_withdrawal_amount       => 2,
            total_withdrawal_amount_today => 2,
            currency_code                 => 'BTC'
        );
        is_deeply(
            $response,
            {
                auto_approve                         => 1,
                tag                                  => 'ACCEPTABLE_NET_DEPOSIT',
                risk_percentage                      => 50,
                total_withdrawal_amount_today_in_usd => 2,
            },
            "returns tag: ACCEPTABLE_NET_DEPOSIT"
        );

        $mock->unmock_all();
    };

    $auto_approve_obj = BOM::Platform::CryptoCashier::AutoUpdatePayouts::Approve->new(
        broker_code             => 'CR',
        allowed_above_threshold => 1
    );

    subtest 'INSUFFICIENT_BALANCE' => sub {
        mock_rule($mock, ['_rule_low_trade_recent_deposit', '_rule_low_trade_recent_net_cfd_deposit']);

        $mock_autoupdate->mock(get_client_balance => sub { 0.99 });
        $mock->mock(
            user_payment_details => sub {
                return {
                    count                             => 2,
                    currency_wise_crypto_net_deposits => {
                        BTC => 1,
                    },
                    payments => [{
                            total_deposit_in_usd    => 15.00,
                            total_withdrawal_in_usd => 0.00,
                            net_deposit             => 15.00,
                            currency_code           => 'USD',
                            is_reversible           => 1,
                            p_method                => 'Skrill',
                            payment_time            => '2020-10-20 21:36:31',
                            is_stable_method        => 1
                        },
                    ],
                    has_stable_method_deposits => 1,
                    method_wise_net_deposits   => {
                        Skrill => -15,
                    },
                };
            },
        );

        is_deeply(
            $auto_approve_obj->user_activity(
                binary_user_id              => $dummy_user->id,
                client_loginid              => $client_loginid,
                total_withdrawal_amount     => 2,
                currency_code               => 'BTC',
                withdrawal_amount_in_crypto => 1,
            ),
            {
                auto_approve                         => 0,
                tag                                  => 'INSUFFICIENT_BALANCE',
                total_withdrawal_amount_today_in_usd => 0,
            },
            'returns tag: INSUFFICIENT_BALANCE and does not approve'
        );

        $mock->unmock_all();
    };

    subtest 'user profit evaluation' => sub {
        mock_rule($mock, ['_rule_low_trade_recent_deposit', '_rule_low_trade_recent_net_cfd_deposit']);

        dies_ok { $auto_approve_obj->get_client_profit('CR001', 'week') } 'dies when invalid timeframe is passed';

        $mock_autoupdate->mock(
            get_client_balance                      => sub { 0.99 },
            get_client_trading_activity             => sub { return 0 },
            get_crypto_account_total_deposit_amount => sub { return 0 });
        $mock_autoupdate->mock(
            'get_client_profit',
            sub {
                my ($self, $client_loginid, $timeframe) = @_;
                return $timeframe eq 'day' ? 2000 : 3000;
            });
        is_deeply(
            $auto_approve_obj->user_activity(
                binary_user_id                => $dummy_user->id,
                client_loginid                => $client_loginid,
                total_withdrawal_amount       => 2,
                total_withdrawal_amount_today => 4
            ),
            {
                auto_approve                         => 0,
                tag                                  => 'ABOVE_MAX_PROFIT_LIMIT_FOR_DAY',
                total_withdrawal_amount_today_in_usd => 4,
            },
            "returns tag ABOVE_MAX_PROFIT_LIMIT_FOR_DAY"
        );

        $mock_autoupdate->mock(
            'get_client_profit',
            sub {
                my ($self, $client_loginid, $timeframe) = @_;
                return $timeframe eq 'day' ? 999 : 5100;
            });

        is_deeply(
            $auto_approve_obj->user_activity(
                binary_user_id                => $dummy_user->id,
                client_loginid                => $client_loginid,
                total_withdrawal_amount       => 2,
                total_withdrawal_amount_today => 4
            ),
            {
                auto_approve                         => 0,
                tag                                  => 'ABOVE_MAX_PROFIT_LIMIT_FOR_MONTH',
                total_withdrawal_amount_today_in_usd => 4,
            },
            "returns tag ABOVE_MAX_PROFIT_LIMIT_FOR_MONTH"
        );
        $mock->unmock_all();
    };

    subtest "rule_cfd_net_transfers" => sub {
        mock_rule($mock, ['_rule_low_trade_recent_deposit', '_rule_low_trade_recent_net_cfd_deposit']);

        $mock_autoupdate->mock(get_net_cfd_transfers => sub { 6000 });

        $mock->mock(
            user_restricted => sub {
                return undef;
            },
            get_client_profit => sub {
                return 0;
            },
            get_client_trading_activity             => sub { return 0 },
            get_crypto_account_total_deposit_amount => sub { return 0 });

        $mock->mock(
            user_payment_details => sub {
                return {
                    count                             => 0,
                    currency_wise_crypto_net_deposits => {},
                    total_crypto_deposits             => 0,
                    non_crypto_deposit_amount         => 0,
                    non_crypto_withdraw_amount        => 0,
                    method_wise_net_deposits          => {}};
            });

        my $response = $auto_approve_obj->user_activity(
            binary_user_id          => $dummy_user->id,
            client_loginid          => $client_loginid,
            total_withdrawal_amount => 2,
        );

        is_deeply(
            $response,
            {
                auto_approve                         => 0,
                tag                                  => 'ABOVE_MAX_CFD_NET_TRANSFER_LIMIT',
                total_withdrawal_amount_today_in_usd => 0,
            },
            "returns tag: ABOVE_MAX_CFD_NET_TRANSFER_LIMIT correclty."
        );

        $mock_autoupdate->mock(get_net_cfd_transfers => sub { -1 });

        $response = $auto_approve_obj->user_activity(
            binary_user_id          => $dummy_user->id,
            client_loginid          => $client_loginid,
            total_withdrawal_amount => 2,
        );

        is_deeply(
            $response,
            {
                auto_approve                         => 0,
                tag                                  => 'NEGATIVE_NET_CFD_DEPOSIT_LOOKBACK_TIMERANGE',
                total_withdrawal_amount_today_in_usd => 0,
            },
            "returns tag: NEGATIVE_NET_CFD_DEPOSIT_LOOKBACK_TIMERANGE correclty."
        );
    };

    # subtest "_rule_low_trade_for_timerange" => sub {
    #     $mock_autoupdate->mock(
    #         get_net_cfd_transfers => sub { 4000 },
    #     );

    #     $mock->mock(
    #         user_restricted => sub {
    #             return undef;
    #         },
    #         get_client_profit => sub {
    #             return 0;
    #         },
    #         get_client_trading_activity => sub {
    #             return 24;
    #         },
    #         get_crypto_account_total_deposit_amount => sub {
    #             return 100;
    #         },
    #         user_payment_details => sub {
    #             return {
    #                 count                             => 0,
    #                 currency_wise_crypto_net_deposits => {},
    #                 total_crypto_deposits             => 0,
    #                 non_crypto_deposit_amount         => 0,
    #                 non_crypto_withdraw_amount        => 0,
    #                 method_wise_net_deposits          => {}};
    #         },

    #     );

    #     my $response = $auto_approve_obj->user_activity(
    #         binary_user_id          => $dummy_user->id,
    #         client_loginid          => $client_loginid,
    #         total_withdrawal_amount => 2,
    #     );
    #     is_deeply(
    #         $response,
    #         {
    #             auto_approve                         => 0,
    #             tag                                  => 'LOW_TRADE_FOR_TIMERANGE',
    #             total_withdrawal_amount_today_in_usd => 0,
    #         },
    #         "returns tag:LOW_TRADE_FOR_TIMERANGE correclty."
    #     );
    #     $mock->unmock_all();
    #     $mock_autoupdate->unmock_all();
    # };

    # subtest "_rule_low_trade_recent_deposit" => sub {
    #     $mock->unmock_all();
    #     mock_all_rule_except_in_param($mock, '_rule_low_trade_recent_deposit');

    #     $mock_autoupdate->mock(get_recent_deposit_to_crypto_account => sub { return {amount => 100, payment_time => "20-02-2024"}; });
    #     $mock_autoupdate->mock(get_client_trading_activity          => sub { return 24; });    # total trade is less then 25% of recent deposit

    #     my $response = $auto_approve_obj->user_activity(
    #         binary_user_id          => $dummy_user->id,
    #         client_loginid          => $client_loginid,
    #         total_withdrawal_amount => 2,
    #     );

    #     is_deeply(
    #         $response,
    #         {
    #             auto_approve                         => 0,
    #             tag                                  => 'LOW_TRADE_RECENT_DEPOSIT',
    #             total_withdrawal_amount_today_in_usd => 0,
    #         },
    #         "returns tag: LOW_TRADE_RECENT_DEPOSIT correclty."
    #     );

    #     $mock->unmock_all();
    #     $mock_autoupdate->unmock_all();
    # };

    # subtest "_rule_low_trade_recent_net_cfd_deposit" => sub {
    #     $mock->unmock_all();
    #     mock_all_rule_except_in_param($mock, '_rule_low_trade_recent_net_cfd_deposit');

    #     my $get_net_cfd_transfers = -10;    #negative net transefer;

    #     $mock_autoupdate->mock(get_recent_cfd_deposit => sub { return {amount => 100, payment_time => "20-02-2024"}; });
    #     $mock_autoupdate->mock(get_net_cfd_transfers  => sub { return $get_net_cfd_transfers; });

    #     $log->clear();

    #     my $response = $auto_approve_obj->user_activity(
    #         binary_user_id          => $dummy_user->id,
    #         client_loginid          => $client_loginid,
    #         total_withdrawal_amount => 2,
    #     );

    #     is_deeply(
    #         $response,
    #         {
    #             auto_approve                         => 0,
    #             tag                                  => 'LOW_TRADE_RECENT_NEGATIVE_NET_CFD_DEPOSIT',
    #             total_withdrawal_amount_today_in_usd => 0,
    #         },
    #         "returns tag: LOW_TRADE_RECENT_NEGATIVE_NET_CFD_DEPOSIT correclty when net cfd transfer is negative."
    #     );

    #     cmp_bag $log->msgs, [{
    #             level    => 'debug',
    #             category => 'BOM::Platform::CryptoCashier::AutoUpdatePayouts::Approve',
    #             message  => re("has negative cfd net transfer activity since the recent crypto deposit"),
    #         },

    #         ],
    #         'Correct debug logs raised when LOW_TRADE_RECENT_NET_CFD_DEPOSIT rule failed due to negative net cfd transfer';

    #     $get_net_cfd_transfers = 26;
    #     $mock_autoupdate->mock(get_recent_cfd_deposit => sub { return {amount => 100, payment_time => "20-02-2024"}; });

    #     $log->clear();
    #     $response = $auto_approve_obj->user_activity(
    #         binary_user_id          => $dummy_user->id,
    #         client_loginid          => $client_loginid,
    #         total_withdrawal_amount => 2,
    #     );

    #     is_deeply(
    #         $response,
    #         {
    #             auto_approve                         => 0,
    #             tag                                  => 'LOW_TRADE_RECENT_NET_CFD_DEPOSIT',
    #             total_withdrawal_amount_today_in_usd => 0,
    #         },
    #         "returns tag: LOW_TRADE_RECENT_NET_CFD_DEPOSIT correclty when less net cfd transfer since recent cfd deposit"
    #     );

    #     cmp_bag $log->msgs, [{
    #             level    => 'debug',
    #             category => 'BOM::Platform::CryptoCashier::AutoUpdatePayouts::Approve',
    #             message  => re("has high net transfer activity since the recent cfd deposit"),
    #         },

    #         ],
    #         'Correct debug logs raised when LOW_TRADE_RECENT_NET_CFD_DEPOSIT rule failed less cfd net transfer activity since the recent cfd deposit';

    #     $mock->unmock_all();
    #     $mock_autoupdate->unmock_all();
    # };
};

$app_config->payments->crypto->auto_update->lookback_time_trading_activity($default_lookback_time_trading_activity);
$app_config->payments->crypto->auto_update->max_profit_limit->day($default_max_profit_limit_day);
$app_config->payments->crypto->auto_update->max_profit_limit->month($default_max_profit_limit_month);
$app_config->payments->crypto->auto_update->max_cfd_net_transfer_limit($default_max_cfd_net_transfer_limit);
$app_config->payments->crypto->auto_update->lookback_time_cfd_net_transfer($default_lookback_time_cfd_net_transfer);

$mock_autoupdate->unmock_all();

done_testing;
