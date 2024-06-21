use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::Deep;
use Test::MockModule;

use BOM::User;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::RPC::QueueClient;
use BOM::Test::Helper::Client;
use BOM::Test::Helper::MT5;
use BOM::Test::Helper::CTrader;
use BOM::Test::Helper::ExchangeRates;
use BOM::Platform::Token::API;
use BOM::MT5::User::Async;
use BOM::Test::Script::DevExperts;
use BOM::Config::Runtime;

my $c         = BOM::Test::RPC::QueueClient->new();
my $token_api = BOM::Platform::Token::API->new();

my $app_config = BOM::Config::Runtime->instance->app_config;
$app_config->system->dxtrade->suspend->all(0);
$app_config->system->dxtrade->suspend->demo(0);
$app_config->system->dxtrade->suspend->real(0);
$app_config->system->dxtrade->token_authentication->demo(1);
$app_config->system->dxtrade->token_authentication->real(1);
$app_config->system->mt5->http_proxy->demo->p01_ts04(1);
$app_config->system->mt5->http_proxy->real->p02_ts01(1);

BOM::Test::Helper::MT5::mock_server();
BOM::Test::Helper::CTrader::mock_server();

BOM::Test::Helper::ExchangeRates::populate_exchange_rates({BTC => 25000});
my $mock_currency_converter = Test::MockModule->new('ExchangeRates::CurrencyConverter');
$mock_currency_converter->redefine(offer_to_clients => 1);
my $mock_fees = Test::MockModule->new('BOM::Config::CurrencyConfig');
$mock_fees->redefine(
    transfer_between_accounts_fees => {
        USD => {BTC => 5},
        BTC => {USD => 5}});
my $user = BOM::User->create(
    email    => rand(999) . '@deriv.com',
    password => 'x',
);

my $legacy_user = BOM::User->create(
    email    => rand(999) . '@deriv.com',
    password => 'x',
);

my $trading_password = 'Abcd1234@';
$user->update_trading_password($trading_password);
$legacy_user->update_trading_password($trading_password);

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
    phone                    => '123',
    client_password          => '',
    secret_question          => '',
    account_opening_reason   => 'Speculative',
    non_pep_declaration_time => '2023-01-01',
    fatca_declaration_time   => '2023-01-01',
    fatca_declaration        => 1,
);

my (%accs, @tests);
$accs{vrtc_binary} = $legacy_user->create_client(
    %args,
    broker_code  => 'VRTC',
    account_type => 'binary',
    currency     => 'USD'
);
$accs{cr_usd} = $legacy_user->create_client(
    %args,
    broker_code  => 'CR',
    account_type => 'binary',
    currency     => 'USD'
);
$accs{cr_btc} = $legacy_user->create_client(
    %args,
    broker_code  => 'CR',
    account_type => 'binary',
    currency     => 'BTC'
);
$accs{vrw} = $user->create_wallet(
    %args,
    broker_code  => 'VRW',
    account_type => 'virtual',
    currency     => 'USD'
);
$accs{vrtc_trading} = $user->create_client(
    %args,
    broker_code    => 'VRTC',
    account_type   => 'standard',
    currency       => 'USD',
    wallet_loginid => $accs{vrw}->loginid
);
$accs{crw_df} = $user->create_wallet(
    %args,
    broker_code  => 'CRW',
    account_type => 'doughflow',
    currency     => 'USD'
);
$accs{crw_btc} = $user->create_wallet(
    %args,
    broker_code  => 'CRW',
    account_type => 'crypto',
    currency     => 'BTC'
);
$accs{crw_p2p} = $user->create_wallet(
    %args,
    broker_code  => 'CRW',
    account_type => 'p2p',
    currency     => 'USD'
);
$accs{crw_pa} = $user->create_wallet(
    %args,
    broker_code  => 'CRW',
    account_type => 'paymentagent',
    currency     => 'USD'
);
$accs{crw_pa_client} = $user->create_wallet(
    %args,
    broker_code  => 'CRW',
    account_type => 'paymentagent_client',
    currency     => 'USD'
);

my %tokens = map { $_ => $token_api->create_token($accs{$_}->loginid, 'test', ['admin']) } keys %accs;
BOM::Test::Helper::Client::top_up($accs{$_}, 'USD', 1000) for qw(vrtc_binary cr_usd vrw crw_df crw_pa_client);

my %loginids = map { $_ => $accs{$_}->loginid } keys %accs;

my $params = {
    language => 'EN',
    token    => $tokens{vrtc_binary},
    args     => {
        account_type => 'demo',
        mainPassword => $trading_password,
    },
};
$loginids{mt5_demo_legacy} = $c->call_ok('mt5_new_account', $params)->result->{login};

$params->{args} = {
    account_type => 'demo',
    password     => $trading_password,
    market_type  => 'all',
    currency     => 'USD',
    platform     => 'dxtrade',
};
$loginids{dx_demo_legacy} = $c->call_ok('trading_platform_new_account', $params)->result->{account_id};

$params->{args} = {
    account_type => 'demo',
    market_type  => 'all',
    currency     => 'USD',
    platform     => 'ctrader',
};
$loginids{ct_demo_legacy} = $c->call_ok('trading_platform_new_account', $params)->result->{account_id};

