use strict;
use warnings;
no indirect;

use Test::More;
use Test::Fatal;
use Test::MockModule;
use Future::AsyncAwait;

use BOM::Platform::CryptoCashier::AutoUpdatePayouts::Reject;

my $mock            = Test::MockModule->new('BOM::Platform::CryptoCashier::AutoUpdatePayouts::Reject');
my $auto_reject_obj = BOM::Platform::CryptoCashier::AutoUpdatePayouts::Reject->new(broker_code => 'CR');

subtest 'BOM::Platform::CryptoCashier::AutoUpdatePayouts::Reject->user_activity' => sub {

    subtest "HIGHEST_DEPOST_METHOD_IS_NOT_CRYPTO" => sub {

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
                binary_user_id                => 1,
                client_loginid                => 'CR90000000',
                total_withdrawal_amount       => 1,
                total_withdrawal_amount_today => 4,
                currency_code                 => 'ETH'
            ),
            {
                auto_reject                          => 1,
                tag                                  => 'HIGHEST_DEPOST_METHOD_IS_NOT_CRYPTO',
                total_withdrawal_amount_today_in_usd => 4,
                reject_reason                        => 'highest_deposit_method_is_not_crypto',
                reject_remark                        => 'AutoRejected - highest deposit method is not crypto, request payout via Webmoney',
                meta_data                            => 'Webmoney',
                fiat_account                         => 'USD'
            },
            "returns tag: HIGHEST_DEPOST_METHOD_IS_NOT_CRYPTO as net deposit of Webmoney payment method is greater than ETH net deposit"
        );

        $mock->mock(
            user_payment_details => sub {
                return {
                    count                             => 4,
                    currency_wise_crypto_net_deposits => {

                    },
                    payments => [{
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
                binary_user_id                => 1,
                client_loginid                => 'CR90000000',
                total_withdrawal_amount       => 1,
                total_withdrawal_amount_today => 4,
                currency_code                 => 'ETH'
            ),
            {
                auto_reject                          => 1,
                tag                                  => 'HIGHEST_DEPOST_METHOD_IS_NOT_CRYPTO',
                total_withdrawal_amount_today_in_usd => 4,
                reject_reason                        => 'highest_deposit_method_is_not_crypto',
                reject_remark                        => 'AutoRejected - highest deposit method is not crypto, request payout via Payment Agent',
                meta_data                            => 'Payment Agent',
                fiat_account                         => 'USD'
            },
            "returns tag: HIGHEST_DEPOST_METHOD_IS_NOT_CRYPTO if there are no crypto deposits for any currency"
        );

        $mock->mock(
            user_payment_details => sub {
                return {
                    count                             => 4,
                    currency_wise_crypto_net_deposits => {
                        BTC => 2,
                        ETH => 5,
                    },
                    payments => [{
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
                binary_user_id                => 1,
                client_loginid                => 'CR90000000',
                total_withdrawal_amount       => 1,
                total_withdrawal_amount_today => 4,
                currency_code                 => 'LTC'
            ),
            {
                auto_reject                          => 1,
                tag                                  => 'HIGHEST_DEPOST_METHOD_IS_NOT_CRYPTO',
                total_withdrawal_amount_today_in_usd => 4,
                reject_reason                        => 'highest_deposit_method_is_not_crypto',
                reject_remark                        => 'AutoRejected - highest deposit method is not crypto, request payout via Skrill',
                meta_data                            => 'Skrill',
                fiat_account                         => 'USD'
            },
            "returns tag: HIGHEST_DEPOST_METHOD_IS_NOT_CRYPTO if there are no crypto deposits for the withdrawal currency"
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
                binary_user_id                => 1,
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
                binary_user_id                => 1,
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
                    count    => 2,
                    payments => [{
                            amount               => "10.00",
                            amount_in_usd        => "10.00",
                            currency_code        => "USD",
                            id                   => 79,
                            payment_gateway_code => "doughflow",
                            payment_method       => "Wirecard",
                            payment_processor    => "",
                            is_stable_method     => 1

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
                binary_user_id                => 1,
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
                binary_user_id                => 1,
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
                    count    => 2,
                    payments => [{
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
                binary_user_id                => 1,
                client_loginid                => 'CR90000000',
                total_withdrawal_amount       => 1,
                total_withdrawal_amount_today => 4,
                currency_code                 => 'BTC'
            ),
            {
                auto_reject                          => 1,
                tag                                  => 'HIGHEST_DEPOST_METHOD_IS_NOT_CRYPTO',
                total_withdrawal_amount_today_in_usd => 4,
                reject_reason                        => 'highest_deposit_method_is_not_crypto',
                reject_remark                        => 'AutoRejected - highest deposit method is not crypto, request payout via Skrill',
                meta_data                            => 'Skrill',
                fiat_account                         => 'USD'
            },
            "returns recent highest deposited method when net deposits of different payment methods are equal "
        );

        $mock->unmock_all();

    }

};

done_testing;
