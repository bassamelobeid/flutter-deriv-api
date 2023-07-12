use strict;
use warnings;
no indirect;

use Test::More;
use Test::Fatal;
use Test::MockModule;
use Future::AsyncAwait;

use BOM::Platform::CryptoCashier::AutoUpdatePayouts::Approve;

my $mock             = Test::MockModule->new('BOM::Platform::CryptoCashier::AutoUpdatePayouts::Approve');
my $auto_approve_obj = BOM::Platform::CryptoCashier::AutoUpdatePayouts::Approve->new(broker_code => 'CR');

my $ccdeposit01 = {
    total_deposit_in_usd    => 37104.45,
    total_withdrawal_in_usd => 0.00,
    currency_code           => "ETH",
    payment_time            => "2020-10-20 20:21:20",
    net_deposit             => 37104.45,
    p_method                => 'WireCard',
    is_reversible           => 1,

};

my $ccdeposit02 = {
    total_deposit_in_usd    => 100.00,
    total_withdrawal_in_usd => 0.00,
    currency_code           => "USD",
    payment_time            => "2020-10-20 18:36:31",
    net_deposit             => 100.00,
    p_method                => 'WireCard',
    is_reversible           => 1,
};

my $ccwithdraw01 = {
    total_withdrawal_in_usd => -10.00,
    total_deposit_in_usd    => 0.00,
    currency_code           => "USD",
    payment_time            => "2020-10-20 18:36:31",
    net_deposit             => -10.00,
    p_method                => 'WireCard',
    is_reversible           => 1,
};

