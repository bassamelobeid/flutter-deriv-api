use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::MockModule;

use BOM::User::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client;
use BOM::Test::Helper::ExchangeRates qw/populate_exchange_rates/;

populate_exchange_rates({
    BTC => 3000,
});

subtest 'Fiat PA' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'aff1@test.com'
    });
    BOM::User->create(
        email    => $client->email,
        password => 'x'
    )->add_client($client);
    $client->account('USD');

    $client->payment_agent({
        payment_agent_name    => 'bob1',
        email                 => 'bob1@test.com',
        information           => 'x',
        summary               => 'x',
        commission_deposit    => 0,
        commission_withdrawal => 0,
        status                => 'authorized',
        currency_code         => 'USD',
        is_listed             => 't',
    });
    $client->save;
    my $pa = $client->get_payment_agent;

    $client->payment_doughflow(
        amount   => 10,
        currency => 'USD',
        remark   => 'x',
    );

    cmp_deeply(
        $pa->cashier_withdrawable_balance,
        {
            available  => 0,
            commission => 0,
            payouts    => 0,
        },
        'Cannot withdraw doughflow deposit'
    );

    $client->payment_affiliate_reward(
        amount   => 11,
        currency => 'USD',
        remark   => 'x',
    );

    cmp_deeply(
        $pa->cashier_withdrawable_balance,
        {
            available  => 11,
            commission => 11,
            payouts    => 0,
        },
        'Allowed to withdraw affiliate_reward'
    );

    $client->payment_doughflow(
        amount   => -11,
        currency => 'USD',
        remark   => 'x',
    );

    cmp_deeply(
        $pa->cashier_withdrawable_balance,
        {
            available  => 0,
            commission => 11,
            payouts    => 11,
        },
        'After withdraw commission'
    );

    $client->payment_mt5_transfer(
        amount   => 12,
        currency => 'USD',
        remark   => 'x',
    );

    cmp_deeply(
        $pa->cashier_withdrawable_balance,
        {
            available  => 12,
            commission => 23,
            payouts    => 11,
        },
        'After mt5 commision received'
    );

    $client->payment_doughflow(
        amount   => -12,
        currency => 'USD',
        remark   => 'x',
    );

    cmp_deeply(
        $pa->cashier_withdrawable_balance,
        {
            available  => 0,
            commission => 23,
            payouts    => 23,
        },
        'After doughflow withdrawal'
    );

    $client->payment_arbitrary_markup(
        amount   => 13,
        currency => 'USD',
        remark   => 'x',
    );

    cmp_deeply(
        $pa->cashier_withdrawable_balance,
        {
            available  => 13,
            commission => 36,
            payouts    => 23,
        },
        'After api commision received',
    );

    $client->payment_mt5_transfer(
        amount   => -2,
        currency => 'USD',
        remark   => 'x',
    );

    cmp_deeply(
        $pa->cashier_withdrawable_balance,
        {
            available  => 11,
            commission => 34,
            payouts    => 23,
        },
        'Withdrawals to MT5 are excluded',
    );

    $pa->status('applied');

    cmp_deeply(
        $pa->cashier_withdrawable_balance,
        {
            available  => num(21),
            commission => 34,
            payouts    => 23,
        },
        'Can withdraw full balance if status not authorized'
    );

};

subtest 'Crypto PA' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'aff2@test.com'
    });
    BOM::User->create(
        email    => $client->email,
        password => 'x'
    )->add_client($client);
    $client->account('USDC');
    $client->payment_agent({
        payment_agent_name    => 'bob2',
        email                 => 'bob2@test.com',
        information           => 'x',
        summary               => 'x',
        commission_deposit    => 0,
        commission_withdrawal => 0,
        status                => 'authorized',
        currency_code         => 'USD',
        is_listed             => 't',
    });
    $client->save;
    my $pa = $client->get_payment_agent;

    $client->payment_ctc(
        amount    => 10,
        currency  => 'USDC',
        crypto_id => 1,
    );

    cmp_deeply(
        $pa->cashier_withdrawable_balance,
        {
            available  => 0,
            commission => 0,
            payouts    => 0,
        },
        'Cannot withdraw crypto deposit'
    );

    $client->payment_affiliate_reward(
        amount   => 5,
        currency => 'USDC',
        remark   => 'x',
    );

    cmp_deeply(
        $pa->cashier_withdrawable_balance,
        {
            available  => 5,
            commission => 5,
            payouts    => 0,
        },
        'After affiliate reward'
    );

    $client->payment_ctc(
        amount    => -5,
        currency  => 'USDC',
        crypto_id => 2,
    );

    cmp_deeply(
        $pa->cashier_withdrawable_balance,
        {
            available  => 0,
            commission => 5,
            payouts    => 5,
        },
        'After crypto withdrawal'
    );
};

