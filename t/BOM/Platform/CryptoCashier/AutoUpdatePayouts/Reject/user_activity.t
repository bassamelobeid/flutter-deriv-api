use strict;
use warnings;
no indirect;

use Test::More;
use Test::Fatal;
use Test::MockModule;

use BOM::Platform::CryptoCashier::AutoUpdatePayouts::Reject;
use BOM::Test::Helper::Utility qw(random_email_address);
use BOM::User;

my $mock            = Test::MockModule->new('BOM::Platform::CryptoCashier::AutoUpdatePayouts::Reject');
my $mock_user       = Test::MockModule->new('BOM::User');
my $mock_autoupdate = Test::MockModule->new('BOM::Platform::CryptoCashier::AutoUpdatePayouts');

$mock_autoupdate->mock(get_client_balance => sub { 9999 });

my $auto_reject_obj = BOM::Platform::CryptoCashier::AutoUpdatePayouts::Reject->new(broker_code => 'CR');
my $dummy_user      = BOM::User->create(
    email    => random_email_address,
    password => 'test',
);
# We are initially mocking this to a high value so that tests not related to trade should pass this.
$mock_user->mock('total_trades', sub { return 30 });

subtest 'BOM::Platform::CryptoCashier::AutoUpdatePayouts::Reject->user_activity' => sub {

    subtest "HIGHEST_DEPOSIT_METHOD_IS_NOT_CRYPTO" => sub {

        $mock->mock(
            user_payment_details => sub {
                return {
                    count                             => 4,
                    currency_wise_crypto_net_deposits => {
                        BTC => 2,
                        ETH => 5,
                    },
                    total_crypto_deposits      => 7,
                    non_crypto_deposit_amount  => 64,
                    non_crypto_withdraw_amount => 0,
                    payments                   => [{
                            total_deposit_in_usd    => 30.00,
                            total_withdrawal_in_usd => 0.00,
                            net_deposit             => 30.00,
                            currency_code           => "USD",
                            is_reversible           => 0,
                            p_method                => 'WebMoney',
                            payment_time            => "2020-10-20 21:36:31",
                            is_stable_method        => 1
                        },
                        {
                            total_deposit_in_usd    => 12.00,
                            total_withdrawal_in_usd => 0.00,
                            net_deposit             => 12.00,
                            currency_code           => "USD",
                            is_reversible           => 1,
                            p_method                => 'Skrill',
                            payment_time            => "2020-10-20 21:36:31",
                            is_stable_method        => 1
                        },
                        {
                            total_deposit_in_usd    => 10.00,
                            total_withdrawal_in_usd => 0.00,
                            net_deposit             => 10.00,
                            currency_code           => "USD",
                            is_reversible           => 0,
                            p_method                => 'payment_agent_transfer',
                            payment_time            => "2020-10-20 21:36:31",
                            is_stable_method        => 1

                        },
                        {

                            total_deposit_in_usd    => 12.00,
                            total_withdrawal_in_usd => 0.00,
                            net_deposit             => 12.00,
                            currency_code           => "USD",
                            is_reversible           => 0,
                            p_method                => 'p2p',
                            payment_time            => "2020-10-20 21:36:31",
                            is_stable_method        => 1

                        }
                    ],
                    has_stable_method_deposits => 1,
                    method_wise_net_deposits   => {
                        payment_agent_transfer => 10,
                        Skrill                 => 15,
                        p2p                    => 12,
                        WebMoney               => 30
                    }};
            },
            is_client_auto_reject_disabled => sub {
                return 0;
            });

        is_deeply(
            $auto_reject_obj->user_activity(
                binary_user_id                => $dummy_user->id,
                client_loginid                => 'CR90000000',
                total_withdrawal_amount       => 1,
                total_withdrawal_amount_today => 4,
                currency_code                 => 'ETH'
            ),
            {
                auto_reject                          => 1,
                tag                                  => 'HIGHEST_DEPOSIT_METHOD_IS_NOT_CRYPTO',
                total_withdrawal_amount_today_in_usd => 4,
                reject_reason                        => 'highest_deposit_method_is_not_crypto',
                reject_remark => 'AutoRejected - highest deposit method is not crypto. Request payout via highest deposited method Webmoney',
                suggested_withdraw_method => 'Webmoney',
            },
            "returns tag: HIGHEST_DEPOSIT_METHOD_IS_NOT_CRYPTO as net deposit of Webmoney payment method is greater than ETH net deposit"
        );

        $mock->mock(
            user_payment_details => sub {
                return {
                    count                             => 4,
                    currency_wise_crypto_net_deposits => {

                    },
                    total_crypto_deposits      => 0,
                    non_crypto_deposit_amount  => 10,
                    non_crypto_withdraw_amount => 0,
                    payments                   => [{
                            total_deposit_in_usd    => 10.00,
                            total_withdrawal_in_usd => 0.00,
                            net_deposit             => 10.00,
                            currency_code           => "USD",
                            is_reversible           => 0,
                            p_method                => 'payment_agent_transfer',
                            payment_time            => "2020-10-20 21:36:31",
                            is_stable_method        => 1
                        },
                    ],
                    has_stable_method_deposits => 1,
                    method_wise_net_deposits   => {
                        payment_agent_transfer => 10,
                    }};
            });

        is_deeply(
            $auto_reject_obj->user_activity(
                binary_user_id                => $dummy_user->id,
                client_loginid                => 'CR90000000',
                total_withdrawal_amount       => 1,
                total_withdrawal_amount_today => 4,
                currency_code                 => 'ETH'
            ),
            {
                auto_reject                          => 1,
                tag                                  => 'HIGHEST_DEPOSIT_METHOD_IS_NOT_CRYPTO',
                total_withdrawal_amount_today_in_usd => 4,
                reject_reason                        => 'highest_deposit_method_is_not_crypto',
                reject_remark => 'AutoRejected - highest deposit method is not crypto. Request payout via highest deposited method Payment Agent',
                suggested_withdraw_method => 'Payment Agent',
            },
            "returns tag: HIGHEST_DEPOSIT_METHOD_IS_NOT_CRYPTO if there are no crypto deposits for any currency"
        );

        $mock->mock(
            user_payment_details => sub {
                return {
                    count                             => 4,
                    currency_wise_crypto_net_deposits => {
                        BTC => 2,
                        ETH => 5,
                    },
                    total_crypto_deposits      => 7,
                    non_crypto_deposit_amount  => 30,
                    non_crypto_withdraw_amount => 0,
                    payments                   => [{
                            total_deposit_in_usd    => 10.00,
                            total_withdrawal_in_usd => 0.00,
                            net_deposit             => 10.00,
                            currency_code           => "USD",
                            is_reversible           => 0,
                            p_method                => 'payment_agent_transfer',
                            payment_time            => "2020-10-20 21:36:31",
                            is_stable_method        => 1

                        },
                        {
                            total_deposit_in_usd    => 20.00,
                            total_withdrawal_in_usd => 0.00,
                            net_deposit             => 20.00,
                            currency_code           => "USD",
                            is_reversible           => 1,
                            p_method                => 'Skrill',
                            payment_time            => "2020-10-20 21:36:31",
                            is_stable_method        => 1
                        },
                    ],
                    has_stable_method_deposits => 1,
                    method_wise_net_deposits   => {
                        payment_agent_transfer => 10,
                        Skrill                 => 20
                    }};
            });

        is_deeply(
            $auto_reject_obj->user_activity(
                binary_user_id                => $dummy_user->id,
                client_loginid                => 'CR90000000',
                total_withdrawal_amount       => 1,
                total_withdrawal_amount_today => 4,
                currency_code                 => 'LTC'
            ),
            {
                auto_reject                          => 1,
                tag                                  => 'HIGHEST_DEPOSIT_METHOD_IS_NOT_CRYPTO',
                total_withdrawal_amount_today_in_usd => 4,
                reject_reason                        => 'highest_deposit_method_is_not_crypto',
                reject_remark => 'AutoRejected - highest deposit method is not crypto. Request payout via highest deposited method Skrill',
                suggested_withdraw_method => 'Skrill',
            },
            "returns tag: HIGHEST_DEPOSIT_METHOD_IS_NOT_CRYPTO if there are no crypto deposits for the withdrawal currency"
        );

        $mock->unmock_all();
    };

    subtest 'HIGH_CRYPTOCURRENCY_DEPOSIT' => sub {
        $mock->mock(
            user_payment_details => sub {
                return {
                    count                             => 2,
                    currency_wise_crypto_net_deposits => {
                        BTC => -20,
                        ETH => 12
                    },
                    total_crypto_deposits      => 12,
                    non_crypto_deposit_amount  => 26,
                    non_crypto_withdraw_amount => 0,
                    has_stable_method_deposits => 1,
                    method_wise_net_deposits   => {
                        payment_agent_transfer => 10,
                        Skrill                 => 15,
                        p2p                    => 1
                    }};
            },
            is_client_auto_reject_disabled => sub {
                return 0;
            });

        is_deeply(
            $auto_reject_obj->user_activity(
                binary_user_id                => $dummy_user->id,
                client_loginid                => 'CR90000000',
                total_withdrawal_amount       => 1,
                total_withdrawal_amount_today => 4,
                currency_code                 => 'BTC'
            ),
            {
                auto_reject                          => 0,
                tag                                  => 'HIGH_CRYPTOCURRENCY_DEPOSIT',
                total_withdrawal_amount_today_in_usd => 4,
            },
            "returns tag: HIGH_CRYPTOCURRENCY_DEPOSIT as crypto net deposit is greater than other payment methdod net deposit"
        );
        $mock->unmock_all();
    };
    subtest 'is_client_auto_reject_disabled' => sub {

        $mock->mock(
            client_status => sub {
                return [{'status_code' => 'crypto_auto_reject_disabled'}];
            });
        is_deeply(
            $auto_reject_obj->user_activity(
                binary_user_id                => $dummy_user->id,
                client_loginid                => 'CR90000000',
                total_withdrawal_amount       => 1,
                total_withdrawal_amount_today => 4,
                currency_code                 => 'BTC'
            ),
            {
                auto_reject                          => 0,
                tag                                  => 'AUTO_REJECT_IS_DISABLED_FOR_CLIENT',
                total_withdrawal_amount_today_in_usd => 4,
            },
            "returns tag: AUTO_REJECT_IS_DISABLED_FOR_CLIENT Auto Reject is disabled for the client from backoffice"
        );

        $mock->unmock_all();
    };
    subtest 'NO_NON_CRYPTO_DEPOSITS_RECENTLY' => sub {

        $mock->mock(
            user_payment_details => sub {
                return {
                    count                      => 2,
                    total_crypto_deposits      => 37,
                    non_crypto_deposit_amount  => 10,
                    non_crypto_withdraw_amount => 0,
                    payments                   => [{
                            amount               => "10.00",
                            amount_in_usd        => "10.00",
                            currency_code        => "USD",
                            id                   => 79,
                            payment_gateway_code => "doughflow",
                            payment_method       => "Wirecard",
                            payment_processor    => "",
                            is_stable_method     => 0

                        }
                    ],
                    currency_wise_crypto_net_deposits => {
                        BTC => 32,
                        ETH => 5,
                    },
                    has_stable_method_deposits => 0,
                    method_wise_net_deposits   => {}};
            },
            client_status => sub {
                return [];
            });

        is_deeply(
            $auto_reject_obj->user_activity(
                binary_user_id                => $dummy_user->id,
                client_loginid                => 'CR90000000',
                total_withdrawal_amount       => 1,
                total_withdrawal_amount_today => 4,
                currency_code                 => 'BTC'
            ),
            {
                auto_reject                          => 0,
                tag                                  => 'NO_NON_CRYPTO_DEPOSITS_RECENTLY',
                total_withdrawal_amount_today_in_usd => 4,
            },
            "returns tag: NO_NON_CRYPTO_DEPOSITS_RECENTLY Do not auto reject if there are no stable deposit methods"
        );

        $mock->mock(
            user_payment_details => sub {
                return {
                    count                             => 2,
                    total_crypto_deposits             => 37,
                    non_crypto_deposit_amount         => 0,
                    non_crypto_withdraw_amount        => 0,
                    payments                          => [],
                    currency_wise_crypto_net_deposits => {
                        BTC => 32,
                        ETH => 5,
                    },
                    has_stable_method_deposits => 0,
                    method_wise_net_deposits   => {}};
            },
            client_status => sub {
                return [];
            });

        is_deeply(
            $auto_reject_obj->user_activity(
                binary_user_id                => $dummy_user->id,
                client_loginid                => 'CR90000000',
                total_withdrawal_amount       => 1,
                total_withdrawal_amount_today => 4,
                currency_code                 => 'BTC'
            ),
            {
                auto_reject                          => 0,
                tag                                  => 'NO_NON_CRYPTO_DEPOSITS_RECENTLY',
                total_withdrawal_amount_today_in_usd => 4,
            },
            "returns tag: NO_NON_CRYPTO_DEPOSITS_RECENTLY Do not auto reject since there are no non crypto deposits"
        );

        $mock->mock(
            user_payment_details => sub {
                return {
                    count                      => 2,
                    total_crypto_deposits      => 9,
                    non_crypto_deposit_amount  => 30,
                    non_crypto_withdraw_amount => 0,
                    payments                   => [{
                            total_deposit_in_usd    => 10.00,
                            total_withdrawal_in_usd => 0.00,
                            net_deposit             => 10.00,
                            currency_code           => "USD",
                            is_reversible           => 0,
                            p_method                => 'payment_agent_transfer',
                            payment_time            => "2021-10-20 21:36:31",
                            is_stable_method        => 1

                        },
                        {
                            total_deposit_in_usd    => 10.00,
                            total_withdrawal_in_usd => 0.00,
                            net_deposit             => 10.00,
                            currency_code           => "USD",
                            is_reversible           => 1,
                            p_method                => 'Skrill',
                            payment_time            => "2022-10-20 22:16:00",
                            is_stable_method        => 1
                        },
                        {
                            total_deposit_in_usd    => 10.00,
                            total_withdrawal_in_usd => 0.00,
                            net_deposit             => 10.00,
                            currency_code           => "USD",
                            is_reversible           => 1,
                            p_method                => 'p2p',
                            payment_time            => "2021-11-20 20:36:31",
                            is_stable_method        => 1
                        },
                    ],
                    currency_wise_crypto_net_deposits => {
                        BTC => 9,
                    },
                    has_stable_method_deposits => 1,
                    method_wise_net_deposits   => {
                        payment_agent_transfer => 10.00,
                        Skrill                 => 10.00,
                        p2p                    => 10.00
                    }};
            },
            client_status => sub {
                return [];
            });

        is_deeply(
            $auto_reject_obj->user_activity(
                binary_user_id                => $dummy_user->id,
                client_loginid                => 'CR90000000',
                total_withdrawal_amount       => 1,
                total_withdrawal_amount_today => 4,
                currency_code                 => 'BTC'
            ),
            {
                auto_reject                          => 1,
                tag                                  => 'HIGHEST_DEPOSIT_METHOD_IS_NOT_CRYPTO',
                total_withdrawal_amount_today_in_usd => 4,
                reject_reason                        => 'highest_deposit_method_is_not_crypto',
                reject_remark => 'AutoRejected - highest deposit method is not crypto. Request payout via highest deposited method Skrill',
                suggested_withdraw_method => 'Skrill',
            },
            "returns recent highest deposited method when net deposits of different payment methods are equal "
        );

        $mock->unmock_all();

    };
    subtest 'CRYPTO_NON_CRYPTO_NET_DEPOSITS_NEGATIVE' => sub {
        $mock_autoupdate->mock(get_client_balance => sub { 0.99 });
        $mock->mock(
            user_payment_details => sub {
                return {
                    count                             => 2,
                    total_crypto_deposits             => 0,
                    non_crypto_withdraw_amount        => 0,
                    non_crypto_deposit_amount         => 15,
                    currency_wise_crypto_net_deposits => {
                        BTC => -1,
                        ETH => -1
                    },
                    payments => [{
                            total_deposit_in_usd    => 15.00,
                            total_withdrawal_in_usd => 0.00,
                            net_deposit             => 15.00,
                            currency_code           => "USD",
                            is_reversible           => 1,
                            p_method                => 'Skrill',
                            payment_time            => "2020-10-20 21:36:31",
                            is_stable_method        => 1
                        },
                    ],
                    has_stable_method_deposits => 1,
                    method_wise_net_deposits   => {
                        Skrill => -15,
                    }};
            },
            is_client_auto_reject_disabled => sub {
                return 0;
            });

        is_deeply(
            $auto_reject_obj->user_activity(
                binary_user_id                => $dummy_user->id,
                client_loginid                => 'CR90000000',
                total_withdrawal_amount       => 1,
                total_withdrawal_amount_today => 1,
                currency_code                 => 'BTC'
            ),
            {
                auto_reject                          => 0,
                tag                                  => 'CRYPTO_NON_CRYPTO_NET_DEPOSITS_NEGATIVE',
                total_withdrawal_amount_today_in_usd => 1,
            },
            "returns tag: CRYPTO_NON_CRYPTO_NET_DEPOSITS_NEGATIVE as user's net crypto deposit amount & highest deposited amount are both negative values"
        );
        $mock->unmock_all();
    };
    #TO-DO: this test is temporarily commented out. It will be fixed in separate card.
    # subtest 'LOW_TRADE' => sub {

    #     $mock_user->mock('total_trades', sub { return 5 });

    #     $mock->mock(
    #         user_payment_details => sub {
    #             return {
    #                 non_crypto_withdraw_amount => 0,
    #                 has_stable_method_deposits => 1,
    #                 total_crypto_deposits      => '50.03',
    #                 last_reversible_deposit    => undef,
    #                 has_reversible_payment     => 0,
    #                 method_wise_net_deposits   => {AirTM => '50'},
    #                 reversible_withdraw_amount => 0,
    #                 count                      => 1,
    #                 payments                   => [{
    #                         total_deposit_in_usd    => '50.00',
    #                         p_method                => 'AirTM',
    #                         payment_time            => '2023-03-28 09:49:53.326552',
    #                         count                   => '1',
    #                         net_deposit             => '50.00',
    #                         is_stable_method        => 1,
    #                         is_reversible           => 0,
    #                         currency_code           => 'USD',
    #                         total_withdrawal_in_usd => 0
    #                     }
    #                 ],
    #                 reversible_deposit_amount         => 0,
    #                 non_crypto_deposit_amount         => '50',
    #                 currency_wise_crypto_net_deposits => {ETH => '50.03'}};
    #         },
    #         is_client_auto_reject_disabled => sub {
    #             return 0;
    #         });
    #     is_deeply(
    #         $auto_reject_obj->user_activity(
    #             binary_user_id                => $dummy_user->id,
    #             client_loginid                => 'CR90000000',
    #             total_withdrawal_amount       => 1,
    #             total_withdrawal_amount_today => 4,
    #             currency_code                 => 'ETH'
    #         ),
    #         {
    #             auto_reject                          => 1,
    #             tag                                  => 'LOW_TRADE',
    #             reject_reason                        => 'low_trade',
    #             reject_remark                        => 'AutoRejected - Total trade amount less than 25 percent of total deposit amount',
    #             total_withdrawal_amount_today_in_usd => 4,
    #         },
    #         "returns tag: LOW_TRADE as total trade is less than 25 percent of total deposit amount"
    #     );
    #     $mock->unmock_all();
    # };

    subtest 'INSUFFICIENT_BALANCE' => sub {
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
                            currency_code           => "USD",
                            is_reversible           => 1,
                            p_method                => 'Skrill',
                            payment_time            => "2020-10-20 21:36:31",
                            is_stable_method        => 1
                        },
                    ],
                    has_stable_method_deposits => 1,
                    method_wise_net_deposits   => {
                        Skrill => -15,
                    },
                };
            },
            is_client_auto_reject_disabled => sub {
                return 0;
            },
            get_client_balance => sub { 0.99 },
        );

        is_deeply(
            $auto_reject_obj->user_activity(
                binary_user_id                => 1,
                client_loginid                => 'CR90000000',
                withdrawal_amount_in_crypto   => 1,
                total_withdrawal_amount       => 1,
                total_withdrawal_amount_today => 1,
                currency_code                 => 'BTC'
            ),
            {
                auto_reject                          => 1,
                tag                                  => 'INSUFFICIENT_BALANCE',
                reject_reason                        => 'insufficient_balance',
                reject_remark                        => 'AutoRejected - client does not have sufficient balance',
                total_withdrawal_amount_today_in_usd => 1,
            },
            "returns tag: INSUFFICIENT_BALANCE when client's balance is lower than the withdrawal amount"
        );
        $mock->unmock_all();
    };

    subtest 'CRYPTO_WITHDRAW_VIA_EWALLET' => sub {
        $mock->mock(
            user_payment_details => sub {
                return {
                    count                             => 4,
                    currency_wise_crypto_net_deposits => {
                        BTC => 2,
                        ETH => 5,
                    },
                    payments => [{
                            total_deposit_in_usd    => 30.00,
                            total_withdrawal_in_usd => 0.00,
                            net_deposit             => 30.00,
                            currency_code           => "USD",
                            is_reversible           => 0,
                            p_method                => 'MasterCard',
                            payment_time            => "2020-10-20 21:36:31",
                            is_stable_method        => 0

                        },
                        {
                            total_deposit_in_usd    => 20.00,
                            total_withdrawal_in_usd => 0.00,
                            net_deposit             => 20.00,
                            currency_code           => "USD",
                            is_reversible           => 1,
                            p_method                => 'payment_agent_transfer',
                            payment_time            => "2020-10-20 21:36:31",
                            is_stable_method        => 1
                        },
                    ],
                    has_stable_method_deposits => 1,
                    mastercard_deposit_amount  => 30,
                    method_wise_net_deposits   => {
                        MasterCard             => 30,
                        payment_agent_transfer => 20
                    }};
            });

        is_deeply(
            $auto_reject_obj->user_activity(
                binary_user_id                => 1,
                client_loginid                => 'CR90000000',
                total_withdrawal_amount       => 1,
                total_withdrawal_amount_today => 4,
                currency_code                 => 'LTC'
            ),
            {
                auto_reject                          => 1,
                tag                                  => 'WITHDRAW_VIA_EWALLET',
                total_withdrawal_amount_today_in_usd => 4,
                reject_reason                        => 'withdraw_via_ewallet',
                reject_remark => 'AutoRejected - highest deposit method is not crypto. Request payout via highest deposited method e-wallet',
            },
            "returns tag: HIGHEST_DEPOSIT_METHOD_IS_NOT_CRYPTO if there are no crypto deposits for the withdrawal currency"
        );

        $mock->unmock_all();

        $mock->mock(
            user_payment_details => sub {
                return {
                    count                             => 4,
                    currency_wise_crypto_net_deposits => {
                        BTC => 2,
                        ETH => 5,
                    },
                    payments => [{
                            total_deposit_in_usd    => 1.00,
                            total_withdrawal_in_usd => 0.00,
                            net_deposit             => 1.00,
                            currency_code           => "USD",
                            is_reversible           => 0,
                            p_method                => 'MasterCard',
                            payment_time            => "2020-10-20 21:36:31",
                            is_stable_method        => 0

                        },
                        {
                            total_deposit_in_usd    => 20.00,
                            total_withdrawal_in_usd => 0.00,
                            net_deposit             => 20.00,
                            currency_code           => "USD",
                            is_reversible           => 1,
                            p_method                => 'payment_agent_transfer',
                            payment_time            => "2020-10-20 21:36:31",
                            is_stable_method        => 1
                        },
                    ],
                    has_stable_method_deposits => 1,
                    mastercard_deposit_amount  => 1,
                    method_wise_net_deposits   => {
                        MasterCard             => 1,
                        payment_agent_transfer => 20
                    }};
            });

        is_deeply(
            $auto_reject_obj->user_activity(
                binary_user_id                => 1,
                client_loginid                => 'CR90000000',
                total_withdrawal_amount       => 1,
                total_withdrawal_amount_today => 4,
                currency_code                 => 'LTC'
            ),
            {
                auto_reject                          => 1,
                tag                                  => 'HIGHEST_DEPOSIT_METHOD_IS_NOT_CRYPTO',
                total_withdrawal_amount_today_in_usd => 4,
                reject_reason                        => 'highest_deposit_method_is_not_crypto',
                reject_remark => 'AutoRejected - highest deposit method is not crypto. Request payout via highest deposited method Payment Agent',
                suggested_withdraw_method => 'Payment Agent',
            },
            "returns tag: HIGHEST_DEPOSIT_METHOD_IS_NOT_CRYPTO if there are no crypto deposits for the withdrawal currency"
        );
        $mock->unmock_all();
    };
};

$mock_autoupdate->unmock_all();

done_testing;
