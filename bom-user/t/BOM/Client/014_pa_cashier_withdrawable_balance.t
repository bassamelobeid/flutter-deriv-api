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
    BTC => 30000,
});

subtest 'Withdrawable balance' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'aff1@test.com'
    });
    $client->account('USD');

    my $sibling = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $sibling->account('BTC');

    my $user = BOM::User->create(
        email    => $client->email,
        password => 'x'
    );

    $user->add_client($_) for ($client, $sibling);

    my $pa_details = {
        payment_agent_name    => 'bob1',
        email                 => 'bob1@test.com',
        information           => 'x',
        summary               => 'x',
        commission_deposit    => 0,
        commission_withdrawal => 0,
        status                => 'authorized',
        currency_code         => 'USD',
        is_listed             => 't',
    };

    $client->payment_agent($pa_details);
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
            available => 0,
            accounts  => bag({
                    loginid  => $client->loginid,
                    currency => 'USD',
                    totals   => [],
                }
            ),
        },
        'After doughflow deposit'
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
            accounts   => bag({
                    loginid  => $client->loginid,
                    currency => 'USD',
                    totals   => bag({
                            payment_type => 'affiliate_reward',
                            credit       => num(11),
                            debit        => undef,
                        }
                    ),
                }
            ),
        },
        'After receive affiliate_reward'
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
            commission => 11,
            payouts    => 12,
            accounts   => bag({
                    loginid  => $client->loginid,
                    currency => 'USD',
                    totals   => bag({
                            payment_type => 'affiliate_reward',
                            credit       => num(11),
                            debit        => undef,
                        },
                        {
                            payment_type => 'external_cashier',
                            credit       => undef,
                            debit        => num(12),
                        },
                    ),
                }
            ),
        },
        'After doughflow withdrawal'
    );

    $client->payment_mt5_transfer(
        amount   => 13,
        currency => 'USD',
        remark   => 'x',
    );

    cmp_deeply(
        $pa->cashier_withdrawable_balance,
        {
            available  => 12,
            commission => 24,
            payouts    => 12,
            accounts   => bag({
                    loginid  => $client->loginid,
                    currency => 'USD',
                    totals   => bag({
                            payment_type => 'affiliate_reward',
                            credit       => num(11),
                            debit        => undef,
                        },
                        {
                            payment_type => 'external_cashier',
                            credit       => undef,
                            debit        => num(12),
                        },
                        {
                            payment_type => 'mt5_transfer',
                            credit       => num(13),
                            debit        => undef,
                        },
                    ),
                }
            ),
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
            commission => 24,
            payouts    => 24,
            accounts   => bag({
                    loginid  => $client->loginid,
                    currency => 'USD',
                    totals   => bag({
                            payment_type => 'affiliate_reward',
                            credit       => num(11),
                            debit        => undef,
                        },
                        {
                            payment_type => 'external_cashier',
                            credit       => undef,
                            debit        => num(24),
                        },
                        {
                            payment_type => 'mt5_transfer',
                            credit       => num(13),
                            debit        => undef,
                        },
                    ),
                }
            ),
        },
        'After 2nd doughflow withdrawal'
    );

    $client->payment_arbitrary_markup(
        amount   => 14,
        currency => 'USD',
        remark   => 'x',
    );

    cmp_deeply(
        $pa->cashier_withdrawable_balance,
        {
            available  => 14,
            commission => 38,
            payouts    => 24,
            accounts   => bag({
                    loginid  => $client->loginid,
                    currency => 'USD',
                    totals   => bag({
                            payment_type => 'affiliate_reward',
                            credit       => num(11),
                            debit        => undef,
                        },
                        {
                            payment_type => 'external_cashier',
                            credit       => undef,
                            debit        => num(24),
                        },
                        {
                            payment_type => 'mt5_transfer',
                            credit       => num(13),
                            debit        => undef,
                        },
                        {
                            payment_type => 'arbitrary_markup',
                            credit       => num(14),
                            debit        => undef,
                        },
                    ),
                }
            ),
        },
        'After arbitrary_markup received',
    );

    $client->payment_mt5_transfer(
        amount   => -2,
        currency => 'USD',
        remark   => 'x',
    );

    cmp_deeply(
        $pa->cashier_withdrawable_balance,
        {
            available  => 12,
            commission => 36,
            payouts    => 24,
            accounts   => bag({
                    loginid  => $client->loginid,
                    currency => 'USD',
                    totals   => bag({
                            payment_type => 'affiliate_reward',
                            credit       => num(11),
                            debit        => undef,
                        },
                        {
                            payment_type => 'external_cashier',
                            credit       => undef,
                            debit        => num(24),
                        },
                        {
                            payment_type => 'mt5_transfer',
                            credit       => num(13),
                            debit        => num(2),
                        },
                        {
                            payment_type => 'arbitrary_markup',
                            credit       => num(14),
                            debit        => undef,
                        },
                    ),
                }
            ),
        },
        'After transfer to MT5',
    );

    $client->payment_account_transfer(
        toClient     => $sibling,
        currency     => 'USD',
        amount       => 9,
        to_amount    => 9 / 30000,
        fees         => 0,
        gateway_code => 'account_transfer',
    );

    cmp_deeply(
        $pa->cashier_withdrawable_balance,
        {
            available  => 3,
            commission => 36,
            payouts    => 33,
            accounts   => bag({
                    loginid  => $client->loginid,
                    currency => 'USD',
                    totals   => bag({
                            payment_type => 'affiliate_reward',
                            credit       => num(11),
                            debit        => undef,
                        },
                        {
                            payment_type => 'external_cashier',
                            credit       => undef,
                            debit        => num(24),
                        },
                        {
                            payment_type => 'mt5_transfer',
                            credit       => num(13),
                            debit        => num(2),
                        },
                        {
                            payment_type => 'arbitrary_markup',
                            credit       => num(14),
                            debit        => undef,
                        },
                        {
                            payment_type => 'internal_transfer',
                            credit       => undef,
                            debit        => num(9),
                        },
                    ),
                }
            ),
        },
        'After transfer to non-PA sibling',
    );

    $sibling->payment_agent($pa_details);
    $sibling->save;
    my $sibling_pa = $sibling->get_payment_agent;

    cmp_deeply(
        $pa->cashier_withdrawable_balance,
        {
            available  => 12,
            commission => 36,
            payouts    => 24,
            accounts   => bag({
                    loginid  => $client->loginid,
                    currency => 'USD',
                    totals   => bag({
                            payment_type => 'affiliate_reward',
                            credit       => num(11),
                            debit        => undef,
                        },
                        {
                            payment_type => 'external_cashier',
                            credit       => undef,
                            debit        => num(24),
                        },
                        {
                            payment_type => 'mt5_transfer',
                            credit       => num(13),
                            debit        => num(2),
                        },
                        {
                            payment_type => 'arbitrary_markup',
                            credit       => num(14),
                            debit        => undef,
                        },
                    ),
                },
                {
                    loginid  => $sibling->loginid,
                    currency => 'BTC',
                    totals   => [],
                },
            ),
        },
        'After sibling becomes a PA',
    );
    $sibling->payment_ctc(
        amount    => sprintf('%.6f', -8 / 30000),
        currency  => 'BTC',
        remark    => 'x',
        crypto_id => 123,
    );

    cmp_deeply(
        $pa->cashier_withdrawable_balance,
        {
            available  => num(4, .1),
            commission => 36,
            payouts    => num(32, .1),
            accounts   => bag({
                    loginid  => $client->loginid,
                    currency => 'USD',
                    totals   => bag({
                            payment_type => 'affiliate_reward',
                            credit       => num(11),
                            debit        => undef,
                        },
                        {
                            payment_type => 'external_cashier',
                            credit       => undef,
                            debit        => num(24),
                        },
                        {
                            payment_type => 'mt5_transfer',
                            credit       => num(13),
                            debit        => num(2),
                        },
                        {
                            payment_type => 'arbitrary_markup',
                            credit       => num(14),
                            debit        => undef,
                        },
                    ),
                },
                {
                    loginid  => $sibling->loginid,
                    currency => 'BTC',
                    totals   => bag({
                            payment_type => 'crypto_cashier',
                            credit       => undef,
                            debit        => num(8 / 30000, .1),
                        },
                    ),
                },
            ),
        },
        'After PA sibling cashier withdrawal',
    );

    cmp_deeply(
        $sibling_pa->cashier_withdrawable_balance,
        {
            available  => num(4 / 30000,  .1),
            commission => num(36 / 30000, .1),
            payouts    => num(32 / 30000, .1),
            accounts   => bag({
                    loginid  => $client->loginid,
                    currency => 'USD',
                    totals   => bag({
                            payment_type => 'affiliate_reward',
                            credit       => num(11),
                            debit        => undef,
                        },
                        {
                            payment_type => 'external_cashier',
                            credit       => undef,
                            debit        => num(24),
                        },
                        {
                            payment_type => 'mt5_transfer',
                            credit       => num(13),
                            debit        => num(2),
                        },
                        {
                            payment_type => 'arbitrary_markup',
                            credit       => num(14),
                            debit        => undef,
                        },
                    ),
                },
                {
                    loginid  => $sibling->loginid,
                    currency => 'BTC',
                    totals   => bag({
                            payment_type => 'crypto_cashier',
                            credit       => undef,
                            debit        => num(8 / 30000, .1),
                        },
                    ),
                },
            ),
        },
        'PA sibling gets correct result',
    );

    $sibling_pa->status('suspended');
    $sibling_pa->save;

    cmp_deeply(
        $pa->cashier_withdrawable_balance,
        {
            available  => 3,
            commission => 36,
            payouts    => 33,
            accounts   => bag({
                    loginid  => $client->loginid,
                    currency => 'USD',
                    totals   => bag({
                            payment_type => 'affiliate_reward',
                            credit       => num(11),
                            debit        => undef,
                        },
                        {
                            payment_type => 'external_cashier',
                            credit       => undef,
                            debit        => num(24),
                        },
                        {
                            payment_type => 'mt5_transfer',
                            credit       => num(13),
                            debit        => num(2),
                        },
                        {
                            payment_type => 'arbitrary_markup',
                            credit       => num(14),
                            debit        => undef,
                        },
                        {
                            payment_type => 'internal_transfer',
                            credit       => undef,
                            debit        => num(9),
                        },
                    ),
                }
            ),
        },
        'After sibling PA is suspended',
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

    my $mock_pa = Test::MockModule->new('BOM::User::Client::PaymentAgent');
    $mock_pa->mock(service_is_allowed => sub { return $_[1] eq 'cashier_withdraw' });

    cmp_ok $client->balance_for_doughflow, '==', 101 + 31, 'full balance when tier allows cashier_withdraw';
};

subtest 'client used MT5 before becoming PA' => sub {

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'aff5@test.com'
    });
    my $user = BOM::User->create(
        email    => $client->email,
        password => 'x'
    )->add_client($client);
    $client->account('USD');
    BOM::Test::Helper::Client::top_up($client, 'USD', 100);

    $client->payment_mt5_transfer(
        amount   => -10,
        currency => 'USD',
        remark   => 'x',
    );

    $client->payment_agent({
        payment_agent_name    => 'bob6',
        email                 => $client->email,
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

    # checking we don't get warnings because deposits are null (COMP-938)
    is $pa->cashier_withdrawable_balance->{available}, 0, 'limit is zero';
};

done_testing();
