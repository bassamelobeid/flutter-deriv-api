use strict;
use warnings;
no indirect;

use Test::More;
use Test::Fatal;
use Test::MockModule;
use Future::AsyncAwait;

use BOM::Platform::CryptoCashier::AutoUpdatePayouts::Reject;
my $auto_reject_obj = BOM::Platform::CryptoCashier::AutoUpdatePayouts::Reject->new();

my $wcdeposit01 = {
    total_deposit_in_usd    => 37104.45,
    total_withdrawal_in_usd => 0.00,
    currency_code           => "ETH",
    payment_time            => "2020-10-20 20:21:20",
    net_deposit             => 37104.45,
    p_method                => 'WireCard',
    is_reversible           => 1,
};

my $wcdeposit02 = {
    total_deposit_in_usd    => 100.00,
    total_withdrawal_in_usd => 0.00,
    currency_code           => "USD",
    payment_time            => "2020-10-20 18:36:31",
    net_deposit             => 100.00,
    p_method                => 'WireCard',
    is_reversible           => 1,
};

my $wcwithdraw01 = {
    total_withdrawal_in_usd => -10.00,
    total_deposit_in_usd    => 0.00,
    currency_code           => "USD",
    payment_time            => "2020-10-20 18:36:31",
    net_deposit             => -10.00,
    p_method                => 'WireCard',
    is_reversible           => 1,
};
my $atmdeposit01 = {

    total_withdrawal_in_usd => 0.00,
    total_deposit_in_usd    => 150.00,
    currency_code           => "USD",
    payment_time            => "2020-10-20 18:36:31",
    net_deposit             => 150.00,
    p_method                => 'AirTM',
    is_reversible           => 0,
};
my $atmwithdraw02 = {
    total_withdrawal_in_usd => -15.00,
    total_deposit_in_usd    => 0.00,
    currency_code           => "USD",
    payment_time            => "2020-10-20 21:36:31",
    net_deposit             => -15.00,
    p_method                => 'AirTM',
    is_reversible           => 0,
};
my $pmdeposit03 = {
    total_withdrawal_in_usd => 0.00,
    total_deposit_in_usd    => 200.00,
    currency_code           => "USD",
    payment_time            => "2020-10-20 20:36:31",
    net_deposit             => 200.00,
    p_method                => 'PerfectM',
    is_reversible           => 0,
};
my $mastercarddeposit = {
    total_withdrawal_in_usd => 0.00,
    total_deposit_in_usd    => 20000.00,
    currency_code           => "USD",
    payment_time            => "2020-10-20 20:36:31",
    net_deposit             => 20000.00,
    p_method                => 'Mastercard',
    is_reversible           => 1,
};
my $payment_agent_deposit01 = {
    total_deposit_in_usd    => 10.00,
    total_withdrawal_in_usd => 0.00,
    net_deposit             => 10.00,
    currency_code           => "USD",
    is_reversible           => 0,
    p_method                => 'payment_agent_transfer',
    payment_time            => "2020-10-20 21:36:31",
};

my $payment_agent_deposit02 = {
    total_deposit_in_usd    => 15.00,
    total_withdrawal_in_usd => 0.00,
    net_deposit             => 15.00,
    currency_code           => "USD",
    is_reversible           => 0,
    p_method                => 'payment_agent_transfer',
    payment_time            => "2020-11-20 21:36:31",
};

my $payment_agent_withdrawal01 = {
    total_deposit_in_usd    => 0.00,
    total_withdrawal_in_usd => -5.00,
    net_deposit             => -5.00,
    currency_code           => "USD",
    is_reversible           => 0,
    p_method                => 'payment_agent_transfer',
    payment_time            => "2020-11-20 21:39:31",
};

my $pa_net_deposit = {
    total_deposit_in_usd    => 25.00,
    total_withdrawal_in_usd => -5.00,
    net_deposit             => 20.00,
    currency_code           => "USD",
    is_reversible           => 0,
    p_method                => 'payment_agent_transfer',
    payment_time            => "2020-10-20 21:36:31",
};

my $p2p_deposit = {
    total_deposit_in_usd    => 40.00,
    total_withdrawal_in_usd => 0.00,
    net_deposit             => 40.00,
    currency_code           => "USD",
    is_reversible           => 0,
    p_method                => 'p2p',
    payment_time            => "2020-11-20 21:39:31",
};