$params = {
    language => 'EN',
    token    => $tokens{cr_usd},
    args     => {
        account_type => 'gaming',
        mainPassword => $trading_password,
    },
};
$loginids{mt5_gaming_legacy} = $c->call_ok('mt5_new_account', $params)->result->{login};

$params->{args} = {
    account_type     => 'financial',
    mt5_account_type => 'financial',
    mainPassword     => $trading_password,
};
$loginids{mt5_financial_legacy} = $c->call_ok('mt5_new_account', $params)->result->{login};

$params->{args} = {
    account_type => 'real',
    password     => $trading_password,
    market_type  => 'all',
    currency     => 'USD',
    platform     => 'dxtrade',
};
$loginids{dx_real_legacy} = $c->call_ok('trading_platform_new_account', $params)->result->{account_id};

$params->{args} = {
    account_type => 'real',
    market_type  => 'all',
    currency     => 'USD',
    platform     => 'ctrader',
};
$loginids{ct_real_legacy} = $c->call_ok('trading_platform_new_account', $params)->result->{account_id};

$params = {
    language => 'EN',
    token    => $tokens{vrw},
    args     => {
        account_type => 'demo',
        mainPassword => $trading_password,
    },
};
$loginids{mt5_demo} = $c->call_ok('mt5_new_account', $params)->result->{login};

$params->{args} = {
    account_type => 'demo',
    password     => $trading_password,
    market_type  => 'all',
    currency     => 'USD',
    platform     => 'dxtrade',
};
$loginids{dx_demo} = $c->call_ok('trading_platform_new_account', $params)->result->{account_id};

$params->{args} = {
    account_type => 'demo',
    market_type  => 'all',
    currency     => 'USD',
    platform     => 'ctrader',
};
$loginids{ct_demo} = $c->call_ok('trading_platform_new_account', $params)->result->{account_id};

$params = {
    language => 'EN',
    token    => $tokens{crw_df},
    args     => {
        account_type => 'gaming',
        mainPassword => $trading_password,
    },
};
$loginids{mt5_gaming} = $c->call_ok('mt5_new_account', $params)->result->{login};

$params->{args} = {
    account_type     => 'financial',
    mt5_account_type => 'financial',
    mainPassword     => $trading_password,
};
$loginids{mt5_financial} = $c->call_ok('mt5_new_account', $params)->result->{login};

$params->{args} = {
    account_type => 'real',
    password     => $trading_password,
    market_type  => 'all',
    currency     => 'USD',
    platform     => 'dxtrade',
};
$loginids{dx_real} = $c->call_ok('trading_platform_new_account', $params)->result->{account_id};

$params->{args} = {
    account_type => 'real',
    market_type  => 'all',
    currency     => 'USD',
    platform     => 'ctrader',
};
$loginids{ct_real} = $c->call_ok('trading_platform_new_account', $params)->result->{account_id};

subtest 'account list' => sub {

    $params->{token} = $tokens{vrtc_binary};
    $params->{args}  = {accounts => 'all'};

    my $res    = $c->call_ok('transfer_between_accounts', $params)->result;
    my @logins = map { $_->{loginid} } $res->{accounts}->@*;
    cmp_deeply \@logins, bag(@loginids{qw(vrtc_binary)}), 'VRTC only gets self';

    $params->{token} = $tokens{cr_usd};
    $res = $c->call_ok('transfer_between_accounts', $params)->result;

    @logins = map { $_->{loginid} } $res->{accounts}->@*;
    cmp_deeply \@logins, bag(@loginids{qw(cr_usd cr_btc mt5_gaming_legacy mt5_financial_legacy dx_real_legacy ct_real_legacy)}),
        'CR gets all real accounts';

    $accs{cr_standard} = $user->create_client(
        %args,
        broker_code    => 'CR',
        account_type   => 'standard',
        currency       => 'USD',
        wallet_loginid => $loginids{crw_df});
    $loginids{cr_standard} = $accs{cr_standard}->loginid;
    $tokens{cr_standard}   = $token_api->create_token($loginids{cr_standard}, 'test', ['admin']);
    delete $user->{loginid_details};    # delete cache

    $params->{token} = $tokens{vrtc_binary};
    $res             = $c->call_ok('transfer_between_accounts', $params)->result;
    @logins          = map { $_->{loginid} } $res->{accounts}->@*;
    cmp_deeply \@logins, bag(@loginids{qw(vrtc_binary)}), 'VRTC still only gets self';

    $params->{token} = $tokens{vrw};
    $res             = $c->call_ok('transfer_between_accounts', $params)->result;
    @logins          = map { $_->{loginid} } $res->{accounts}->@*;
    cmp_deeply \@logins, bag(@loginids{qw(vrw vrtc_trading mt5_demo dx_demo ct_demo)}), 'expected accounts for VRW';

    $params->{token} = $tokens{vrtc_trading};
    $res             = $c->call_ok('transfer_between_accounts', $params)->result;
    @logins          = map { $_->{loginid} } $res->{accounts}->@*;
    cmp_deeply \@logins, bag(@loginids{qw(vrw vrtc_trading)}), 'expected accounts for linked VRTC';

    $params->{token} = $tokens{crw_df};
    $res             = $c->call_ok('transfer_between_accounts', $params)->result;
    @logins          = map { $_->{loginid} } $res->{accounts}->@*;
    cmp_deeply \@logins, bag(@loginids{qw(crw_df crw_btc cr_standard crw_p2p crw_pa mt5_gaming mt5_financial dx_real ct_real)}),
        'expected accounts for CRW wallet with linked accounts';
};

