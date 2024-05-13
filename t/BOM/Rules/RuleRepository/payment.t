use strict;
use warnings;

use Test::Most;
use Test::Fatal;
use Test::Exception;
use Test::MockModule;
use Test::MockTime qw(set_fixed_time restore_time);
use Syntax::Keyword::Try;
use Format::Util::Numbers            qw(financialrounding);
use ExchangeRates::CurrencyConverter qw/convert_currency/;
use BOM::Test::Helper::ExchangeRates qw/populate_exchange_rates/;
use BOM::Test::Helper::Client;
use BOM::TradingPlatform;

populate_exchange_rates({
    USD => 1,
    EUR => 1.1888,
    GBP => 1.3333,
    JPY => 0.0089,
    BTC => 5500,
    BCH => 320,
    LTC => 50,
    ETH => 2000,
});

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Rules::Engine;
use BOM::User;
use BOM::TradingPlatform;

my $user = BOM::User->create(
    email    => 'rules_payment@binary.com',
    password => 'abcd'
);
my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});

my $crypto_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});

$user->add_client($client);
$user->add_client($crypto_client);

$client->set_default_account('USD');
$crypto_client->set_default_account('BTC');

$client->payment_free_gift(
    currency     => 'USD',
    amount       => 1_000,
    remark       => 'here is money',
    payment_type => 'free_gift'
);

$crypto_client->payment_free_gift(
    currency     => 'BTC',
    amount       => 0.005,
    remark       => 'here is money',
    payment_type => 'free_gift'
);

sub new_client {
    my ($currency, %args) = @_;
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => $args{broker_code} // 'CR',
        residence   => $args{residence}   // 'id'
    });
    $client->set_default_account($currency);
    $user->add_client($client);

    return $client;
}

my $rule_engine = BOM::Rules::Engine->new(client => $client);

my $rule_name = 'payment.currency_matches_account';
subtest $rule_name => sub {
    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    my %args = (loginid => $client->loginid);
    like exception { $rule_engine->apply_rules($rule_name, %args) }, qr'Payment currency is missing', 'Payment currency is required';

    $args{currency} = 'EUR';
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'CurrencyMismatch',
        params     => ['EUR', 'USD'],
        rule       => $rule_name,
        },
        'Payment currency does not match account';

    $args{currency} = 'USD';
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Rule applies matching currencies';
};

$rule_name = 'deposit.total_balance_limits';
subtest $rule_name => sub {
    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    my %args = (
        loginid => $client->loginid,
        action  => 'withdrawal'
    );
    like exception { $rule_engine->apply_rules($rule_name, %args) }, qr/The rule deposit.total_balance_limits is for deposit actions only/,
        'Wrong action type error';

    $args{action} = 'deposit';
    like exception { $rule_engine->apply_rules($rule_name, %args) }, qr/Amount is required/, 'Error for missing amount';

    my $mock_client = Test::MockModule->new('BOM::User::Client');
    $mock_client->redefine(fixed_max_balance => 5000);

    cmp_ok $client->account->balance, '==', 1000, 'Client balance is 1000 USD';
    $args{amount} = 4001;

    if (!$client->landing_company->unlimited_balance) {
        is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
            {
            error_code => 'BalanceExceeded',
            rule       => $rule_name,
            params     => [5000, 'USD']
            },
            'Balance will become more than max balance with this payment';
    }

    $client->set_exclusion();
    $client->self_exclusion->max_balance(4000);
    $client->save;
    $args{amount} = 3001;

    if (!$client->landing_company->unlimited_balance) {
        is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
            {
            error_code => 'SelfExclusionLimitExceeded',
            rule       => $rule_name,
            params     => [4000, 'USD']
            },
            'Balance cannot exceed self-exclusion limit';
    }

    $args{amount} = 3000;
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'It is OK to reach at the limit itself';

    $mock_client->unmock_all;
};

