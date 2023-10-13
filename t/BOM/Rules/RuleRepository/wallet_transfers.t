use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::Deep;

use BOM::Rules::Engine;
use BOM::User;
use BOM::Config::Runtime;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis    qw(initialize_user_transfer_limits);
use BOM::Test::Helper::ExchangeRates           qw(populate_exchange_rates);

populate_exchange_rates({
    BTC => 20000,
});

my $app_config = BOM::Config::Runtime->instance->app_config;

my $user = BOM::User->create(
    email    => rand(999) . '@deriv.com',
    password => 'test',
);

my %args = (
    email                    => $user->email,
    salutation               => 'x',
    last_name                => 'x',
    first_name               => 'x',
    date_of_birth            => '1979-01-01',
    citizen                  => 'id',
    residence                => 'id',
    address_line_1           => 'x',
    address_line_2           => 'x',
    address_city             => 'x',
    address_state            => 'x',
    address_postcode         => 'x',
    phone                    => '',
    client_password          => '',
    secret_question          => '',
    non_pep_declaration_time => '2023-01-01',
);

my %clients;

$clients{vrtc} = $user->create_client(
    %args,
    broker_code  => 'VRTC',
    account_type => 'binary',
    currency     => 'USD'
);
$user->add_loginid('MTD001', 'mt5',     'demo', 'USD', undef, undef);
$user->add_loginid('DXD001', 'dxtrade', 'demo', 'USD', undef, undef);
$user->add_loginid('EZD001', 'derivez', 'demo', 'USD', undef, undef);
$user->add_loginid('CTD001', 'ctrader', 'demo', 'USD', undef, undef);

$clients{binary_usd} = $user->create_client(
    %args,
    broker_code  => 'CR',
    account_type => 'binary',
    currency     => 'USD'
);
$clients{binary_btc} = $user->create_client(
    %args,
    broker_code  => 'CR',
    account_type => 'binary',
    currency     => 'BTC'
);
$user->add_loginid('MTR001', 'mt5',     'real', 'USD', undef, undef);
$user->add_loginid('DXR001', 'dxtrade', 'real', 'USD', undef, undef);
$user->add_loginid('EZR001', 'derivez', 'real', 'USD', undef, undef);
$user->add_loginid('CTR001', 'derivez', 'real', 'USD', undef, undef);

$clients{vrw}->{wallet} = $user->create_wallet(
    %args,
    broker_code  => 'VRW',
    account_type => 'virtual',
    currency     => 'USD'
);
$clients{vrw}->{standard} = $user->create_client(
    %args,
    broker_code    => 'VRTC',
    wallet_loginid => $clients{vrw}->{wallet}->loginid,
    account_type   => 'standard',
    currency       => 'USD'
);
$user->add_loginid('MTD002', 'mt5',     'demo', 'USD', undef, $clients{vrw}->{wallet}->loginid);
$user->add_loginid('DXD002', 'dxtrade', 'demo', 'USD', undef, $clients{vrw}->{wallet}->loginid);
$user->add_loginid('EZD002', 'derivez', 'demo', 'USD', undef, $clients{vrw}->{wallet}->loginid);
$user->add_loginid('CTD002', 'ctrader', 'demo', 'USD', undef, $clients{vrw}->{wallet}->loginid);

$clients{doughflow_crw_usd}->{wallet} = $user->create_wallet(
    %args,
    broker_code  => 'CRW',
    account_type => 'doughflow',
    currency     => 'USD'
);
$clients{doughflow_crw_usd}->{standard} = $user->create_client(
    %args,
    broker_code    => 'CR',
    wallet_loginid => $clients{doughflow_crw_usd}->{wallet}->loginid,
    account_type   => 'standard',
    currency       => 'USD'
);
$user->add_loginid('MTR002', 'mt5',     'real', 'USD', undef, $clients{doughflow_crw_usd}->{wallet}->loginid);
$user->add_loginid('DXR002', 'dxtrade', 'real', 'USD', undef, $clients{doughflow_crw_usd}->{wallet}->loginid);
$user->add_loginid('EZR002', 'derivez', 'real', 'USD', undef, $clients{doughflow_crw_usd}->{wallet}->loginid);
$user->add_loginid('CTR002', 'ctrader', 'real', 'USD', undef, $clients{doughflow_crw_usd}->{wallet}->loginid);

$clients{doughflow_mfw_usd}->{wallet} = $user->create_wallet(
    %args,
    broker_code  => 'MFW',
    account_type => 'doughflow',
    currency     => 'USD'
);
$clients{doughflow_mfw_usd}->{standard} = $user->create_client(
    %args,
    broker_code    => 'MF',
    wallet_loginid => $clients{doughflow_mfw_usd}->{wallet}->loginid,
    account_type   => 'standard',
    currency       => 'USD'
);
$user->add_loginid('MTR003', 'mt5', 'real', 'USD', undef, $clients{doughflow_mfw_usd}->{wallet}->loginid);

$clients{crypto_btc}->{wallet} = $user->create_wallet(
    %args,
    broker_code  => 'CRW',
    account_type => 'crypto',
    currency     => 'BTC'
);
$clients{crypto_btc}->{standard} = $user->create_client(
    %args,
    broker_code    => 'CR',
    wallet_loginid => $clients{crypto_btc}->{wallet}->loginid,
    account_type   => 'standard',
    currency       => 'BTC'
);
$user->add_loginid('MTR004', 'mt5',     'real', 'USD', undef, $clients{crypto_btc}->{wallet}->loginid);
$user->add_loginid('DXR004', 'dxtrade', 'real', 'USD', undef, $clients{crypto_btc}->{wallet}->loginid);
$user->add_loginid('EZR004', 'derivez', 'real', 'USD', undef, $clients{crypto_btc}->{wallet}->loginid);
$user->add_loginid('CTR004', 'ctrader', 'real', 'USD', undef, $clients{crypto_btc}->{wallet}->loginid);