subtest 'PA with siblings' => sub {
    my $usd_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'aff3@test.com'
    });
    my $user = BOM::User->create(
        email    => $usd_client->email,
        password => 'x'
    )->add_client($usd_client);
    $usd_client->account('USD');
    BOM::Test::Helper::Client::top_up($usd_client, 'USD', 1000);

    $usd_client->payment_agent({
            payment_agent_name    => 'bob3',
            email                 => 'bob3@test.com',
            information           => 'x',
            summary               => 'x',
            commission_deposit    => 0,
            commission_withdrawal => 0,
            status                => 'authorized',
            currency_code         => 'USD',
            is_listed             => 't',
        })->client_loginid;
    $usd_client->save;
    my $usd_pa = $usd_client->get_payment_agent;

    my $btc_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    $btc_client->account('BTC');
    $user->add_client($btc_client);

    $btc_client->payment_agent({
        payment_agent_name    => 'bob4',
        email                 => 'bob4@test.com',
        information           => 'x',
        summary               => 'x',
        commission_deposit    => 0,
        commission_withdrawal => 0,
        status                => 'authorized',
        currency_code         => 'BTC',
        is_listed             => 't',
    });
    $btc_client->save;
    my $btc_pa = $btc_client->get_payment_agent;

    $btc_client->payment_affiliate_reward(
        amount   => 0.02,    # 60 USD equivalent
        currency => 'BTC',
        remark   => 'x',
    );

    cmp_deeply(
        $usd_pa->cashier_withdrawable_balance,
        {
            available  => 60,
            commission => 60,
            payouts    => 0,
        },
        'USD pa can withdraw after sibling PA gets affiliate reward'
    );

    $usd_client->payment_doughflow(
        amount   => -45,     # 0.015 BTC equivalent
        currency => 'USD',
        remark   => 'x',
    );

    cmp_deeply(
        $btc_pa->cashier_withdrawable_balance,
        {
            available  => 0.005,
            commission => 0.02,
            payouts    => 0.015,
        },
        'BTC pa limit reduced after sibling PA withdraws'
    );

    $btc_client->payment_ctc(
        amount    => -0.005,
        currency  => 'BTC',
        crypto_id => 3,
    );

    cmp_deeply(
        $usd_pa->cashier_withdrawable_balance,
        {
            available  => 0,
            commission => 60,
            payouts    => 60,
        },
        'USD pa cannot withdraw after sibling withdrew everything'
    );
};

subtest 'balance_for_doughflow' => sub {

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'aff4@test.com'
    });
    my $user = BOM::User->create(
        email    => $client->email,
        password => 'x'
    )->add_client($client);
    $client->account('USD');
    BOM::Test::Helper::Client::top_up($client, 'USD', 101);

    cmp_ok $client->balance_for_doughflow, '==', 101, 'balance for regular client';

    $client->payment_agent({
        payment_agent_name    => 'bob5',
        email                 => $client->email,
        information           => 'x',
        summary               => 'x',
        commission_deposit    => 0,
        commission_withdrawal => 0,
        status                => 'applied',
        currency_code         => 'USD',
        is_listed             => 't',
    });
    $client->save;
    my $pa = $client->get_payment_agent;

    cmp_ok $client->balance_for_doughflow, '==', 101, 'balance for applied pa';

    $pa->status('authorized');

    cmp_ok $client->balance_for_doughflow, '==', 0, 'balance for authorized pa';

    $client->payment_affiliate_reward(
        amount   => 31,
        currency => 'USD',
        remark   => 'x',
    );
    $client->save;

    cmp_ok $client->balance_for_doughflow, '==', 31, 'balance for pa with commission';
};

done_testing();