$rule_name = 'deposit.periodical_balance_limits';
subtest $rule_name => sub {
    my %args    = (loginid => $client->loginid);
    my $mock_lc = Test::MockModule->new('LandingCompany');

    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});

    $client_cr->set_default_account('USD');
    is_deeply $client_cr->get_deposit_limits, {}, 'deposit settings are empty in the beginning';
    $client_cr->set_exclusion();

    my $rule_engine = BOM::Rules::Engine->new(client => [$client_cr]);
    like exception { $rule_engine->apply_rules($rule_name, loginid => $client_cr->loginid) }, qr/Amount is required/, 'Amount is missing';
    like exception { $rule_engine->apply_rules($rule_name, loginid => $client_cr->loginid, amount => 1) }, qr/is for deposit actions only/,
        'Wrong action type error';

    my %limit_duration_to_name = (
        '30' => 'max_deposit_30day',
        '7'  => 'max_deposit_7day',
        '1'  => 'max_deposit_daily'
    );

    for my $limit_duration (30, 7, 1) {
        my $limit_name   = $limit_duration_to_name{$limit_duration};
        my $limit_short  = $limit_name =~ s/max_deposit_//r;
        my $limit_amount = $limit_duration * 100;

        $client_cr->self_exclusion->$limit_name($limit_amount);
        $client_cr->save;

        is_deeply $client_cr->get_deposit_limits, {$limit_short => $limit_amount}, 'Deposit limits are updated';

        ok $client_cr->payment_free_gift(
            currency => 'USD',
            amount   => $limit_amount,
            remark   => 'initial deposit',
            ),
            'Let the balance reach at the limit';

        my $payment      = $client->db->dbic->run(fixup => sub { $_->selectrow_hashref("SELECT * FROM payment.payment ORDER BY id DESC LIMIT 1"); });
        my $payment_time = Date::Utility->new($payment->{payment_time})->epoch;

        my $one_usd_payment = {
            currency => 'USD',
            amount   => 1,
        };

        # move time forward to 1 day less than limit duration
        set_fixed_time($payment_time + ($limit_duration - 1) * 86400);

        lives_ok { $rule_engine->apply_rules($rule_name, %$one_usd_payment, loginid => $client_cr->loginid, action => 'deposit') }
        "we can deposit if deposit limits are disabled for the landing company";
        # move time forward exactly the same number of days as limit duration
        set_fixed_time($payment_time + ($limit_duration + 1) * 86400);
        lives_ok { $rule_engine->apply_rules($rule_name, %$one_usd_payment, loginid => $client_cr->loginid, action => 'deposit') }
        "we can deposit to the limit-disabled landing company any time, can' t we? ";

        $client_cr->self_exclusion->$limit_name(undef);
        is_deeply($client_cr->get_deposit_limits, {}, 'deposit limits are reset');
        restore_time();
    }

    $mock_lc->unmock_all();
};

$rule_name = 'withdrawal.less_than_balance';
subtest $rule_name => sub {
    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    my %args = (loginid => $client->loginid);
    like exception { $rule_engine->apply_rules($rule_name, %args) }, qr'Amount is required', 'Payment amount is required';

    $args{amount} = 1001;
    like exception { $rule_engine->apply_rules($rule_name, %args) }, qr'is for withdrawal actions only', 'Payment type is required';

    $args{action} = 'withdrawal';
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'AmountExceedsBalance',
        params     => [1001, 'USD', '1000.00'],
        rule       => $rule_name,
        },
        'Payment amouth exceeds balance';

    $args{amount} = 1000;
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Rule applies with amount <= balance';
};

$rule_name = 'withdrawal.age_verification_limits';
subtest $rule_name => sub {
    my $rule_engine = BOM::Rules::Engine->new(client => $crypto_client);
    my %args        = (loginid => $crypto_client->loginid);
    $crypto_client->payment_free_gift(
        currency     => 'BTC',
        amount       => 10,
        remark       => 'here is money',
        payment_type => 'free_gift'
    );
    $crypto_client->payment_bank_wire(
        currency => 'BTC',
        amount   => -0.01,
        remark   => 'here is money',
    );

    my $dxtrader = BOM::TradingPlatform->new(
        platform => 'dxtrade',
        client   => $crypto_client
    );

    $dxtrader->client_payment(
        payment_type => 'dxtrade_transfer',
        amount       => -2,
        remark       => 'legacy remark',
        txn_details  => {
            dxtrade_account_id => 'DXD001',
            fees               => 0,
        },
    );
    my %params = (
        currency => $crypto_client->currency,
    );

    $crypto_client->payment_mt5_transfer(
        %params,
        remark      => 'blabla',
        amount      => -2,
        txn_details => {
            mt5_account => '102',
            fees        => 0,
        },
    );

    $args{action}       = 'withdrawal';
    $args{payment_type} = 'crypto_cashier';
    $args{amount}       = 0.01;

    is_deeply(exception { $rule_engine->apply_rules($rule_name, %args) }, exception {}, 'no exceptions for account_trasfer gateway code');
    $args{amount} = 2;
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'CryptoLimitAgeVerified',
        params     => [2, 'BTC', 1000],
        rule       => $rule_name,
        },
        'age verification required for withdrawal over limit';
};

