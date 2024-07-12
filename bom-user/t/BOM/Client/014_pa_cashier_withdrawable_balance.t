use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::MockModule;

use BOM::User::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client;
use BOM::Test::Helper::ExchangeRates;
use BOM::Test::Customer;
use ExchangeRates::CurrencyConverter qw(convert_currency);

my %rates = (ETH => 4000);
BOM::Test::Helper::ExchangeRates::populate_exchange_rates(\%rates);
BOM::Test::Helper::ExchangeRates::populate_exchange_rates_db(BOM::Database::ClientDB->new({broker_code => 'CR'})->db->dbic, \%rates);

subtest 'Withdrawable balance' => sub {
    my $test_customer = BOM::Test::Customer->create(
        clients => [{
                name            => 'CR1',
                broker_code     => 'CR',
                default_account => 'USD',
            },
            {
                name            => 'CR2',
                broker_code     => 'CR',
                default_account => 'ETH',
            }]);
    my $client  = $test_customer->get_client_object('CR1');
    my $sibling = $test_customer->get_client_object('CR2');

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
        amount   => 100,
        currency => 'USD',
        remark   => 'x',
    );

    cmp_ok $pa->cashier_withdrawable_balance, '==', 0, 'After doughflow deposit';

    $client->payment_affiliate_reward(
        amount   => 11,
        currency => 'USD',
        remark   => 'x',
    );

    cmp_ok $pa->cashier_withdrawable_balance, '==', 11, 'After receive affiliate_reward';

    $client->payment_doughflow(
        amount   => -12,
        currency => 'USD',
        remark   => 'x',
    );

    cmp_ok $pa->cashier_withdrawable_balance, '==', 0, 'After doughflow withdrawal';

    $client->payment_mt5_transfer(
        amount   => 13,
        currency => 'USD',
        remark   => 'x',
    );

    cmp_ok $pa->cashier_withdrawable_balance, '==', 12, 'After mt5 commision received';

    $client->payment_doughflow(
        amount   => -12,
        currency => 'USD',
        remark   => 'x',
    );

    cmp_ok $pa->cashier_withdrawable_balance, '==', 0, 'After 2nd doughflow withdrawal';

    $client->payment_arbitrary_markup(
        amount   => 14,
        currency => 'USD',
        remark   => 'x',
    );

    cmp_ok $pa->cashier_withdrawable_balance, '==', 14, 'After arbitrary_markup received';

    $client->payment_mt5_transfer(
        amount   => -20,
        currency => 'USD',
        remark   => 'x',
    );

    cmp_ok $pa->cashier_withdrawable_balance, '==', 14, 'Transfer to MT5 not included';

    $client->payment_account_transfer(
        toClient     => $sibling,
        currency     => 'USD',
        amount       => 3,
        to_amount    => convert_currency(3, 'USD', 'ETH'),
        fees         => 0,
        gateway_code => 'account_transfer',
    );

    cmp_ok $pa->cashier_withdrawable_balance, '==', 11, 'After transfer to non-PA sibling';

    $sibling->payment_agent($pa_details);
    $sibling->save;
    my $sibling_pa = $sibling->get_payment_agent;

    cmp_ok $sibling_pa->cashier_withdrawable_balance, '==', convert_currency(3, 'USD', 'ETH'), 'PA sibling can withdraw';

    $sibling->payment_account_transfer(
        toClient     => $client,
        currency     => 'ETH',
        amount       => convert_currency(1, 'USD', 'ETH'),
        to_amount    => 1,
        fees         => 0,
        gateway_code => 'account_transfer',
    );

    cmp_ok $sibling_pa->cashier_withdrawable_balance, '==', convert_currency(2, 'USD', 'ETH'),, 'PA after transfer to PA sibling';
    cmp_ok $pa->cashier_withdrawable_balance,         '==', 11,                                 'PA after transfer from PA sibling';

    $sibling->payment_ctc(
        amount    => convert_currency(-2, 'USD', 'ETH'),
        currency  => 'ETH',
        remark    => 'x',
        crypto_id => 123,
    );

    cmp_ok $sibling_pa->cashier_withdrawable_balance, '==', 0, 'PA after crypto withdrawal';
    cmp_ok $pa->cashier_withdrawable_balance,         '==', 9, 'PA sibling after crypto withdrawal';

    $pa->status('suspended');
    $pa->save;

    cmp_ok $pa->cashier_withdrawable_balance, '==', 92, 'full balance returned when PA is suspended';
};

subtest 'balance_for_doughflow' => sub {
    my $test_customer = BOM::Test::Customer->create(
        clients => [{
                name            => 'CR',
                broker_code     => 'CR',
                default_account => 'USD',
            }]);
    my $client = $test_customer->get_client_object('CR');

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
    my $test_customer = BOM::Test::Customer->create(
        clients => [{
                name            => 'CR',
                broker_code     => 'CR',
                default_account => 'USD',
            }]);
    my $client = $test_customer->get_client_object('CR');

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
    cmp_ok $pa->cashier_withdrawable_balance, '==', 0, 'limit is zero';
};

done_testing();