my $p2p_withdrawal = {
    total_deposit_in_usd    => 0.00,
    total_withdrawal_in_usd => -10.00,
    net_deposit             => -10.00,
    currency_code           => "USD",
    is_reversible           => 0,
    p_method                => 'p2p',
    payment_time            => "2020-11-20 21:39:31",
};

my $cryptodeposit01 = {
    total_deposit_in_usd    => 424.88,
    total_withdrawal_in_usd => 0.00,
    net_deposit             => 424.88,
    currency_code           => "BTC",
    is_reversible           => 0,
    p_method                => 'ctc',
    payment_time            => "2020-11-20 21:39:31",
};
my $crypto_net_deposit01 = {
    total_deposit_in_usd    => 424.88,
    total_withdrawal_in_usd => -225.88,
    net_deposit             => 199,
    currency_code           => "BTC",
    is_reversible           => 0,
    p_method                => 'ctc',
    payment_time            => "2020-11-20 21:39:31",
};
my $crypto_net_deposit02 = {
    total_deposit_in_usd    => 224.88,
    total_withdrawal_in_usd => -225.88,
    net_deposit             => -1.00,
    currency_code           => "BTC",
    is_reversible           => 0,
    p_method                => 'ctc',
    payment_time            => "2020-11-20 21:39:31",
};
my $cryptodeposit03 = {
    total_deposit_in_usd    => 379.54,
    total_withdrawal_in_usd => 0.00,
    net_deposit             => 379.54,
    currency_code           => "ETH",
    is_reversible           => 0,
    p_method                => 'ctc',
    payment_time            => "2020-11-20 21:39:31",
};
my $cryptowithdrawal01 = {
    total_deposit_in_usd    => 0.00,
    total_withdrawal_in_usd => -225.88,
    net_deposit             => -225.88,
    currency_code           => "BTC",
    is_reversible           => 0,
    p_method                => 'ctc',
    payment_time            => "2020-11-20 21:39:31",
};

my $mock = Test::MockModule->new('BOM::Platform::CryptoCashier::AutoUpdatePayouts::Reject');