my $nonccwithdraw01 = {
    total_withdrawal_in_usd => -15.00,
    total_deposit_in_usd    => 0.00,
    currency_code           => "USD",
    payment_time            => "2020-10-20 21:36:31",
    net_deposit             => -15.00,
    p_method                => 'AirTM',
    is_reversible           => 0,
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

my $pa_net_deposit = {
    total_deposit_in_usd    => 25.00,
    total_withdrawal_in_usd => -5.00,
    net_deposit             => 20.00,
    currency_code           => "USD",
    is_reversible           => 0,
    p_method                => 'payment_agent_transfer',
    payment_time            => "2020-10-20 21:36:31",
};

my $p2p_net_deposit = {
    total_deposit_in_usd    => 40,
    total_withdrawal_in_usd => -10.00,
    net_deposit             => 30.00,
    currency_code           => "USD",
    is_reversible           => 0,
    p_method                => 'p2p',
    payment_time            => "2020-10-20 21:36:31",
};

my $cryptodeposit01 = {
    amount               => 0.009,
    amount_in_usd        => 424.88,
    currency_code        => "BTC",
    id                   => 2319,
    payment_gateway_code => 'ctc',
    payment_method       => undef,
    payment_processor    => undef,
    payment_time         => "2020-10-20 21:36:31",
};
my $cryptodeposit02 = {
    total_deposit_in_usd    => 224.88,
    total_withdrawal_in_usd => 0.00,
    net_deposit             => 224.88,
    currency_code           => "BTC",
    is_reversible           => 0,
    p_method                => 'ctc',
    payment_time            => "2020-10-20 21:36:31",
};
my $cryptodeposit03 = {
    amount               => 0.1,
    amount_in_usd        => 379.54,
    currency_code        => "ETH",
    id                   => 2319,
    payment_gateway_code => 'ctc',
    payment_method       => undef,
    payment_processor    => undef,
    payment_time         => "2020-10-20 21:36:31",
};
my $crypto_net_deposit = {
    total_deposit_in_usd    => 224.88,
    total_withdrawal_in_usd => -225.88,
    net_deposit             => -1,
    currency_code           => "BTC",
    is_reversible           => 0,
    p_method                => 'ctc',
    payment_time            => "2020-10-20 21:36:31",
};
my $cryptowithdrawal01 = {
    total_withdrawal_in_usd => -225.88,
    net_deposit             => -224.88,
    currency_code           => "BTC",
    is_reversible           => 0,
    p_method                => 'ctc',
    payment_time            => "2020-10-20 21:36:31",
};

my @mock_methods = ({
    payment_processor => 'WireCard',
    payment_method    => ''
});

subtest 'BOM::Platform::CryptoCashier::AutoUpdatePayouts::Approve->user_payment_details' => sub {
    subtest 'no payments' => sub {
        $mock->mock(
            user_payments => sub {
                return [];
            });

        is_deeply(
            $auto_approve_obj->user_payment_details(),
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

    subtest 'no reversible payments' => sub {
        my $non_reversible_deposit = {
            total_deposit_in_usd    => 100,
            total_withdrawal_in_usd => 0,
            net_deposit             => 100,
            currency_code           => "USD",
            id                      => 19,
            p_method                => "PayLivre",
            payment_time            => "2020-10-20 18:36:31",
            is_reversible           => 0
        };

        $mock->mock(
            user_payments => sub {
                return [$non_reversible_deposit, $payment_agent_deposit01];
            });

        my $response = $auto_approve_obj->user_payment_details();

        is_deeply(
            $response,
            {
                count                      => 2,
                total_crypto_deposits      => 0,
                non_crypto_deposit_amount  => 110.00,
                has_reversible_payment     => 0,
                reversible_deposit_amount  => 0,
                reversible_withdraw_amount => 0,
                non_crypto_withdraw_amount => 0,
                last_reversible_deposit    => undef,
                payments                   => [$non_reversible_deposit, $payment_agent_deposit01],
                method_wise_net_deposits   => {
                    payment_agent_transfer => 10,
                    PayLivre               => 100
                },
                mastercard_deposit_amount         => 0,
                currency_wise_crypto_net_deposits => {},
                has_stable_method_deposits        => 1
            });

        $mock->unmock('user_payments');
    };

    subtest '2 reversible deposits' => sub {

        $mock->mock(
            user_payments => sub {
                return [$ccdeposit01, $ccdeposit02, $crypto_net_deposit];
            });

        is_deeply(
            $auto_approve_obj->user_payment_details(),
            {
                count                             => 2,
                total_crypto_deposits             => $crypto_net_deposit->{total_deposit_in_usd},
                non_crypto_deposit_amount         => $ccdeposit01->{total_deposit_in_usd} + $ccdeposit02->{total_deposit_in_usd},
                has_reversible_payment            => 1,
                reversible_deposit_amount         => $ccdeposit01->{total_deposit_in_usd} + $ccdeposit02->{total_deposit_in_usd},
                reversible_withdraw_amount        => 0,
                non_crypto_withdraw_amount        => 0,
                last_reversible_deposit           => $ccdeposit01,
                payments                          => [$ccdeposit01, $ccdeposit02],
                method_wise_net_deposits          => {},
                mastercard_deposit_amount         => 0,
                currency_wise_crypto_net_deposits => {$crypto_net_deposit->{currency_code} => $crypto_net_deposit->{net_deposit}},
                has_stable_method_deposits        => 0
            });

        $mock->unmock('user_payments');
    };

    subtest '2 reversible deposits & 1 reversible withdraw' => sub {

        $mock->mock(
            user_payments => sub {
                return [$ccdeposit01, $ccdeposit02, $ccwithdraw01];
            });

        is_deeply(
            $auto_approve_obj->user_payment_details(),
            {
                count                             => 3,
                total_crypto_deposits             => 0,
                non_crypto_deposit_amount         => $ccdeposit01->{total_deposit_in_usd} + $ccdeposit02->{total_deposit_in_usd},
                has_reversible_payment            => 1,
                reversible_deposit_amount         => $ccdeposit01->{total_deposit_in_usd} + $ccdeposit02->{total_deposit_in_usd},
                reversible_withdraw_amount        => $ccwithdraw01->{total_withdrawal_in_usd},
                non_crypto_withdraw_amount        => $ccwithdraw01->{total_withdrawal_in_usd},
                last_reversible_deposit           => $ccdeposit01,
                payments                          => [$ccdeposit01, $ccdeposit02, $ccwithdraw01],
                method_wise_net_deposits          => {},
                mastercard_deposit_amount         => 0,
                currency_wise_crypto_net_deposits => {},
                has_stable_method_deposits        => 0
            });

        $mock->unmock('user_payments');
    };

    subtest '2 reversible deposits & 1 non-reversible withdraw' => sub {

        $mock->mock(
            user_payments => sub {
                return [$ccdeposit01, $ccdeposit02, $nonccwithdraw01];
            });

        is_deeply(
            $auto_approve_obj->user_payment_details(),
            {
                count                             => 3,
                total_crypto_deposits             => 0,
                non_crypto_deposit_amount         => $ccdeposit01->{total_deposit_in_usd} + $ccdeposit02->{total_deposit_in_usd},
                has_reversible_payment            => 1,
                reversible_deposit_amount         => $ccdeposit01->{total_deposit_in_usd} + $ccdeposit02->{total_deposit_in_usd},
                reversible_withdraw_amount        => 0,
                non_crypto_withdraw_amount        => $nonccwithdraw01->{total_withdrawal_in_usd},
                last_reversible_deposit           => $ccdeposit01,
                payments                          => [$ccdeposit01, $ccdeposit02, $nonccwithdraw01],
                method_wise_net_deposits          => {$nonccwithdraw01->{p_method} => $nonccwithdraw01->{total_withdrawal_in_usd}},
                mastercard_deposit_amount         => 0,
                currency_wise_crypto_net_deposits => {},
                has_stable_method_deposits        => 0
            });

        $mock->unmock('user_payments');
    };

    subtest 'payment agent deposits and withdrawals  &  p2p deposits & withdrawals' => sub {
        $mock->mock(
            user_payments => sub {
                return [$pa_net_deposit, $p2p_net_deposit];
            });

        is_deeply(
            $auto_approve_obj->user_payment_details(),
            {
                count                      => 2,
                total_crypto_deposits      => 0,
                non_crypto_deposit_amount  => $pa_net_deposit->{total_deposit_in_usd} + $p2p_net_deposit->{total_deposit_in_usd},
                has_reversible_payment     => 0,
                reversible_deposit_amount  => 0,
                reversible_withdraw_amount => 0,
                non_crypto_withdraw_amount => $pa_net_deposit->{total_withdrawal_in_usd} + $p2p_net_deposit->{total_withdrawal_in_usd},
                last_reversible_deposit    => undef,
                payments                   => [$pa_net_deposit, $p2p_net_deposit],
                method_wise_net_deposits   => {
                    payment_agent_transfer => $pa_net_deposit->{net_deposit},
                    p2p                    => $p2p_net_deposit->{net_deposit}
                },
                mastercard_deposit_amount         => 0,
                currency_wise_crypto_net_deposits => {},
                has_stable_method_deposits        => 1
            });

        $mock->unmock('user_payments');
    }
};

done_testing;