$clients{p2p_usd}->{wallet} = $user->create_wallet(
    %args,
    broker_code  => 'CRW',
    account_type => 'p2p',
    currency     => 'USD'
);
$clients{p2p_usd}->{standard} = $user->create_client(
    %args,
    broker_code    => 'CR',
    wallet_loginid => $clients{p2p_usd}->{wallet}->loginid,
    account_type   => 'standard',
    currency       => 'USD'
);
$user->add_loginid('MTR005', 'mt5',     'real', 'USD', undef, $clients{p2p_usd}->{wallet}->loginid);
$user->add_loginid('DXR005', 'dxtrade', 'real', 'USD', undef, $clients{p2p_usd}->{wallet}->loginid);
$user->add_loginid('EZR005', 'derivez', 'real', 'USD', undef, $clients{p2p_usd}->{wallet}->loginid);
$user->add_loginid('CTR005', 'ctrader', 'real', 'USD', undef, $clients{p2p_usd}->{wallet}->loginid);

$clients{paclient_usd}->{wallet} = $user->create_wallet(
    %args,
    broker_code  => 'CRW',
    account_type => 'paymentagent_client',
    currency     => 'USD'
);
$clients{paclient_usd}->{standard} = $user->create_client(
    %args,
    broker_code    => 'CR',
    wallet_loginid => $clients{paclient_usd}->{wallet}->loginid,
    account_type   => 'standard',
    currency       => 'USD'
);

$clients{pa_usd}->{wallet} = $user->create_wallet(
    %args,
    broker_code  => 'CRW',
    account_type => 'paymentagent',
    currency     => 'USD'
);
$clients{pa_usd}->{standard} = $user->create_client(
    %args,
    broker_code    => 'CR',
    wallet_loginid => $clients{pa_usd}->{wallet}->loginid,
    account_type   => 'standard',
    currency       => 'USD'
);