$rule_name = 'withdrawal.only_unfrozen_balance';
subtest $rule_name => sub {
    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    my %args = (loginid => $client->loginid);
    like exception { $rule_engine->apply_rules($rule_name, %args) }, qr'Amount is required', 'Payment amount is required';

    $args{amount} = 901;
    like exception { $rule_engine->apply_rules($rule_name, %args) }, qr'is for withdrawal actions only', 'Payment type is required';

    $args{action} = 'withdrawal';

    my $mock_client = Test::MockModule->new('BOM::User::Client');
    $mock_client->redefine(get_withdrawal_limits => +{frozen_free_gift => 100});
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'AmountExceedsUnfrozenBalance',
        params     => ['USD', '901.00', '1000.00', '100.00'],
        rule       => $rule_name,
        },
        'Payment amount exceeeds unfrozen balance';

    $args{amount} = 900;
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Rule applies with amount <= unfrozed';
};

$rule_name = 'withdrawal.landing_company_limits';
subtest $rule_name => sub {

    my %deposit = (
        currency     => 'USD',
        payment_type => 'free_gift',
        remark       => 'test'
    );

    subtest 'CR unauthenticated' => sub {
        my $client      = new_client('USD');
        my $dbh         = $client->dbh;
        my $rule_engine = BOM::Rules::Engine->new(client => $client);
        my %args        = (loginid => $client->loginid);
        like exception { $rule_engine->apply_rules($rule_name, %args) }, qr/Amount is required/, 'Payment amount is required';

        $args{amount} = 1;
        like exception { $rule_engine->apply_rules($rule_name, %args) }, qr/is for withdrawal actions only/, 'Payment type is required';

        $args{action} = 'withdrawal';

        my %emitted;
        my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
        $mock_events->mock(
            'emit',
            sub {
                my ($type, $data) = @_;
                $emitted{$data->{loginid}} = $type;
            });

        $client->payment_legacy_payment(%deposit, amount => 10500);
        $args{amount} = -10001;
        is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
            {
            rule       => $rule_name,
            error_code => 'WithdrawalLimit',
            params     => ['10000.00', 'USD']
            },
            'Non-Authed CR withdrawal greater than USD10K';

        $args{amount} = -10000;
        lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Non-Authed CR withdrawal USD10K';
        $args{amount} = -9999;
        lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Non-Authed CR withdrawal USD9999';

        $mock_events->unmock_all();
    };

    subtest 'CR - no limit for fully authenticated clients and internal transfers' => sub {
        my $client      = new_client('USD');
        my $rule_engine = BOM::Rules::Engine->new(client => $client);

        my %args = (
            loginid => $client->loginid,
            action  => 'withdrawal'
        );
        lives_ok { $rule_engine->apply_rules($rule_name, %args, amount => -10001, is_internal => 1) } 'Internal transfer more than USD10K';

        $client->status->set('age_verification', 'system', 'Successfully authenticated identity via Experian Prove ID',);
        $client->set_authentication('ID_DOCUMENT', {status => 'pass'});
        $client->payment_legacy_payment(%deposit, amount => 20000);

        lives_ok { $rule_engine->apply_rules($rule_name, %args, amount => -10000) } 'Authed CR withdrawal no more than USD10K';
        lives_ok { $rule_engine->apply_rules($rule_name, %args, amount => -10001) } 'Authed CR withdrawal more than USD10K';
    };
};