subtest 'BOM::Platform::CryptoCashier::AutoUpdatePayouts::Reject->user_payment_details' => sub {
    subtest 'no payments' => sub {
        $mock->mock(
            user_payments => sub {
                return [];
            });

        is_deeply(
            $auto_reject_obj->user_payment_details(),
            {
                count                             => 0,
                total_crypto_deposits             => 0,
                non_crypto_deposit_amount         => 0,
                has_reversible_payment            => 0,
                reversible_deposit_amount         => 0,
                reversible_withdraw_amount        => 0,
                non_crypto_withdraw_amount        => 0,
                last_reversible_deposit           => undef,
                payments                          => [],
                method_wise_net_deposits          => {},
                mastercard_deposit_amount         => 0,
                currency_wise_crypto_net_deposits => {},
                has_stable_method_deposits        => 0
            });

        $mock->unmock('user_payments');
    };

    subtest 'Correct net deposit calculation for crypto, doughflow and PA' => sub {
        $mock->mock(
            user_payments => sub {
                return [
                    $crypto_net_deposit01, $cryptodeposit03, $atmdeposit01, $atmwithdraw02,
                    $wcdeposit01,          $wcwithdraw01,    $pmdeposit03,  $payment_agent_deposit02
                ];
            });

        is_deeply(
            $auto_reject_obj->user_payment_details(),
            {
                count                     => 6,
                total_crypto_deposits     => $crypto_net_deposit01->{total_deposit_in_usd} + $cryptodeposit03->{total_deposit_in_usd},
                non_crypto_deposit_amount => $atmdeposit01->{total_deposit_in_usd} +
                    $wcdeposit01->{total_deposit_in_usd} +
                    $pmdeposit03->{total_deposit_in_usd} +
                    $payment_agent_deposit02->{total_deposit_in_usd},
                has_reversible_payment     => 1,
                reversible_deposit_amount  => $wcdeposit01->{total_deposit_in_usd},
                reversible_withdraw_amount => $wcwithdraw01->{total_withdrawal_in_usd},
                non_crypto_withdraw_amount => $wcwithdraw01->{total_withdrawal_in_usd} + $atmwithdraw02->{total_withdrawal_in_usd},
                last_reversible_deposit    => $wcdeposit01,
                payments                   => [$atmdeposit01, $atmwithdraw02, $wcdeposit01, $wcwithdraw01, $pmdeposit03, $payment_agent_deposit02],
                method_wise_net_deposits   => {
                    $atmdeposit01->{p_method} => $atmdeposit01->{net_deposit} + $atmwithdraw02->{net_deposit},
                    $pmdeposit03->{p_method}  => $pmdeposit03->{net_deposit},
                    payment_agent_transfer    => $payment_agent_deposit02->{net_deposit}
                },
                mastercard_deposit_amount         => 0,
                currency_wise_crypto_net_deposits => {
                    $crypto_net_deposit01->{currency_code} => $crypto_net_deposit01->{net_deposit},
                    $cryptodeposit03->{currency_code}      => $cryptodeposit03->{net_deposit}
                },
                has_stable_method_deposits => 1
            });

        $mock->unmock('user_payments');
    };

    subtest 'Refer to payment_method when payment_processor is empty' => sub {

        $mock->mock(
            user_payments => sub {
                return [$wcdeposit01, $atmwithdraw02, $pmdeposit03, $crypto_net_deposit01];
            });

        is_deeply(
            $auto_reject_obj->user_payment_details(),
            {
                count                      => 3,
                total_crypto_deposits      => $crypto_net_deposit01->{total_deposit_in_usd},
                non_crypto_deposit_amount  => $wcdeposit01->{total_deposit_in_usd} + $pmdeposit03->{total_deposit_in_usd},
                has_reversible_payment     => 1,
                reversible_deposit_amount  => $wcdeposit01->{total_deposit_in_usd},
                reversible_withdraw_amount => 0,
                non_crypto_withdraw_amount => $atmwithdraw02->{total_withdrawal_in_usd},
                last_reversible_deposit    => $wcdeposit01,
                payments                   => [$wcdeposit01, $atmwithdraw02, $pmdeposit03],
                method_wise_net_deposits   => {
                    $atmwithdraw02->{p_method} => $atmwithdraw02->{net_deposit},
                    $pmdeposit03->{p_method}   => $pmdeposit03->{net_deposit}
                },
                mastercard_deposit_amount         => 0,
                currency_wise_crypto_net_deposits => {$crypto_net_deposit01->{currency_code} => $crypto_net_deposit01->{net_deposit}},
                has_stable_method_deposits        => 1
            });

        $mock->unmock('user_payments');
    };

    subtest 'Correct net deposit calculation for payment agent transfer and p2p' => sub {
        $mock->mock(
            user_payments => sub {
                return [$payment_agent_deposit01, $payment_agent_deposit02, $payment_agent_withdrawal01, $p2p_deposit, $p2p_withdrawal];
            });

        is_deeply(
            $auto_reject_obj->user_payment_details(),
            {
                count                     => 5,
                total_crypto_deposits     => 0,
                non_crypto_deposit_amount => $payment_agent_deposit01->{total_deposit_in_usd} +
                    $payment_agent_deposit02->{total_deposit_in_usd} +
                    $p2p_deposit->{total_deposit_in_usd},
                has_reversible_payment     => 0,
                reversible_deposit_amount  => 0,
                reversible_withdraw_amount => 0,
                non_crypto_withdraw_amount => $payment_agent_withdrawal01->{total_withdrawal_in_usd} + $p2p_withdrawal->{total_withdrawal_in_usd},
                last_reversible_deposit    => undef,
                payments => [$payment_agent_deposit01, $payment_agent_deposit02, $payment_agent_withdrawal01, $p2p_deposit, $p2p_withdrawal],
                method_wise_net_deposits => {
                    payment_agent_transfer => $payment_agent_deposit01->{net_deposit} +
                        $payment_agent_deposit02->{net_deposit} +
                        $payment_agent_withdrawal01->{net_deposit},
                    p2p => $p2p_deposit->{net_deposit} + $p2p_withdrawal->{net_deposit}
                },
                mastercard_deposit_amount         => 0,
                currency_wise_crypto_net_deposits => {},
                has_stable_method_deposits        => 1
            });

        $mock->unmock('user_payments');
    };

    subtest 'Ignore unstable payment methods in net deposits' => sub {
        $mock->mock(
            user_payments => sub {
                return [
                    $payment_agent_deposit01,    $mastercarddeposit, $payment_agent_deposit02,
                    $payment_agent_withdrawal01, $p2p_deposit,       $p2p_withdrawal
                ];
            });

        is_deeply(
            $auto_reject_obj->user_payment_details(),
            {
                count                     => 6,
                total_crypto_deposits     => 0,
                non_crypto_deposit_amount => $payment_agent_deposit01->{total_deposit_in_usd} +
                    $payment_agent_deposit02->{total_deposit_in_usd} +
                    $p2p_deposit->{total_deposit_in_usd} +
                    $mastercarddeposit->{total_deposit_in_usd},
                has_reversible_payment     => 1,
                reversible_deposit_amount  => $mastercarddeposit->{total_deposit_in_usd},
                reversible_withdraw_amount => 0,
                non_crypto_withdraw_amount => $payment_agent_withdrawal01->{total_withdrawal_in_usd} + $p2p_withdrawal->{total_withdrawal_in_usd},
                last_reversible_deposit    => $mastercarddeposit,
                payments                   => [
                    $payment_agent_deposit01,    $mastercarddeposit, $payment_agent_deposit02,
                    $payment_agent_withdrawal01, $p2p_deposit,       $p2p_withdrawal
                ],
                method_wise_net_deposits => {
                    payment_agent_transfer => $payment_agent_deposit01->{net_deposit} +
                        $payment_agent_deposit02->{net_deposit} +
                        $payment_agent_withdrawal01->{net_deposit},
                    p2p => $p2p_deposit->{net_deposit} + $p2p_withdrawal->{net_deposit}
                },
                mastercard_deposit_amount         => 20000,
                currency_wise_crypto_net_deposits => {},
                has_stable_method_deposits        => 1
            });

        $mock->unmock('user_payments');
    };

    subtest 'has_stable_method_deposits is false if no deposit and 1 withdrawal through stable payment method' => sub {
        $mock->mock(
            user_payments => sub {
                return [$atmwithdraw02];
            });

        is_deeply(
            $auto_reject_obj->user_payment_details(),
            {
                count                             => 1,
                total_crypto_deposits             => 0,
                non_crypto_deposit_amount         => 0,
                has_reversible_payment            => 0,
                reversible_deposit_amount         => 0,
                reversible_withdraw_amount        => 0,
                non_crypto_withdraw_amount        => $atmwithdraw02->{total_withdrawal_in_usd},
                last_reversible_deposit           => undef,
                payments                          => [$atmwithdraw02],
                method_wise_net_deposits          => {$atmwithdraw02->{p_method} => $atmwithdraw02->{net_deposit}},
                mastercard_deposit_amount         => 0,
                currency_wise_crypto_net_deposits => {},
                has_stable_method_deposits        => 0
            });

        $mock->unmock('user_payments');
    };

    subtest 'has_stable_method_deposits is false if no user payments and negative net deposit for crypto' => sub {
        $mock->mock(
            user_payments => sub {
                return [$crypto_net_deposit02];
            });

        is_deeply(
            $auto_reject_obj->user_payment_details(),
            {
                count                             => 0,
                total_crypto_deposits             => $crypto_net_deposit02->{total_deposit_in_usd},
                non_crypto_deposit_amount         => 0,
                has_reversible_payment            => 0,
                reversible_deposit_amount         => 0,
                reversible_withdraw_amount        => 0,
                non_crypto_withdraw_amount        => 0,
                last_reversible_deposit           => undef,
                payments                          => [],
                method_wise_net_deposits          => {},
                mastercard_deposit_amount         => 0,
                currency_wise_crypto_net_deposits => {$crypto_net_deposit02->{currency_code} => $crypto_net_deposit02->{net_deposit}},
                has_stable_method_deposits        => 0
            });

        $mock->unmock('user_payments');
    };

    subtest 'has_stable_method_deposits is false if no payments through stable payment method' => sub {
        $mock->mock(
            user_payments => sub {
                return [$wcdeposit01];
            });

        is_deeply(
            $auto_reject_obj->user_payment_details(),
            {
                count                             => 1,
                total_crypto_deposits             => 0,
                non_crypto_deposit_amount         => $wcdeposit01->{total_deposit_in_usd},
                has_reversible_payment            => 1,
                reversible_deposit_amount         => $wcdeposit01->{total_deposit_in_usd},
                reversible_withdraw_amount        => 0,
                non_crypto_withdraw_amount        => 0,
                last_reversible_deposit           => $wcdeposit01,
                payments                          => [$wcdeposit01],
                method_wise_net_deposits          => {},
                mastercard_deposit_amount         => 0,
                currency_wise_crypto_net_deposits => {},
                has_stable_method_deposits        => 0
            });

        $mock->unmock('user_payments');
    }
};

done_testing;