my @tests = ({
        name                                => 'VRTC to VRTC',
        same_account_not_allowed            => 'SameAccountNotAllowed',
        authorized_client_is_legacy_virtual => 'TransferBlockedClientIsVirtual',
        clients                             => $clients{vrtc},
        args                                => {
            loginid      => $clients{vrtc}->loginid,
            loginid_from => $clients{vrtc}->loginid,
            loginid_to   => $clients{vrtc}->loginid,
        },
    },
    {
        name                                => 'VRTC to MT5',
        authorized_client_is_legacy_virtual => 'TransferBlockedClientIsVirtual',
        clients                             => $clients{vrtc},
        args                                => {
            loginid      => $clients{vrtc}->loginid,
            loginid_from => $clients{vrtc}->loginid,
            loginid_to   => 'MTD001',
        },
    },
    {
        name                                => 'Demo MT5 to demo DerivX',
        authorized_client_is_legacy_virtual => 'TransferBlockedClientIsVirtual',
        between_trading_accounts            => 'TransferBlockedTradingAccounts',
        clients                             => $clients{vrtc},
        args                                => {
            loginid      => $clients{vrtc}->loginid,
            loginid_from => 'MTD001',
            loginid_to   => 'DXD001',
        },
    },
    {
        name                        => 'Binary to demo MT5',
        real_to_virtual_not_allowed => 'RealToVirtualNotAllowed',
        clients                     => $clients{binary_usd},
        args                        => {
            loginid      => $clients{binary_usd}->loginid,
            loginid_from => $clients{binary_usd}->loginid,
            loginid_to   => 'MTD001',
        },
    },
    {
        name    => 'Binary to binary',
        clients => [$clients{binary_usd}, $clients{binary_btc}],
        args    => {
            loginid      => $clients{binary_usd}->loginid,
            loginid_from => $clients{binary_usd}->loginid,
            loginid_to   => $clients{binary_btc}->loginid,
        },
    },
    {
        name              => 'Binary to wallet',
        legacy_and_wallet => 'TransferBlockedLegacy',
        wallet_links      => 'TransferBlockedWalletNotLinked',
        clients           => [$clients{binary_usd}, $clients{doughflow_crw_usd}->{wallet}],
        args              => {
            loginid      => $clients{binary_usd}->loginid,
            loginid_from => $clients{binary_usd}->loginid,
            loginid_to   => $clients{doughflow_crw_usd}->{wallet}->loginid,
        },
    },
    {
        name                  => 'Binary to standard',
        wallet_links          => 'TransferBlockedWalletNotLinked',
        legacy_and_non_legacy => 'TransferBlockedLegacy',
        clients               => [$clients{binary_usd}, $clients{doughflow_crw_usd}->{standard}],
        args                  => {
            loginid      => $clients{binary_usd}->loginid,
            loginid_from => $clients{binary_usd}->loginid,
            loginid_to   => $clients{doughflow_crw_usd}->{standard}->loginid,
        },
    },
    {
        name                     => 'Standard to ctrader',
        wallet_links             => 'TransferBlockedWalletNotLinked',
        between_trading_accounts => 'TransferBlockedTradingAccounts',
        clients                  => [$clients{binary_usd}, $clients{doughflow_crw_usd}->{standard}],
        args                     => {
            loginid      => $clients{doughflow_crw_usd}->{standard}->loginid,
            loginid_from => $clients{doughflow_crw_usd}->{standard}->loginid,
            loginid_to   => 'CTR001',
        },
    },
    {
        name    => 'Doughflow to crypto',
        clients => [$clients{doughflow_crw_usd}->{wallet}, $clients{crypto_btc}->{wallet}],
        args    => {
            loginid      => $clients{doughflow_crw_usd}->{wallet}->loginid,
            loginid_from => $clients{doughflow_crw_usd}->{wallet}->loginid,
            loginid_to   => $clients{crypto_btc}->{wallet}->loginid,
        },
    },
    {
        name    => 'Doughflow to P2P',
        clients => [$clients{doughflow_crw_usd}->{wallet}, $clients{p2p_usd}->{wallet}],
        args    => {
            loginid      => $clients{doughflow_crw_usd}->{wallet}->loginid,
            loginid_from => $clients{doughflow_crw_usd}->{wallet}->loginid,
            loginid_to   => $clients{p2p_usd}->{wallet}->loginid,
        },
    },
    {
        name                    => 'P2P to doughflow',
        account_type_capability => 'TransferBlockedWalletWithdrawal',
        clients                 => [$clients{doughflow_crw_usd}->{wallet}, $clients{p2p_usd}->{wallet}],
        args                    => {
            loginid      => $clients{doughflow_crw_usd}->{wallet}->loginid,
            loginid_from => $clients{p2p_usd}->{wallet}->loginid,
            loginid_to   => $clients{doughflow_crw_usd}->{wallet}->loginid,
        },
    },
    {
        name    => 'Doughlow to linked standard',
        clients => [$clients{doughflow_crw_usd}->{wallet}, $clients{doughflow_crw_usd}->{standard}],
        args    => {
            loginid      => $clients{doughflow_crw_usd}->{wallet}->loginid,
            loginid_from => $clients{doughflow_crw_usd}->{wallet}->loginid,
            loginid_to   => $clients{doughflow_crw_usd}->{standard}->loginid,
        },
    },
    {
        name    => 'Doughflow to linked DerivEZ',
        clients => $clients{doughflow_crw_usd}->{wallet},
        args    => {
            loginid      => $clients{doughflow_crw_usd}->{wallet}->loginid,
            loginid_from => $clients{doughflow_crw_usd}->{wallet}->loginid,
            loginid_to   => 'EZR002',
        },
    },
    {
        name    => 'Doughflow to linked ctrader',
        clients => $clients{doughflow_crw_usd}->{wallet},
        args    => {
            loginid      => $clients{doughflow_crw_usd}->{wallet}->loginid,
            loginid_from => $clients{doughflow_crw_usd}->{wallet}->loginid,
            loginid_to   => 'CTR002',
        },
    },
    {
        name         => 'CRW wallet to other linked DerivEZ',
        wallet_links => 'TransferBlockedWalletNotLinked',
        clients      => $clients{doughflow_crw_usd}->{wallet},
        args         => {
            loginid      => $clients{doughflow_crw_usd}->{wallet}->loginid,
            loginid_from => $clients{doughflow_crw_usd}->{wallet}->loginid,
            loginid_to   => 'EZR004',
        },
    },
    {
        name                     => 'Standard to standard',
        wallet_links             => 'TransferBlockedWalletNotLinked',
        between_trading_accounts => 'TransferBlockedTradingAccounts',
        clients                  => [$clients{doughflow_crw_usd}->{standard}, $clients{crypto_btc}->{standard}],
        args                     => {
            loginid      => $clients{doughflow_crw_usd}->{standard}->loginid,
            loginid_from => $clients{doughflow_crw_usd}->{standard}->loginid,
            loginid_to   => $clients{crypto_btc}->{standard}->loginid,
        },
    },
    {
        name                     => 'Standard to MT5',
        wallet_links             => 'TransferBlockedWalletNotLinked',
        between_trading_accounts => 'TransferBlockedTradingAccounts',
        clients                  => $clients{doughflow_crw_usd}->{standard},
        args                     => {
            loginid      => $clients{doughflow_crw_usd}->{standard}->loginid,
            loginid_from => $clients{doughflow_crw_usd}->{standard}->loginid,
            loginid_to   => 'MTR002',
        },
    },
    {
        name                     => 'DerivEZ to DerivX',
        wallet_links             => 'TransferBlockedWalletNotLinked',
        between_trading_accounts => 'TransferBlockedTradingAccounts',
        clients                  => $clients{crypto_btc}->{wallet},
        args                     => {
            loginid      => $clients{crypto_btc}->{wallet}->loginid,
            loginid_from => 'EZR004',
            loginid_to   => 'DXR004',
        },
    },
    {
        name    => 'P2P to linked standard',
        clients => [$clients{p2p_usd}->{wallet}, $clients{p2p_usd}->{standard}],
        args    => {
            loginid      => $clients{p2p_usd}->{wallet}->loginid,
            loginid_from => $clients{p2p_usd}->{wallet}->loginid,
            loginid_to   => $clients{p2p_usd}->{standard}->loginid,
        },
    },
    {
        name         => 'non-linked ctrader to P2P',
        clients      => $clients{p2p_usd}->{wallet},
        wallet_links => 'TransferBlockedWalletNotLinked',
        args         => {
            loginid      => $clients{p2p_usd}->{wallet}->loginid,
            loginid_from => 'CTR002',
            loginid_to   => $clients{p2p_usd}->{wallet}->loginid,
        },
    },
    {
        name                    => 'PA client to Doughflow',
        account_type_capability => 'TransferBlockedWalletWithdrawal',
        clients                 => [$clients{paclient_usd}->{wallet}, $clients{doughflow_crw_usd}->{wallet}],
        args                    => {
            loginid      => $clients{paclient_usd}->{wallet}->loginid,
            loginid_from => $clients{paclient_usd}->{wallet}->loginid,
            loginid_to   => $clients{doughflow_crw_usd}->{wallet}->loginid,
        },
    },
    {
        name                    => 'Doughflow to PA client',
        account_type_capability => 'TransferBlockedWalletDeposit',
        clients                 => [$clients{paclient_usd}->{wallet}, $clients{doughflow_crw_usd}->{wallet}],
        args                    => {
            loginid      => $clients{doughflow_crw_usd}->{wallet}->loginid,
            loginid_from => $clients{doughflow_crw_usd}->{wallet}->loginid,
            loginid_to   => $clients{paclient_usd}->{wallet}->loginid,
        },
    },
    {
        name    => 'Doughflow to PA',
        clients => [$clients{doughflow_crw_usd}->{wallet}, $clients{pa_usd}->{wallet}],
        args    => {
            loginid      => $clients{doughflow_crw_usd}->{wallet}->loginid,
            loginid_from => $clients{doughflow_crw_usd}->{wallet}->loginid,
            loginid_to   => $clients{pa_usd}->{wallet}->loginid,
        },
    },
    {
        name                    => 'PA to doughflow',
        account_type_capability => 'TransferBlockedWalletWithdrawal',
        clients                 => [$clients{doughflow_crw_usd}->{wallet}, $clients{pa_usd}->{wallet}],
        args                    => {
            loginid      => $clients{pa_usd}->{wallet}->loginid,
            loginid_from => $clients{pa_usd}->{wallet}->loginid,
            loginid_to   => $clients{doughflow_crw_usd}->{wallet}->loginid,
        },
    },
    {
        name    => 'PA to standard',
        clients => [$clients{pa_usd}->{wallet}, $clients{pa_usd}->{standard}],
        args    => {
            loginid      => $clients{pa_usd}->{wallet}->loginid,
            loginid_from => $clients{pa_usd}->{wallet}->loginid,
            loginid_to   => $clients{pa_usd}->{standard}->loginid,
        },
    },
    {
        name    => 'Standard to PA',
        clients => [$clients{pa_usd}->{wallet}, $clients{pa_usd}->{standard}],
        args    => {
            loginid      => $clients{pa_usd}->{wallet}->loginid,
            loginid_from => $clients{pa_usd}->{wallet}->loginid,
            loginid_to   => $clients{pa_usd}->{standard}->loginid,
        },
    },
);