subtest 'Virtual transfers' => sub {

    # standard
    $params->{token} = $tokens{vrw};
    $params->{args}  = {
        account_from => $loginids{vrw},
        account_to   => $loginids{vrtc_trading},
        amount       => 10,
        currency     => 'USD',
    };

    my %expected = (
        a => {
            loginid               => $loginids{vrw},
            balance               => num(990),
            account_type          => 'virtual',
            account_category      => 'wallet',
            currency              => 'USD',
            transfers             => 'all',
            demo_account          => bool(1),
            landing_company_short => $accs{vrw}->landing_company->short,
        },
        b => {
            loginid               => $loginids{vrtc_trading},
            balance               => num(10),
            account_type          => 'standard',
            account_category      => 'trading',
            currency              => 'USD',
            transfers             => 'all',
            demo_account          => bool(1),
            landing_company_short => $accs{vrtc_trading}->landing_company->short,
            market_type           => 'all',
        });

    my $res = $c->call_ok('transfer_between_accounts', $params)->has_no_error('VRW to linked VRTC ok')->result;
    cmp_deeply $res->{accounts}, bag(values %expected), 'VRW to linked VRTC expected response';
    cmp_ok $accs{vrw}->account->balance,          '==', 990, 'VRW balance deducted';
    cmp_ok $accs{vrtc_trading}->account->balance, '==', 10,  'VRTC balance credited';

    $params->{token} = $tokens{vrtc_trading};
    $params->{args}  = {
        account_from => $loginids{vrtc_trading},
        account_to   => $loginids{vrw},
        amount       => 10,
        currency     => 'USD',
    };

    $res                    = $c->call_ok('transfer_between_accounts', $params)->has_no_error('Linked VRTC to VRW ok')->result;
    $expected{a}->{balance} = num(1000);
    $expected{b}->{balance} = num(0);
    cmp_deeply $res->{accounts}, bag(values %expected), 'Linked VRTC to VRW expected response';

    cmp_ok $accs{vrw}->account->balance,          '==', 1000, 'VRW balance credited';
    cmp_ok $accs{vrtc_trading}->account->balance, '==', 0,    'VRTC balance deducted';

    cmp_ok $user->daily_transfer_count(
        type       => 'virtual',
        identifier => $user->id
        ),
        '==', 2, 'virtual transfer count incremented for user';
    cmp_ok $user->daily_transfer_amount(
        type       => 'virtual',
        identifier => $user->id
        ),
        '==', 20, 'virtual transfer amount incremented for user';

    # MT5
    $expected{a}->{balance} = num(990);
    $expected{b} = {
        loginid               => $loginids{mt5_demo},
        balance               => num(10010),            # mt5 demo accounts get created with 10k initial balance for now
        account_type          => 'mt5',
        account_category      => 'trading',
        currency              => 'USD',
        transfers             => 'all',
        demo_account          => bool(1),
        mt5_group             => ignore(),
        landing_company_short => 'svg',
        market_type           => 'synthetic',
        sub_account_type      => 'financial',
        product               => 'synthetic',
    };

    $params->{token}              = $tokens{vrw};
    $params->{args}{account_from} = $loginids{vrw};
    $params->{args}{account_to}   = $loginids{mt5_demo};
    $res                          = $c->call_ok('transfer_between_accounts', $params)->has_no_error('VRW to MT5 ok')->result;
    cmp_deeply $res->{accounts}, bag(values %expected), 'VRW to MT5 expected response';
    $params->{args}{account_from} = $loginids{mt5_demo};
    $params->{args}{account_to}   = $loginids{vrw};
    $res                          = $c->call_ok('transfer_between_accounts', $params)->has_no_error('MT5 to VRW ok')->result;
    $expected{a}->{balance}       = num(1000);
    $expected{b}->{balance}       = num(10000);
    cmp_deeply $res->{accounts}, bag(values %expected), 'MT5 to VRW expected response';

    cmp_ok $user->daily_transfer_count(
        type       => 'virtual',
        identifier => $user->id
        ),
        '==', 4, 'virtual transfer count incremented for user';
    cmp_ok $user->daily_transfer_amount(
        type       => 'virtual',
        identifier => $user->id
        ),
        '==', 40, 'virtual transfer amount incremented for user';

    # derivx
    $expected{a}->{balance} = num(990);
    $expected{b} = {
        loginid               => $loginids{dx_demo},
        balance               => num(10010),           # derivX demo accounts get created with 10k initial balance for now
        account_type          => 'dxtrade',
        account_category      => 'trading',
        currency              => 'USD',
        transfers             => 'all',
        demo_account          => bool(1),
        market_type           => 'all',
        landing_company_short => 'svg',
    };

    $params->{args}{account_from} = $loginids{vrw};
    $params->{args}{account_to}   = $loginids{dx_demo};
    $res                          = $c->call_ok('transfer_between_accounts', $params)->has_no_error('VRW to DerivX ok')->result;
    cmp_deeply $res->{accounts}, bag(values %expected), 'VRW to DerivX expected response';

    $params->{args}{account_from} = $loginids{dx_demo};
    $params->{args}{account_to}   = $loginids{vrw};
    $res                          = $c->call_ok('transfer_between_accounts', $params)->has_no_error('DerivX to VRW ok')->result;
    $expected{a}->{balance}       = num(1000);
    $expected{b}->{balance}       = num(10000);
    cmp_deeply $res->{accounts}, bag(values %expected), 'DerivX to VRW expected response';

    cmp_ok $user->daily_transfer_count(
        type       => 'virtual',
        identifier => $user->id
        ),
        '==', 6, 'virtual transfer count incremented for user';
    cmp_ok $user->daily_transfer_amount(
        type       => 'virtual',
        identifier => $user->id
        ),
        '==', 60, 'virtual transfer amount incremented for user';

    # ctrader
    $expected{a}->{balance} = num(990);
    $expected{b} = {
        loginid               => $loginids{ct_demo},
        balance               => num(10),
        account_type          => 'ctrader',
        account_category      => 'trading',
        currency              => 'USD',
        transfers             => 'all',
        demo_account          => bool(1),
        market_type           => 'all',
        landing_company_short => 'svg',
    };

    $params->{args}{account_from} = $loginids{vrw};
    $params->{args}{account_to}   = $loginids{ct_demo};
    $res                          = $c->call_ok('transfer_between_accounts', $params)->has_no_error('VRW to CTrader ok')->result;
    cmp_deeply $res->{accounts}, bag(values %expected), 'VRW to CTrader expected response';

    $params->{args}{account_from} = $loginids{ct_demo};
    $params->{args}{account_to}   = $loginids{vrw};
    $res                          = $c->call_ok('transfer_between_accounts', $params)->has_no_error('CTrader to VRW ok')->result;
    $expected{a}->{balance}       = num(1000);
    $expected{b}->{balance}       = num(0);
    cmp_deeply $res->{accounts}, bag(values %expected), 'CTrader to VRW expected response';

    cmp_ok $user->daily_transfer_count(
        type       => 'virtual',
        identifier => $user->id
        ),
        '==', 8, 'virtual transfer count incremented for user';
    cmp_ok $user->daily_transfer_amount(
        type       => 'virtual',
        identifier => $user->id
        ),
        '==', 80, 'virtual transfer amount incremented for user';

    # errors
    $app_config->payments->transfer_between_accounts->daily_cumulative_limit->enable(0);
    $app_config->payments->transfer_between_accounts->limits->virtual(8);

    $params->{token} = $tokens{vrw};
    $params->{args}{account_from} = $loginids{vrw};

    for my $l (qw(vrtc_trading mt5_demo dx_demo ct_demo)) {
        $params->{args}{account_to} = $loginids{$l};

        $c->call_ok('transfer_between_accounts', $params)->error_code_is('MaximumTransfers', "vrw to $l error code for exceed transfer count")
            ->error_message_like(qr/up to 8 transfers/, "vrw to $l error message for exceed transfer count")->result;
    }

    $app_config->payments->transfer_between_accounts->daily_cumulative_limit->enable(1);
    $app_config->payments->transfer_between_accounts->daily_cumulative_limit->virtual(80);

    for my $l (qw(vrtc_trading mt5_demo dx_demo ct_demo)) {
        $params->{args}{account_to} = $loginids{$l};

        $c->call_ok('transfer_between_accounts', $params)->error_code_is('MaximumAmountTransfers', "vrw to $l error code for exceed transfer amount")
            ->error_message_like(qr/80.00 USD per day/, "vrw to $l error message for exceed transfer amount");
    }

    $app_config->payments->transfer_between_accounts->daily_cumulative_limit->enable(0);
    $app_config->payments->transfer_between_accounts->limits->virtual(100);

    $params->{token}              = $tokens{vrtc_trading};
    $params->{args}{account_from} = $loginids{vrw};
    $params->{args}{account_to}   = $loginids{vrtc_trading};
    $c->call_ok('transfer_between_accounts', $params)
        ->error_code_is('IncompatibleClientLoginidClientFrom', 'VRTC token cannot perform transfer for VRW account');

    # these tests are to specifically check that we don't treat VR transfers as demo topups
    $params->{token}              = $tokens{vrw};
    $params->{token_type}         = 'oauth_token';
    $params->{args}{account_from} = $loginids{crw_df};

    $params->{args}{account_to} = $loginids{vrtc_trading};
    $c->call_ok('transfer_between_accounts', $params)->error_code_is('RealToVirtualNotAllowed', 'Cannot transfer from real wallet to demo standard');

    $params->{args}{account_to} = $loginids{mt5_demo};
    $c->call_ok('transfer_between_accounts', $params)->error_code_is('RealToVirtualNotAllowed', 'Cannot transfer from real wallet to mt5 demo');

    $params->{args}{account_to} = $loginids{dx_demo};
    $c->call_ok('transfer_between_accounts', $params)->error_code_is('DXInvalidAccount', 'Cannot transfer from real wallet to dxtrade demo');

    $params->{args}{account_to} = $loginids{ct_demo};
    $c->call_ok('transfer_between_accounts', $params)->error_code_is('CTraderInvalidAccount', 'Cannot transfer from real wallet to ctrader demo');

    delete $params->{token_type};

    @tests = (
        [vrw           => 'SameAccountNotAllowed'],
        [crw_df        => 'RealToVirtualNotAllowed'],
        [crw_btc       => 'RealToVirtualNotAllowed'],
        [cr_standard   => 'RealToVirtualNotAllowed'],
        [crw_p2p       => 'RealToVirtualNotAllowed'],
        [crw_pa        => 'RealToVirtualNotAllowed'],
        [crw_pa_client => 'RealToVirtualNotAllowed'],
        [mt5_gaming    => 'RealToVirtualNotAllowed'],
        [mt5_financial => 'RealToVirtualNotAllowed'],
        [dx_real       => 'DXInvalidAccount'],
        [ct_real       => 'CTraderInvalidAccount'],
    );
    run_tests('vrw');

    @tests = (
        [vrtc_trading  => 'SameAccountNotAllowed'],
        [mt5_demo      => 'TransferBlockedTradingAccounts'],
        [dx_demo       => 'DXInvalidAccount'],
        [ct_demo       => 'CTraderInvalidAccount'],
        [crw_df        => 'RealToVirtualNotAllowed'],
        [crw_btc       => 'RealToVirtualNotAllowed'],
        [cr_standard   => 'RealToVirtualNotAllowed'],
        [crw_p2p       => 'RealToVirtualNotAllowed'],
        [crw_pa        => 'RealToVirtualNotAllowed'],
        [crw_pa_client => 'RealToVirtualNotAllowed'],
        [mt5_gaming    => 'RealToVirtualNotAllowed'],
        [mt5_financial => 'RealToVirtualNotAllowed'],
        [dx_real       => 'DXInvalidAccount'],
        [ct_real       => 'CTraderInvalidAccount'],
    );
    run_tests('vrtc_trading');
};