$rule_name = 'withdrawal.p2p_and_payment_agent_deposits';
subtest $rule_name => sub {

    my $mock_client = Test::MockModule->new('BOM::User::Client');

    subtest 'pa only' => sub {
        my $user = BOM::User->create(
            email    => 'padeposits@test.com',
            password => 'x'
        );

        my (%clients, %pas);
        for my $cur (qw(USD BTC ETH)) {
            $clients{$cur} = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR', binary_user_id => $user->id});
            $clients{$cur}->account($cur);
            $pas{$cur} = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
            $pas{$cur}->account($cur);
            BOM::Test::Helper::Client::top_up($pas{$cur}, $cur, sprintf('%.6f', convert_currency(1000, 'USD', $cur)));
            $pas{$cur}->payment_agent({
                payment_agent_name    => '',
                email                 => '',
                information           => '',
                summary               => '',
                commission_deposit    => 0,
                commission_withdrawal => 0,
                currency_code         => $cur,
            });
            $pas{$cur}->save;
        }

        my $rule_engine = BOM::Rules::Engine->new(client => $clients{USD});

        lives_ok { $rule_engine->apply_rules($rule_name, loginid => $clients{USD}->loginid, payment_type => 'doughflow', amount => -1000) }
        'No PA deposits yet, can withdraw max';

        BOM::Test::Helper::Client::top_up($clients{USD}, 'USD', 10);

        $pas{USD}->payment_account_transfer(
            toClient           => $clients{USD},
            amount             => 100,
            to_amount          => 100,
            currency           => 'USD',
            fees               => 0,
            gateway_code       => 'payment_agent_transfer',
            is_agent_to_client => 1,
        );

        lives_ok { $rule_engine->apply_rules($rule_name, loginid => $clients{USD}->loginid, payment_type => 'doughflow', amount => -10) }
        'Can withdraw doughflow portion.';

        cmp_deeply(
            exception { $rule_engine->apply_rules($rule_name, loginid => $clients{USD}->loginid, payment_type => 'doughflow', amount => -10.01) },
            {
                error_code => 'PADepositsWithdrawalLimit',
                params     => ['10.00', 'USD'],
                rule       => $rule_name
            },
            'Cannot withdraw amount that includes PA deposits',
        );

        for my $type (qw(internal_transfer mt5_transfer dxtrade_transfer ctrader_transfer p2p)) {
            lives_ok { $rule_engine->apply_rules($rule_name, loginid => $clients{USD}->loginid, payment_type => $type, amount => -10.01) }
            "$type is not blocked.";
        }

        BOM::Test::Helper::Client::top_up($clients{BTC}, 'BTC', sprintf('%.6f', convert_currency(11, 'USD', 'BTC')));

        $pas{BTC}->payment_account_transfer(
            toClient           => $clients{BTC},
            amount             => sprintf('%.6f', 101 / 5500),
            to_amount          => sprintf('%.6f', 101 / 5500),
            currency           => 'BTC',
            fees               => 0,
            gateway_code       => 'payment_agent_transfer',
            is_agent_to_client => 1,
        );

        lives_ok { $rule_engine->apply_rules($rule_name, loginid => $clients{USD}->loginid, payment_type => 'doughflow', amount => -21) }
        'can withdraw total cashier deposits of all siblings';

        BOM::Test::Helper::Client::top_up($clients{USD}, 'USD', -21);

        cmp_deeply(
            exception { $rule_engine->apply_rules($rule_name, loginid => $clients{USD}->loginid, payment_type => 'doughflow', amount => -0.01) },
            {
                error_code => 'PADepositsWithdrawalZero',
                rule       => $rule_name
            },
            'Fully blocked after withdrawing',
        );

        $rule_engine = BOM::Rules::Engine->new(client => $clients{BTC});

        cmp_deeply(
            exception {
                $rule_engine->apply_rules(
                    $rule_name,
                    loginid      => $clients{BTC}->loginid,
                    payment_type => 'crypto_cashier',
                    amount       => sprintf('%.6f', -0.01 / 5500))
            },
            {
                error_code => 'PADepositsWithdrawalZero',
                rule       => $rule_name
            },
            'Sibling blocked after withdrawing',
        );
    };

    my $p2p_wd_limit;
    $mock_client->mock(p2p_withdrawable_balance => sub { $p2p_wd_limit });

    subtest 'p2p only' => sub {
        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
            email       => 'p2p2@test.com',
        });

        BOM::User->create(
            email    => $client->email,
            password => 'x',
        )->add_client($client);

        $client->account('USD');
        BOM::Test::Helper::Client::top_up($client, 'USD', 10);

        my $rule_engine = BOM::Rules::Engine->new(client => $client);
        my %args        = (
            loginid      => $client->loginid,
            payment_type => 'doughflow',
            amount       => -10,
        );

        $p2p_wd_limit = 10;
        ok $rule_engine->apply_rules($rule_name, %args), 'Rule passes if limit is ok';

        $p2p_wd_limit = 0;
        cmp_deeply(
            exception { $rule_engine->apply_rules($rule_name, %args) },
            {
                error_code => 'P2PDepositsWithdrawalZero',
                rule       => $rule_name,
            },
            'Error for zero limit'
        );

        $p2p_wd_limit = 9;
        cmp_deeply(
            exception { $rule_engine->apply_rules($rule_name, %args) },
            {
                error_code => 'P2PDepositsWithdrawal',
                params     => [num(9), 'USD'],
                rule       => $rule_name,
            },
            'Error for insufficient limit'
        );

        $args{payment_type} = 'internal_transfer';

        cmp_deeply(
            exception { $rule_engine->apply_rules($rule_name, %args) },
            {
                error_code => 'P2PDepositsTransfer',
                params     => [num(9), 'USD'],
                rule       => $rule_name,
            },
            'Specific error code for internal_transfer, insufficient limit'
        );

        $p2p_wd_limit = 0;
        cmp_deeply(
            exception { $rule_engine->apply_rules($rule_name, %args) },
            {
                error_code => 'P2PDepositsTransferZero',
                rule       => $rule_name,
            },
            'Specific error code for internal_transfer, zero limit'
        );

        $client->payment_agent({status => 'applied'});
        cmp_deeply(
            exception { $rule_engine->apply_rules($rule_name, %args) },
            {
                error_code => 'P2PDepositsTransferZero',
                rule       => $rule_name,
            },
            'Error for applied PA'
        );

        $client->payment_agent({status => 'authorized'});
        ok $rule_engine->apply_rules($rule_name, %args), 'Rule passes for authorized PA ';
    };

    subtest 'pa + p2p deposits' => sub {
        my $user = BOM::User->create(
            email    => 'p2ppadeposits@test.com',
            password => 'x'
        );

        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR', binary_user_id => $user->id});
        $client->account('USD');

        my $pa = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
        $pa->account('USD');
        BOM::Test::Helper::Client::top_up($pa, 'USD', 1000);

        $pa->payment_agent({
            payment_agent_name    => '',
            email                 => '',
            information           => '',
            summary               => '',
            commission_deposit    => 0,
            commission_withdrawal => 0,
            currency_code         => 'USD',
        });
        $pa->save;

        $pa->payment_account_transfer(
            toClient           => $client,
            amount             => 101,
            to_amount          => 101,
            currency           => 'USD',
            fees               => 0,
            gateway_code       => 'payment_agent_transfer',
            is_agent_to_client => 1,
        );

        BOM::Test::Helper::Client::top_up($client, 'USD', 100);
        $p2p_wd_limit = 101;

        my $rule_engine = BOM::Rules::Engine->new(client => $client);

        my %args = (
            loginid      => $client->loginid,
            payment_type => 'doughflow',
            amount       => -201,
        );

        cmp_deeply(
            exception { $rule_engine->apply_rules($rule_name, %args) },
            {
                error_code => 'PAP2PDepositsWithdrawalZero',
                rule       => $rule_name,
            },
            'Error for zero limit'
        );

        $p2p_wd_limit = 102;

        cmp_deeply(
            exception { $rule_engine->apply_rules($rule_name, %args) },
            {
                error_code => 'PAP2PDepositsWithdrawalLimit',
                params     => [num(1), 'USD'],
                rule       => $rule_name,
            },
            'Error for partial limit'
        );

        cmp_deeply(exception { $rule_engine->apply_rules($rule_name, %args, amount => -1) }, undef, 'no error for amount=limit');

    };

};

# Subroutine to get the GBP equivalent of EUR
sub _GBP_equiv { sprintf '%.2f', convert_currency($_[0], 'EUR', 'GBP') }

done_testing();