for my $rule (
    qw(same_account_not_allowed real_to_virtual_not_allowed account_type_capability legacy_and_wallet between_trading_accounts wallet_links authorized_client_is_legacy_virtual)
    )
{
    my $rule_name = 'transfers.' . $rule;

    subtest $rule_name => sub {
        for my $test (@tests) {
            my $rule_engine = BOM::Rules::Engine->new(
                client => $test->{clients},
                user   => $user
            );
            my $res;
            my $err = exception { $res = $rule_engine->apply_rules($rule_name, $test->{args}->%*) };
            cmp_deeply(
                $err,
                {
                    error_code => $test->{$rule},
                    rule       => $rule_name
                },
                $test->{name} . ' got expected error'
            ) if $test->{$rule};
            ok($res && !$err, $test->{name} . ' passes') or diag explain $err unless $test->{$rule};
        }
    };
}

my $rule_name = 'transfers.daily_count_limit';
subtest $rule_name => sub {

    initialize_user_transfer_limits();
    $app_config->payments->transfer_between_accounts->limits->between_accounts(5);
    $app_config->payments->transfer_between_accounts->limits->dtrade(5);
    $app_config->payments->transfer_between_accounts->limits->MT5(5);
    $app_config->payments->transfer_between_accounts->limits->dxtrade(5);
    $app_config->payments->transfer_between_accounts->limits->derivez(5);

    subtest 'binary -> binary' => sub {
        $app_config->payments->transfer_between_accounts->daily_cumulative_limit->enable(0);
        my $rule_engine = BOM::Rules::Engine->new(
            client => [$clients{binary_usd}, $clients{binary_btc}],
            user   => $user
        );
        $user->daily_transfer_incr(
            client_from     => $clients{binary_usd},
            client_to       => $clients{binary_btc},
            amount          => 10,
            amount_currency => 'USD'
        ) for (1 .. 4);
        my %args = (
            loginid      => $clients{binary_usd}->loginid,
            loginid_from => $clients{binary_usd}->loginid,
            loginid_to   => $clients{binary_btc}->loginid,
        );
        my $res;
        my $err = exception { $res = $rule_engine->apply_rules($rule_name, %args) };
        ok($res && !$err, 'pass when count is under limit') or diag explain $err;

        $user->daily_transfer_incr(
            client_from     => $clients{binary_usd},
            client_to       => $clients{binary_btc},
            amount          => 10,
            amount_currency => 'USD'
        );
        $err = exception { $rule_engine->apply_rules($rule_name, %args) };
        cmp_deeply(
            $err,
            {
                error_code => 'MaximumTransfers',
                rule       => $rule_name,
                params     => [5]
            },
            'fail when limit reached'
        );

        $app_config->payments->transfer_between_accounts->daily_cumulative_limit->enable(1);
        $app_config->payments->transfer_between_accounts->daily_cumulative_limit->between_accounts(0);
        $err = exception { $rule_engine->apply_rules($rule_name, %args) };
        cmp_deeply(
            $err,
            {
                error_code => 'MaximumTransfers',
                rule       => $rule_name,
                params     => [5]
            },
            'fails when cumulative limit enabled but limit is zero'
        );

        $app_config->payments->transfer_between_accounts->daily_cumulative_limit->between_accounts(100);
        $err = exception { $rule_engine->apply_rules($rule_name, %args) };
        ok($res && !$err, 'pass when cumulative limit is enabled and more than zero') or diag explain $err;

        $app_config->payments->transfer_between_accounts->daily_cumulative_limit->enable(0);
    };

    subtest 'wallet -> standard' => sub {
        my $rule_engine = BOM::Rules::Engine->new(
            client => [$clients{doughflow_crw_usd}->{wallet}, $clients{doughflow_crw_usd}->{standard}],
            user   => $user
        );
        $user->daily_transfer_incr(
            client_from     => $clients{doughflow_crw_usd}->{wallet},
            client_to       => $clients{doughflow_crw_usd}->{standard},
            amount          => 10,
            amount_currency => 'USD'
        ) for (1 .. 4);
        my %args = (
            loginid      => $clients{doughflow_crw_usd}->{wallet}->loginid,
            loginid_from => $clients{doughflow_crw_usd}->{wallet}->loginid,
            loginid_to   => $clients{doughflow_crw_usd}->{standard}->loginid,
        );
        my $res;
        my $err = exception { $res = $rule_engine->apply_rules($rule_name, %args) };
        ok($res && !$err, 'pass when count is under limit') or diag explain $err;

        $user->daily_transfer_incr(
            client_from     => $clients{doughflow_crw_usd}->{wallet},
            client_to       => $clients{doughflow_crw_usd}->{standard},
            amount          => 10,
            amount_currency => 'USD'
        );
        $err = exception { $rule_engine->apply_rules($rule_name, %args) };
        cmp_deeply(
            $err,
            {
                error_code => 'MaximumTransfers',
                rule       => $rule_name,
                params     => [5]
            },
            'fail when limit reached'
        );

        $args{loginid_from} = $clients{doughflow_crw_usd}->{standard}->loginid;
        $args{loginid_to}   = $clients{doughflow_crw_usd}->{wallet}->loginid;

        $err = exception { $rule_engine->apply_rules($rule_name, %args) };
        cmp_deeply(
            $err,
            {
                error_code => 'MaximumTransfers',
                rule       => $rule_name,
                params     => [5]
            },
            'fails in opposite direction'
        );
    };

    subtest 'binary -> mt5' => sub {
        my $rule_engine = BOM::Rules::Engine->new(
            client => $clients{binary_usd},
            user   => $user
        );
        $user->daily_transfer_incr(
            client_from     => $clients{binary_usd},
            loginid_to      => 'MTR001',
            amount          => 10,
            amount_currency => 'USD'
        ) for (1 .. 4);
        my %args = (
            loginid      => $clients{binary_usd}->loginid,
            loginid_from => $clients{binary_usd}->loginid,
            loginid_to   => 'MTR001',
        );
        my $res;
        my $err = exception { $res = $rule_engine->apply_rules($rule_name, %args) };
        ok($res && !$err, 'pass when count is under limit') or diag explain $err;

        $user->daily_transfer_incr(
            client_from     => $clients{binary_usd},
            loginid_to      => 'MTR001',
            amount          => 10,
            amount_currency => 'USD'
        );
        $err = exception { $rule_engine->apply_rules($rule_name, %args) };
        cmp_deeply(
            $err,
            {
                error_code => 'MaximumTransfers',
                rule       => $rule_name,
                params     => [5]
            },
            'fail when limit reached'
        );

        $args{loginid_from} = 'MTR001';
        $args{loginid_to}   = $clients{binary_usd}->loginid;

        $err = exception { $rule_engine->apply_rules($rule_name, %args) };
        cmp_deeply(
            $err,
            {
                error_code => 'MaximumTransfers',
                rule       => $rule_name,
                params     => [5]
            },
            'fails in opposite direction'
        );
    };

    subtest 'wallet -> mt5' => sub {
        my $rule_engine = BOM::Rules::Engine->new(
            client => [$clients{doughflow_crw_usd}->{wallet}],
            user   => $user
        );
        $user->daily_transfer_incr(
            client_from     => $clients{doughflow_crw_usd}->{wallet},
            loginid_to      => 'MTR002',
            amount          => 10,
            amount_currency => 'USD'
        ) for (1 .. 4);
        my %args = (
            loginid      => $clients{doughflow_crw_usd}->{wallet}->loginid,
            loginid_from => $clients{doughflow_crw_usd}->{wallet}->loginid,
            loginid_to   => 'MTR002',
        );
        my $res;
        my $err = exception { $res = $rule_engine->apply_rules($rule_name, %args) };
        ok($res && !$err, 'pass when count is under limit') or diag explain $err;

        $user->daily_transfer_incr(
            client_from     => $clients{doughflow_crw_usd}->{wallet},
            loginid_to      => 'MTR002',
            amount          => 10,
            amount_currency => 'USD'
        );
        $err = exception { $rule_engine->apply_rules($rule_name, %args) };
        cmp_deeply(
            $err,
            {
                error_code => 'MaximumTransfers',
                rule       => $rule_name,
                params     => [5]
            },
            'fail when limit reached'
        );

        $args{loginid_from} = 'MTR002';
        $args{loginid_to}   = $clients{doughflow_crw_usd}->{wallet}->loginid;

        $err = exception { $rule_engine->apply_rules($rule_name, %args) };
        cmp_deeply(
            $err,
            {
                error_code => 'MaximumTransfers',
                rule       => $rule_name,
                params     => [5]
            },
            'fails in opposite direction'
        );
    };

    subtest 'binary -> dxtrade' => sub {
        my $rule_engine = BOM::Rules::Engine->new(
            client => $clients{binary_usd},
            user   => $user
        );
        $user->daily_transfer_incr(
            client_from     => $clients{binary_usd},
            loginid_to      => 'DXR001',
            amount          => 10,
            amount_currency => 'USD'
        ) for (1 .. 4);
        my %args = (
            loginid      => $clients{binary_usd}->loginid,
            loginid_from => $clients{binary_usd}->loginid,
            loginid_to   => 'DXR001',
        );
        my $res;
        my $err = exception { $res = $rule_engine->apply_rules($rule_name, %args) };
        ok($res && !$err, 'pass when count is under limit') or diag explain $err;

        $user->daily_transfer_incr(
            client_from     => $clients{binary_usd},
            loginid_to      => 'DXR001',
            amount          => 10,
            amount_currency => 'USD'
        );
        $err = exception { $rule_engine->apply_rules($rule_name, %args) };
        cmp_deeply(
            $err,
            {
                error_code => 'MaximumTransfers',
                rule       => $rule_name,
                params     => [5]
            },
            'fail when limit reached'
        );

        $args{loginid_from} = 'DXR001';
        $args{loginid_to}   = $clients{binary_usd}->loginid;

        $err = exception { $rule_engine->apply_rules($rule_name, %args) };
        cmp_deeply(
            $err,
            {
                error_code => 'MaximumTransfers',
                rule       => $rule_name,
                params     => [5]
            },
            'fails in opposite direction'
        );
    };

    subtest 'wallet -> dxtrade' => sub {
        my $rule_engine = BOM::Rules::Engine->new(
            client => [$clients{doughflow_crw_usd}->{wallet}],
            user   => $user
        );
        $user->daily_transfer_incr(
            client_from     => $clients{doughflow_crw_usd}->{wallet},
            loginid_to      => 'DXR002',
            amount          => 10,
            amount_currency => 'USD'
        ) for (1 .. 4);
        my %args = (
            loginid      => $clients{doughflow_crw_usd}->{wallet}->loginid,
            loginid_from => $clients{doughflow_crw_usd}->{wallet}->loginid,
            loginid_to   => 'DXR002',
        );
        my $res;
        my $err = exception { $res = $rule_engine->apply_rules($rule_name, %args) };
        ok($res && !$err, 'pass when count is under limit') or diag explain $err;

        $user->daily_transfer_incr(
            client_from     => $clients{doughflow_crw_usd}->{wallet},
            loginid_to      => 'DXR002',
            amount          => 10,
            amount_currency => 'USD'
        );
        $err = exception { $rule_engine->apply_rules($rule_name, %args) };
        cmp_deeply(
            $err,
            {
                error_code => 'MaximumTransfers',
                rule       => $rule_name,
                params     => [5]
            },
            'fail when limit reached'
        );

        $args{loginid_from} = 'DXR002', $args{loginid_to} = $clients{doughflow_crw_usd}->{wallet}->loginid;

        $err = exception { $rule_engine->apply_rules($rule_name, %args) };
        cmp_deeply(
            $err,
            {
                error_code => 'MaximumTransfers',
                rule       => $rule_name,
                params     => [5]
            },
            'fails in opposite direction'
        );
    };

    subtest 'binary -> derivez' => sub {
        my $rule_engine = BOM::Rules::Engine->new(
            client => $clients{binary_usd},
            user   => $user
        );
        $user->daily_transfer_incr(
            client_from     => $clients{binary_usd},
            loginid_to      => 'EZR001',
            amount          => 10,
            amount_currency => 'USD'
        ) for (1 .. 4);
        my %args = (
            loginid      => $clients{binary_usd}->loginid,
            loginid_from => $clients{binary_usd}->loginid,
            loginid_to   => 'EZR001',
        );
        my $res;
        my $err = exception { $res = $rule_engine->apply_rules($rule_name, %args) };
        ok($res && !$err, 'pass when count is under limit') or diag explain $err;

        $user->daily_transfer_incr(
            client_from     => $clients{binary_usd},
            loginid_to      => 'EZR001',
            amount          => 10,
            amount_currency => 'USD'
        );
        $err = exception { $rule_engine->apply_rules($rule_name, %args) };
        cmp_deeply(
            $err,
            {
                error_code => 'MaximumTransfers',
                rule       => $rule_name,
                params     => [5]
            },
            'fail when limit reached'
        );

        $args{loginid_from} = 'EZR001';
        $args{loginid_to}   = $clients{binary_usd}->loginid;

        $err = exception { $rule_engine->apply_rules($rule_name, %args) };
        cmp_deeply(
            $err,
            {
                error_code => 'MaximumTransfers',
                rule       => $rule_name,
                params     => [5]
            },
            'fails in opposite direction'
        );
    };

    subtest 'wallet -> derivez' => sub {
        my $rule_engine = BOM::Rules::Engine->new(
            client => [$clients{doughflow_crw_usd}->{wallet}],
            user   => $user
        );
        $user->daily_transfer_incr(
            client_from     => $clients{doughflow_crw_usd}->{wallet},
            loginid_to      => 'EZR002',
            amount          => 10,
            amount_currency => 'USD'
        ) for (1 .. 4);
        my %args = (
            loginid      => $clients{doughflow_crw_usd}->{wallet}->loginid,
            loginid_from => $clients{doughflow_crw_usd}->{wallet}->loginid,
            loginid_to   => 'EZR002',
        );
        my $res;
        my $err = exception { $res = $rule_engine->apply_rules($rule_name, %args) };
        ok($res && !$err, 'pass when count is under limit') or diag explain $err;

        $user->daily_transfer_incr(
            client_from     => $clients{doughflow_crw_usd}->{wallet},
            loginid_to      => 'EZR002',
            amount          => 10,
            amount_currency => 'USD'
        );
        $err = exception { $rule_engine->apply_rules($rule_name, %args) };
        cmp_deeply(
            $err,
            {
                error_code => 'MaximumTransfers',
                rule       => $rule_name,
                params     => [5]
            },
            'fail when limit reached'
        );

        $args{loginid_from} = 'EZR002';
        $args{loginid_to}   = $clients{doughflow_crw_usd}->{wallet}->loginid;

        $err = exception { $rule_engine->apply_rules($rule_name, %args) };
        cmp_deeply(
            $err,
            {
                error_code => 'MaximumTransfers',
                rule       => $rule_name,
                params     => [5]
            },
            'fails in opposite direction'
        );
    };
};