subtest 'real transfers' => sub {

    # crw - standard
    my %expected = (
        a => {
            loginid               => $loginids{crw_df},
            balance               => num(990),
            account_type          => 'doughflow',
            account_category      => 'wallet',
            currency              => 'USD',
            transfers             => 'all',
            demo_account          => bool(0),
            landing_company_short => $accs{crw_df}->landing_company->short,
        },
        b => {
            loginid               => $loginids{cr_standard},
            balance               => num(10),
            account_type          => 'standard',
            account_category      => 'trading',
            currency              => 'USD',
            transfers             => 'all',
            demo_account          => bool(0),
            market_type           => 'all',
            landing_company_short => $accs{cr_standard}->landing_company->short,
        });

    $params->{token} = $tokens{crw_df};
    $params->{args}  = {
        account_from => $loginids{crw_df},
        account_to   => $loginids{cr_standard},
        amount       => 10,
        currency     => 'USD',
    };

    my $res = $c->call_ok('transfer_between_accounts', $params)->has_no_error('CRW to standard ok')->result;
    cmp_deeply $res->{accounts}, bag(values %expected), 'CRW to standard expected response';
    cmp_ok $accs{crw_df}->account->balance,      '==', 990, 'CRW balance debited';
    cmp_ok $accs{cr_standard}->account->balance, '==', 10,  'CR standard balance credited';

    $params->{token}              = $tokens{cr_standard};
    $params->{args}{account_from} = $loginids{cr_standard};
    $params->{args}{account_to}   = $loginids{crw_df};
    $expected{a}->{balance}       = num(1000);
    $expected{b}->{balance}       = num(0);
    $res                          = $c->call_ok('transfer_between_accounts', $params)->has_no_error('standard to CRW ok')->result;
    cmp_deeply $res->{accounts}, bag(values %expected), 'standard to CRW expected response';
    cmp_ok $accs{crw_df}->account->balance,      '==', 1000, 'CRW balance credited';
    cmp_ok $accs{cr_standard}->account->balance, '==', 0,    'CR standard balance debited';

    cmp_ok $user->daily_transfer_count(
        type       => 'dtrade',
        identifier => $loginids{crw_df}
        ),
        '==', 2, 'dtrade transfer count incremented for wallet';
    cmp_ok $user->daily_transfer_amount(
        type       => 'dtrade',
        identifier => $loginids{crw_df}
        ),
        '==', 20, 'dtrade transfer amount incremented for wallet';

    # crw usd - crw btc
    my $btc_amt = (10 - (10 * 0.05)) / 25000;
    $expected{a}->{balance} = num(990);
    $expected{b} = {
        loginid               => $loginids{crw_btc},
        balance               => num($btc_amt),
        account_type          => 'crypto',
        account_category      => 'wallet',
        currency              => 'BTC',
        transfers             => 'all',
        demo_account          => bool(0),
        landing_company_short => $accs{crw_btc}->landing_company->short,
    };

    $params->{token}              = $tokens{crw_df};
    $params->{args}{account_from} = $loginids{crw_df};
    $params->{args}{account_to}   = $loginids{crw_btc};
    $res                          = $c->call_ok('transfer_between_accounts', $params)->has_no_error('CRW USD to BTC ok')->result;
    cmp_deeply $res->{accounts}, bag(values %expected), 'CRW USD to BTC expected response';
    cmp_ok $accs{crw_df}->account->balance,  '==', 990,      'USD balance debited';
    cmp_ok $accs{crw_btc}->account->balance, '==', $btc_amt, 'BTC standard balance credited minus fee';

    my $usd_amt = sprintf('%.2f', ($btc_amt - ($btc_amt * 0.05)) * 25000);
    $expected{a}->{balance} = num(990 + $usd_amt);
    $expected{b}->{balance} = num(0);

    $params->{token} = $tokens{crw_btc};
    $params->{args}  = {
        account_from => $loginids{crw_btc},
        account_to   => $loginids{crw_df},
        amount       => $btc_amt,
        currency     => 'BTC',
    };

    $res = $c->call_ok('transfer_between_accounts', $params)->has_no_error('CRW BTC to USD ok')->result;
    cmp_deeply $res->{accounts}, bag(values %expected), 'CRW USD to BTC expected response';
    cmp_ok $accs{crw_df}->account->balance,  '==', 990 + $usd_amt, 'USD balance credited minus fee';
    cmp_ok $accs{crw_btc}->account->balance, '==', 0,              'BTC standard balance debited';

    cmp_ok $user->daily_transfer_count(
        type       => 'internal',
        identifier => $user->id
        ),
        '==', 2, 'internal transfer count incremented for user';
    cmp_ok $user->daily_transfer_amount(
        type       => 'internal',
        identifier => $user->id
        ),
        '==', 10 + ($btc_amt * 25000), 'internal transfer amount incremented for user';

    # reset wallet to 1000
    BOM::Test::Helper::Client::top_up($accs{crw_df}, 'USD', 1000 - $accs{crw_df}->account->balance);

    # crw usd - P2P
    $expected{a}->{balance} = num(990);
    $expected{b} = {
        loginid               => $loginids{crw_p2p},
        balance               => num(10),
        account_type          => 'p2p',
        account_category      => 'wallet',
        currency              => 'USD',
        transfers             => 'deposit',
        demo_account          => bool(0),
        landing_company_short => $accs{crw_p2p}->landing_company->short,
    };

    $params->{token} = $tokens{crw_df};
    $params->{args}  = {
        account_from => $loginids{crw_df},
        account_to   => $loginids{crw_p2p},
        amount       => 10,
        currency     => 'USD',
    };
    $res = $c->call_ok('transfer_between_accounts', $params)->has_no_error('CRW to P2P ok')->result;
    cmp_deeply $res->{accounts}, bag(values %expected), 'CRW to P2P expected response';

    cmp_ok $user->daily_transfer_count(
        type       => 'wallet',
        identifier => $user->id
        ),
        '==', 1, 'wallet transfer count incremented for user';
    cmp_ok $user->daily_transfer_amount(
        type       => 'wallet',
        identifier => $user->id
        ),
        '==', 10, 'wallet transfer amount incremented for user';

    # crw usd - PA
    $expected{a}->{balance} = num(980);
    $expected{b} = {
        loginid               => $loginids{crw_pa},
        balance               => num(10),
        account_type          => 'paymentagent',
        account_category      => 'wallet',
        currency              => 'USD',
        transfers             => 'deposit',
        demo_account          => bool(0),
        landing_company_short => $accs{crw_pa}->landing_company->short,
    };

    $params->{args} = {
        account_from => $loginids{crw_df},
        account_to   => $loginids{crw_pa},
        amount       => 10,
        currency     => 'USD',
    };
    $res = $c->call_ok('transfer_between_accounts', $params)->has_no_error('CRW to PA ok')->result;
    cmp_deeply $res->{accounts}, bag(values %expected), 'CRW to PA expected response';

    cmp_ok $user->daily_transfer_count(
        type       => 'wallet',
        identifier => $user->id
        ),
        '==', 2, 'wallet transfer count incremented for user';
    cmp_ok $user->daily_transfer_amount(
        type       => 'wallet',
        identifier => $user->id
        ),
        '==', 20, 'wallet transfer amount incremented for user';

    # crw - MT5
    $expected{a}->{balance} = num(970);
    $expected{b} = {
        loginid               => $loginids{mt5_gaming},
        balance               => num(10),
        account_type          => 'mt5',
        account_category      => 'trading',
        currency              => 'USD',
        transfers             => 'all',
        demo_account          => bool(0),
        mt5_group             => ignore(),
        market_type           => 'synthetic',
        landing_company_short => 'svg',
        sub_account_type      => 'financial',
        product               => 'synthetic',
    };

    $params->{args} = {
        account_from => $loginids{crw_df},
        account_to   => $loginids{mt5_gaming},
        amount       => 10,
        currency     => 'USD',
    };

    $res = $c->call_ok('transfer_between_accounts', $params)->has_no_error('CRW to MT5 ok')->result;
    cmp_deeply $res->{accounts}, bag(values %expected), 'CRW to MT5 expected response';
    cmp_ok $user->daily_transfer_count(
        type       => 'MT5',
        identifier => $loginids{crw_df}
        ),
        '==', 1, 'MT5 transfer count incremented for wallet';
    cmp_ok $user->daily_transfer_amount(
        type       => 'MT5',
        identifier => $loginids{crw_df}
        ),
        '==', 10, 'MT5 transfer amount incremented for wallet';

    $params->{args}{account_from} = $loginids{mt5_gaming};
    $params->{args}{account_to}   = $loginids{crw_df};
    $expected{a}->{balance}       = num(980);
    $expected{b}->{balance}       = num(0);

    $res = $c->call_ok('transfer_between_accounts', $params)->has_no_error('MT5 to CRW ok')->result;
    cmp_deeply $res->{accounts}, bag(values %expected), 'MT5 to CRW expected response';
    cmp_ok $user->daily_transfer_count(
        type       => 'MT5',
        identifier => $loginids{crw_df}
        ),
        '==', 2, 'MT5 transfer count incremented for wallet';
    cmp_ok $user->daily_transfer_amount(
        type       => 'MT5',
        identifier => $loginids{crw_df}
        ),
        '==', 20, 'MT5 transfer amount incremented for wallet';

    # crw - Deriv X
    $expected{a}->{balance} = num(970);
    $expected{b} = {
        loginid               => $loginids{dx_real},
        balance               => num(10),
        account_type          => 'dxtrade',
        account_category      => 'trading',
        currency              => 'USD',
        transfers             => 'all',
        demo_account          => bool(0),
        market_type           => 'all',
        landing_company_short => 'svg',
    };

    $params->{args} = {
        account_from => $loginids{crw_df},
        account_to   => $loginids{dx_real},
        amount       => 10,
        currency     => 'USD',
    };

    $res = $c->call_ok('transfer_between_accounts', $params)->has_no_error('CRW to Deriv X ok')->result;
    cmp_deeply $res->{accounts}, bag(values %expected), 'CRW to Deriv X expected response';
    cmp_ok $user->daily_transfer_count(
        type       => 'dxtrade',
        identifier => $loginids{crw_df}
        ),
        '==', 1, 'dxtrade transfer count incremented for wallet';
    cmp_ok $user->daily_transfer_amount(
        type       => 'dxtrade',
        identifier => $loginids{crw_df}
        ),
        '==', 10, 'dxtrade transfer amount incremented for wallet';

    $params->{args}{account_from} = $loginids{dx_real};
    $params->{args}{account_to}   = $loginids{crw_df};
    $expected{a}->{balance}       = num(980);
    $expected{b}->{balance}       = num(0);

    $res = $c->call_ok('transfer_between_accounts', $params)->has_no_error('MT5 to Deriv X ok')->result;
    cmp_deeply $res->{accounts}, bag(values %expected), 'MT5 to Deriv X expected response';
    cmp_ok $user->daily_transfer_count(
        type       => 'dxtrade',
        identifier => $loginids{crw_df}
        ),
        '==', 2, 'dxtrade transfer count incremented for wallet';
    cmp_ok $user->daily_transfer_amount(
        type       => 'dxtrade',
        identifier => $loginids{crw_df}
        ),
        '==', 20, 'dxtrade transfer amount incremented for wallet';

    # crw - CTrader
    $expected{a}->{balance} = num(970);
    $expected{b} = {
        loginid               => $loginids{ct_real},
        balance               => num(10),
        account_type          => 'ctrader',
        account_category      => 'trading',
        currency              => 'USD',
        transfers             => 'all',
        demo_account          => bool(0),
        market_type           => 'all',
        landing_company_short => 'svg',
    };

    $params->{args} = {
        account_from => $loginids{crw_df},
        account_to   => $loginids{ct_real},
        amount       => 10,
        currency     => 'USD',
    };

    $res = $c->call_ok('transfer_between_accounts', $params)->has_no_error('CRW to Deriv EZ ok')->result;
    cmp_deeply $res->{accounts}, bag(values %expected), 'CRW to CTrader expected response';
    cmp_ok $user->daily_transfer_count(
        type       => 'ctrader',
        identifier => $loginids{crw_df}
        ),
        '==', 1, 'ctrader transfer count incremented for wallet';
    cmp_ok $user->daily_transfer_amount(
        type       => 'ctrader',
        identifier => $loginids{crw_df}
        ),
        '==', 10, 'ctrader transfer amount incremented for wallet';

    $params->{args}{account_from} = $loginids{ct_real};
    $params->{args}{account_to}   = $loginids{crw_df};
    $expected{a}->{balance}       = num(980);
    $expected{b}->{balance}       = num(0);

    $res = $c->call_ok('transfer_between_accounts', $params)->has_no_error('MT5 to CTrader ok')->result;
    cmp_deeply $res->{accounts}, bag(values %expected), 'MT5 to CTrader expected response';
    cmp_ok $user->daily_transfer_count(
        type       => 'ctrader',
        identifier => $loginids{crw_df}
        ),
        '==', 2, 'ctrader transfer count incremented for wallet';
    cmp_ok $user->daily_transfer_amount(
        type       => 'ctrader',
        identifier => $loginids{crw_df}
        ),
        '==', 20, 'ctrader transfer amount incremented for wallet';

    # errors
    $params->{token}              = $tokens{crw_p2p};
    $params->{args}{account_from} = $loginids{crw_p2p};
    $params->{args}{account_to}   = $loginids{crw_df};
    $c->call_ok('transfer_between_accounts', $params)->error_code_is('TransferBlockedWalletWithdrawal', 'cannot transfer p2p -> crw');

    $params->{token}              = $tokens{crw_pa};
    $params->{args}{account_from} = $loginids{crw_pa};
    $params->{args}{account_to}   = $loginids{crw_df};
    $c->call_ok('transfer_between_accounts', $params)->error_code_is('TransferBlockedWalletWithdrawal', 'cannot transfer PA -> crw');

    $params->{token}              = $tokens{crw_pa_client};
    $params->{args}{account_from} = $loginids{crw_pa_client};
    $params->{args}{account_to}   = $loginids{crw_df};
    $c->call_ok('transfer_between_accounts', $params)->error_code_is('TransferBlockedWalletWithdrawal', 'cannot transfer PA client -> crw');

    $params->{token}              = $tokens{crw_df};
    $params->{args}{account_from} = $loginids{crw_df};
    $params->{args}{account_to}   = $loginids{crw_pa_client};
    $c->call_ok('transfer_between_accounts', $params)->error_code_is('TransferBlockedWalletDeposit', 'cannot transfer crw -> PA client');

    @tests = ([crw_df => 'SameAccountNotAllowed'],);
    run_tests('crw_df');

    @tests = (
        [crw_btc       => 'SameAccountNotAllowed'],
        [cr_standard   => 'TransferBlockedWalletNotLinked'],
        [mt5_gaming    => 'TransferBlockedWalletNotLinked'],
        [mt5_financial => 'TransferBlockedWalletNotLinked'],
        [dx_real       => 'DXInvalidAccount'],
        [ct_real       => 'CTraderInvalidAccount'],
    );
    run_tests('crw_btc');

    @tests = (
        [cr_standard   => 'SameAccountNotAllowed'],
        [mt5_gaming    => 'TransferBlockedTradingAccounts'],
        [mt5_financial => 'TransferBlockedTradingAccounts'],
        [dx_real       => 'DXInvalidAccount'],
        [ct_real       => 'CTraderInvalidAccount'],
    );
    run_tests('cr_standard');

    $params->{token} = $tokens{crw_df};
    $params->{args}  = {
        account_from => $loginids{crw_df},
        amount       => 10,
        currency     => 'USD',
    };

    for my $l (qw(cr_standard crw_btc crw_p2p mt5_gaming dx_real ct_real)) {
        $app_config->payments->transfer_between_accounts->daily_cumulative_limit->enable(0);
        for my $cfg (qw(dtrade between_accounts between_wallets MT5 dxtrade derivez ctrader)) {
            $app_config->payments->transfer_between_accounts->limits->$cfg(3);
        }

        $params->{args}{account_to} = $loginids{$l};
        $params->{args}{amount} += 0.01;    # avoid duplicate transaction error

        $c->call_ok('transfer_between_accounts', $params)->has_no_error("3rd transfer to $l ok");

        $c->call_ok('transfer_between_accounts', $params)->error_code_is('MaximumTransfers', "$l transfer number limit error code")
            ->error_message_like(qr/up to 3 transfers/, "$l transfer number error message")->result;

        $app_config->payments->transfer_between_accounts->daily_cumulative_limit->enable(1);
        for my $cfg (qw(dtrade between_accounts between_wallets MT5 dxtrade derivez ctrader)) {
            $app_config->payments->transfer_between_accounts->daily_cumulative_limit->$cfg(31);
        }

        $c->call_ok('transfer_between_accounts', $params)->error_code_is('MaximumAmountTransfers', "$l transfer cumulative limit error code")
            ->error_message_like(qr/31.00 USD per day/, "$l transfer cumulative limit error message")->result;
    }

};

done_testing();

sub run_tests {
    my $acc = shift;
    $params->{token}    = $tokens{$acc};
    $params->{currency} = $accs{$acc}->currency;
    for my $t (@tests) {
        $params->{args}{account_from} = $loginids{$acc};
        $params->{args}{account_to}   = $loginids{$t->[0]};
        $params->{args}{currency}     = $accs{$acc} ? $accs{$acc}->currency : 'USD';
        $c->call_ok('transfer_between_accounts', $params)->error_code_is($t->[1], "$acc to $t->[0] gets $t->[1]");

        next if $t->[0] eq $acc;

        $params->{args}{account_from} = $loginids{$t->[0]};
        $params->{args}{account_to}   = $loginids{$acc};
        $params->{args}{currency}     = $accs{$t->[0]} ? $accs{$t->[0]}->currency : 'USD';
        $c->call_ok('transfer_between_accounts', $params)->error_code_is($t->[1], "$t->[0] to $acc gets $t->[1]");
    }
}
