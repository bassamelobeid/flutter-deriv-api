use strict;
use warnings;
no indirect;

use Test::More;
use Test::Fatal;
use Test::MockModule;

use BOM::Platform::CryptoCashier::AutoUpdatePayouts::Approve;

my $mock             = Test::MockModule->new('BOM::Platform::CryptoCashier::AutoUpdatePayouts::Approve');
my $auto_approve_obj = BOM::Platform::CryptoCashier::AutoUpdatePayouts::Approve->new(broker_code => 'CR');

subtest 'BOM::Platform::CryptoCashier::AutoUpdatePayouts::Approve->user_activity' => sub {
    subtest "ACCEPTABLE_NET_DEPOSIT" => sub {
        $mock->mock(user_restricted => sub { return undef });
        $mock->mock(
            user_payment_details => sub {
                return {};
            });

        my $response = $auto_approve_obj->user_activity(total_withdrawal_amount => undef);

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
        for my $restricted_status (qw/cashier_locked disabled no_withdrawal_or_trading withdrawal_locked duplicate_account closed unwelcome/) {
            $mock->mock(
                user_restricted => sub {
                    return {status_code => $restricted_status};
                });

            is_deeply(
                $auto_approve_obj->user_activity(
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
        $mock->mock(
            user_restricted => sub {
                return undef;
            });

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
                    currency_wise_crypto_net_deposits => {
                        ETH => 19.09,
                        BTC => 18.86,
                    },
                    method_wise_net_deposits => {payment_agent_transfer => 19.59}};
            });

        is_deeply(
            $auto_approve_obj->user_activity(
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
                    currency_wise_crypto_net_deposits => {
                        ETH => 25,
                        BTC => 18.86
                    },
                    method_wise_net_deposits => {
                        payment_agent_transfer => 10.1,
                        p2p                    => 20
                    }};
            });

        is_deeply(
            $auto_approve_obj->user_activity(
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
                    currency_wise_crypto_net_deposits => {
                        ETH => 25,
                        BTC => 18.86
                    },
                    method_wise_net_deposits => {
                        payment_agent_transfer => 10.1,
                        p2p                    => 5,
                        Skrill                 => 19
                    }};
            });

        is_deeply(
            $auto_approve_obj->user_activity(
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
        $mock->mock(
            user_restricted => sub {
                return undef;
            });

        $mock->mock(
            user_payment_details => sub {
                return {
                    count                             => 0,
                    currency_wise_crypto_net_deposits => {
                        ETH => 25,
                        BTC => 18.86
                    },
                    method_wise_net_deposits => {}};
            });

        is_deeply(
            $auto_approve_obj->user_activity(
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
                    method_wise_net_deposits          => {}};
            });

        is_deeply(
            $auto_approve_obj->user_activity(
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
        $mock->mock(user_restricted => sub { return undef });
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
        $mock->mock(user_restricted => sub { return undef });
        $mock->mock(
            user_payment_details => sub {
                return {
                    count                   => 1,
                    has_reversible_payment  => 1,
                    last_reversible_deposit => {
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
            total_withdrawal_amount => 2,
            currency_code           => 'BTC'
        );

        isnt($response->{tag}, 'AMOUNT_ABOVE_THRESHOLD');

        $mock->unmock_all();
    };

    subtest "ACCEPTABLE_NET_DEPOSITS" => sub {
        $mock->mock(user_restricted => sub { return undef });
        $mock->mock(
            user_payment_details => sub {
                return {
                    count                   => 1,
                    has_reversible_payment  => 1,
                    last_reversible_deposit => {
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
        $mock->mock(user_restricted => sub { return undef });
        $mock->mock(
            user_payment_details => sub {
                return {
                    count                   => 1,
                    has_reversible_payment  => 1,
                    last_reversible_deposit => {
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
        $mock->mock(user_restricted => sub { return undef });
        $mock->mock(
            user_payment_details => sub {
                return {
                    count                      => 1,
                    has_reversible_payment     => 0,
                    last_reversible_deposit    => undef,
                    reversible_deposit_amount  => 0,
                    reversible_withdraw_amount => 0,
                    deposit_amount             => 100,
                    withdraw_amount            => 50
                };
            });
        my $response = $auto_approve_obj->user_activity(
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
    };
};

done_testing;