$rule_name = 'transfers.daily_total_amount_limit';
subtest $rule_name => sub {

    initialize_user_transfer_limits();
    $app_config->payments->transfer_between_accounts->daily_cumulative_limit->enable(1);
    $app_config->payments->transfer_between_accounts->daily_cumulative_limit->between_accounts(50);
    $app_config->payments->transfer_between_accounts->daily_cumulative_limit->dtrade(50);
    $app_config->payments->transfer_between_accounts->daily_cumulative_limit->MT5(50);
    $app_config->payments->transfer_between_accounts->daily_cumulative_limit->dxtrade(50);
    $app_config->payments->transfer_between_accounts->daily_cumulative_limit->derivez(50);

    subtest 'binary USD' => sub {
        my $rule_engine = BOM::Rules::Engine->new(
            client => [$clients{binary_usd}, $clients{binary_btc}],
            user   => $user
        );
        $user->daily_transfer_incr(
            client_from     => $clients{binary_usd},
            client_to       => $clients{binary_btc},
            amount          => 10,
            amount_currency => 'USD'
        ) for (1 .. 4);
        my %args = (
            loginid         => $clients{binary_btc}->loginid,
            loginid_from    => $clients{binary_btc}->loginid,
            loginid_to      => $clients{binary_usd}->loginid,
            amount_currency => 'USD',
            amount          => 10,
        );
        my $res;
        my $err = exception { $res = $rule_engine->apply_rules($rule_name, %args) };
        ok($res && !$err, 'pass when amount is within limit') or diag explain $err;

        $user->daily_transfer_incr(
            client_from     => $clients{binary_usd},
            client_to       => $clients{binary_btc},
            amount          => 10,
            amount_currency => 'USD'
        );
        $err = exception { $rule_engine->apply_rules($rule_name, %args) };
        cmp_deeply(
            $err,
            {
                error_code => 'MaximumAmountTransfers',
                rule       => $rule_name,
                params     => ['50.00', 'USD']
            },
            'fail when amount is over limit'
        );

        $app_config->payments->transfer_between_accounts->daily_cumulative_limit->between_accounts(0);

        $err = exception { $res = $rule_engine->apply_rules($rule_name, %args) };
        ok($res && !$err, 'pass when limit is zero') or diag explain $err;

        $app_config->payments->transfer_between_accounts->daily_cumulative_limit->between_accounts(50);
    };

    subtest 'binary BTC' => sub {
        initialize_user_transfer_limits();
        my $rule_engine = BOM::Rules::Engine->new(
            client => [$clients{binary_usd}, $clients{binary_btc}],
            user   => $user
        );
        $user->daily_transfer_incr(
            client_from     => $clients{binary_usd},
            client_to       => $clients{binary_btc},
            amount          => 0.0005,
            amount_currency => 'BTC'
        ) for (1 .. 4);
        my %args = (
            loginid         => $clients{binary_usd}->loginid,
            loginid_from    => $clients{binary_usd}->loginid,
            loginid_to      => $clients{binary_btc}->loginid,
            amount_currency => 'BTC',
            amount          => 0.0005,                          # 10/20000,
        );
        my $res;
        my $err = exception { $res = $rule_engine->apply_rules($rule_name, %args) };
        ok($res && !$err, 'pass when amount is within limit') or diag explain $err;

        $user->daily_transfer_incr(
            client_from     => $clients{binary_usd},
            client_to       => $clients{binary_btc},
            amount          => 0.0005,
            amount_currency => 'BTC'
        );
        $err = exception { $rule_engine->apply_rules($rule_name, %args) };

        cmp_deeply(
            $err,
            {
                error_code => 'MaximumAmountTransfers',
                rule       => $rule_name,
                params     => ['0.00250000', 'BTC']
            },
            'fail when amount is over limit'
        );
    };

    subtest 'binary -> mt5' => sub {
        my $rule_engine = BOM::Rules::Engine->new(
            client => $clients{binary_usd},
            user   => $user
        );
        $user->daily_transfer_incr(
            client_from     => $clients{binary_usd},
            loginid_to      => 'MTR001',
            amount          => 10,
            amount_currency => 'USD'
        ) for (1 .. 4);
        my %args = (
            loginid         => $clients{binary_usd}->loginid,
            loginid_from    => $clients{binary_usd}->loginid,
            loginid_to      => 'MTR001',
            amount_currency => 'USD',
            amount          => 10,
        );
        my $res;
        my $err = exception { $res = $rule_engine->apply_rules($rule_name, %args) };
        ok($res && !$err, 'pass when amount is within limit') or diag explain $err;

        $user->daily_transfer_incr(
            client_from     => $clients{binary_usd},
            loginid_to      => 'MTR001',
            amount          => 10,
            amount_currency => 'USD'
        );
        $err = exception { $rule_engine->apply_rules($rule_name, %args) };
        cmp_deeply(
            $err,
            {
                error_code => 'MaximumAmountTransfers',
                rule       => $rule_name,
                params     => ['50.00', 'USD']
            },
            'fail when amount is over limit'
        );

        $args{loginid_from} = 'MTR001';
        $args{loginid_to}   = $clients{binary_usd}->loginid;

        $err = exception { $rule_engine->apply_rules($rule_name, %args) };
        cmp_deeply(
            $err,
            {
                error_code => 'MaximumAmountTransfers',
                rule       => $rule_name,
                params     => ['50.00', 'USD']
            },
            'fails in opposite direction'
        );
    };

    subtest 'wallet -> mt5' => sub {
        my $rule_engine = BOM::Rules::Engine->new(
            client => [$clients{doughflow_crw_usd}->{wallet}],
            user   => $user
        );
        $user->daily_transfer_incr(
            client_from     => $clients{doughflow_crw_usd}->{wallet},
            loginid_to      => 'MTR002',
            amount          => 10,
            amount_currency => 'USD'
        ) for (1 .. 4);
        my %args = (
            loginid         => $clients{doughflow_crw_usd}->{wallet}->loginid,
            loginid_from    => $clients{doughflow_crw_usd}->{wallet}->loginid,
            loginid_to      => 'MTR002',
            amount_currency => 'USD',
            amount          => 10,
        );
        my $res;
        my $err = exception { $res = $rule_engine->apply_rules($rule_name, %args) };
        ok($res && !$err, 'pass when amount is within limit') or diag explain $err;

        $user->daily_transfer_incr(
            client_from     => $clients{doughflow_crw_usd}->{wallet},
            loginid_to      => 'MTR002',
            amount          => 10,
            amount_currency => 'USD'
        );
        $err = exception { $rule_engine->apply_rules($rule_name, %args) };
        cmp_deeply(
            $err,
            {
                error_code => 'MaximumAmountTransfers',
                rule       => $rule_name,
                params     => ['50.00', 'USD']
            },
            'fail when amount is over limit'
        );

        $args{loginid_from} = 'MTR002';
        $args{loginid_to}   = $clients{doughflow_crw_usd}->{wallet}->loginid;

        $err = exception { $rule_engine->apply_rules($rule_name, %args) };
        cmp_deeply(
            $err,
            {
                error_code => 'MaximumAmountTransfers',
                rule       => $rule_name,
                params     => ['50.00', 'USD']
            },
            'fails in opposite direction'
        );
    };

    subtest 'binary -> dxtrade' => sub {
        my $rule_engine = BOM::Rules::Engine->new(
            client => $clients{binary_usd},
            user   => $user
        );
        $user->daily_transfer_incr(
            client_from     => $clients{doughflow_crw_usd}->{wallet},
            loginid_to      => 'DXR001',
            amount          => 10,
            amount_currency => 'USD'
        ) for (1 .. 4);
        my %args = (
            loginid         => $clients{binary_usd}->loginid,
            loginid_from    => $clients{binary_usd}->loginid,
            loginid_to      => 'DXR001',
            amount_currency => 'USD',
            amount          => 10,
        );
        my $res;
        my $err = exception { $res = $rule_engine->apply_rules($rule_name, %args) };
        ok($res && !$err, 'pass when amount is within limit') or diag explain $err;

        $user->daily_transfer_incr(
            client_from     => $clients{doughflow_crw_usd}->{wallet},
            loginid_to      => 'DXR001',
            amount          => 10,
            amount_currency => 'USD'
        );
        $err = exception { $rule_engine->apply_rules($rule_name, %args) };
        cmp_deeply(
            $err,
            {
                error_code => 'MaximumAmountTransfers',
                rule       => $rule_name,
                params     => ['50.00', 'USD']
            },
            'fail when amount is over limit'
        );

        $args{loginid_from} = 'DXR001';
        $args{loginid_to}   = $clients{binary_usd}->loginid;

        $err = exception { $rule_engine->apply_rules($rule_name, %args) };
        cmp_deeply(
            $err,
            {
                error_code => 'MaximumAmountTransfers',
                rule       => $rule_name,
                params     => ['50.00', 'USD']
            },
            'fails in opposite direction'
        );
    };

    subtest 'wallet -> dxtrade' => sub {
        my $rule_engine = BOM::Rules::Engine->new(
            client => [$clients{doughflow_crw_usd}->{wallet}],
            user   => $user
        );
        $user->daily_transfer_incr(
            client_from     => $clients{doughflow_crw_usd}->{wallet},
            loginid_to      => 'DXR002',
            amount          => 10,
            amount_currency => 'USD'
        ) for (1 .. 4);
        my %args = (
            loginid         => $clients{doughflow_crw_usd}->{wallet}->loginid,
            loginid_from    => $clients{doughflow_crw_usd}->{wallet}->loginid,
            loginid_to      => 'DXR002',
            amount_currency => 'USD',
            amount          => 10,
        );
        my $res;
        my $err = exception { $res = $rule_engine->apply_rules($rule_name, %args) };
        ok($res && !$err, 'pass when amount is within limit') or diag explain $err;

        $user->daily_transfer_incr(
            client_from     => $clients{doughflow_crw_usd}->{wallet},
            loginid_to      => 'DXR002',
            amount          => 10,
            amount_currency => 'USD'
        );
        $err = exception { $rule_engine->apply_rules($rule_name, %args) };
        cmp_deeply(
            $err,
            {
                error_code => 'MaximumAmountTransfers',
                rule       => $rule_name,
                params     => ['50.00', 'USD']
            },
            'fail when amount is over limit'
        );

        $args{loginid_from} = 'DXR002';
        $args{loginid_to}   = $clients{doughflow_crw_usd}->{wallet}->loginid;

        $err = exception { $rule_engine->apply_rules($rule_name, %args) };
        cmp_deeply(
            $err,
            {
                error_code => 'MaximumAmountTransfers',
                rule       => $rule_name,
                params     => ['50.00', 'USD']
            },
            'fails in opposite direction'
        );
    };

    subtest 'binary -> derivez' => sub {
        my $rule_engine = BOM::Rules::Engine->new(
            client => $clients{binary_usd},
            user   => $user
        );
        $user->daily_transfer_incr(
            client_from     => $clients{doughflow_crw_usd}->{wallet},
            loginid_to      => 'EZR001',
            amount          => 10,
            amount_currency => 'USD'
        ) for (1 .. 4);
        my %args = (
            loginid         => $clients{binary_usd}->loginid,
            loginid_from    => $clients{binary_usd}->loginid,
            loginid_to      => 'EZR001',
            amount_currency => 'USD',
            amount          => 10,
        );
        my $res;
        my $err = exception { $res = $rule_engine->apply_rules($rule_name, %args) };
        ok($res && !$err, 'pass when amount is within limit') or diag explain $err;

        $user->daily_transfer_incr(
            client_from     => $clients{doughflow_crw_usd}->{wallet},
            loginid_to      => 'EZR001',
            amount          => 10,
            amount_currency => 'USD'
        );
        $err = exception { $rule_engine->apply_rules($rule_name, %args) };
        cmp_deeply(
            $err,
            {
                error_code => 'MaximumAmountTransfers',
                rule       => $rule_name,
                params     => ['50.00', 'USD']
            },
            'fail when amount is over limit'
        );

        $args{loginid_from} = 'EZR001';
        $args{loginid_to}   = $clients{binary_usd}->loginid;

        $err = exception { $rule_engine->apply_rules($rule_name, %args) };
        cmp_deeply(
            $err,
            {
                error_code => 'MaximumAmountTransfers',
                rule       => $rule_name,
                params     => ['50.00', 'USD']
            },
            'fails in opposite direction'
        );
    };

    subtest 'wallet -> derivez' => sub {
        my $rule_engine = BOM::Rules::Engine->new(
            client => [$clients{doughflow_crw_usd}->{wallet}],
            user   => $user
        );
        $user->daily_transfer_incr(
            client_from     => $clients{doughflow_crw_usd}->{wallet},
            loginid_to      => 'EZR002',
            amount          => 10,
            amount_currency => 'USD'
        ) for (1 .. 4);
        my %args = (
            loginid         => $clients{doughflow_crw_usd}->{wallet}->loginid,
            loginid_from    => $clients{doughflow_crw_usd}->{wallet}->loginid,
            loginid_to      => 'EZR002',
            amount_currency => 'USD',
            amount          => 10,
        );
        my $res;
        my $err = exception { $res = $rule_engine->apply_rules($rule_name, %args) };
        ok($res && !$err, 'pass when amount is within limit') or diag explain $err;

        $user->daily_transfer_incr(
            client_from     => $clients{doughflow_crw_usd}->{wallet},
            loginid_to      => 'EZR002',
            amount          => 10,
            amount_currency => 'USD'
        );
        $err = exception { $rule_engine->apply_rules($rule_name, %args) };
        cmp_deeply(
            $err,
            {
                error_code => 'MaximumAmountTransfers',
                rule       => $rule_name,
                params     => ['50.00', 'USD']
            },
            'fail when amount is over limit'
        );

        $args{loginid_from} = 'EZR002';
        $args{loginid_to}   = $clients{doughflow_crw_usd}->{wallet}->loginid;

        $err = exception { $rule_engine->apply_rules($rule_name, %args) };
        cmp_deeply(
            $err,
            {
                error_code => 'MaximumAmountTransfers',
                rule       => $rule_name,
                params     => ['50.00', 'USD']
            },
            'fails in opposite direction'
        );
    };
};

done_testing();
