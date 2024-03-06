use strict;
use warnings;

use BOM::Test::RPC::QueueClient;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client;

use Test::More;
use Test::Deep;
use Test::Fatal;
use Test::MockModule;
use Test::Warnings;

use BOM::Config::Runtime;
use BOM::Platform::Token::API;
use Locale::Country::Extra;
use Test::BOM::RPC::Accounts;

# Setting up app config for demo and real server
my $app_config = BOM::Config::Runtime->instance->app_config;
$app_config->system->mt5->http_proxy->demo->p01_ts04(1);
$app_config->system->mt5->http_proxy->real->p02_ts01(1);

my $m       = BOM::Platform::Token::API->new;
my $c       = BOM::Test::RPC::QueueClient->new();
my %DETAILS = %Test::BOM::RPC::Accounts::ACCOUNT_DETAILS;

$ENV{LOG_DETAILED_EXCEPTION} = 1;

subtest 'tradding accounts for wallet accounts' => sub {
    # Preparing mocks
    # Mocking BOM::MT5::User::Async for testing purposes
    my $mock_mt5 = Test::MockModule->new('BOM::MT5::User::Async');

    my $mock_user_data = +{};
    # Mocking get_user to return undef to make sure user dont have any derivez account yet
    $mock_mt5->mock('get_user', sub { return Future->done($mock_user_data->{$_[0]}); });

    # Mocking create_user to create a new derivez user
    my $MT_counter = 1000;
    $mock_mt5->mock(
        'create_user',
        sub {
            my $prefix = ($_[0]{group} // '') =~ /^demo/ ? 'MTD' : 'MTR';
            my $login  = $prefix . $MT_counter++;
            $mock_user_data->{$login} = +{
                $_[0]->%*,
                login           => $login,
                balance         => 0,
                display_balance => '0.00',
                country         => Locale::Country::Extra->new->country_from_code($_[0]->{country} // 'za'),
            };
            return Future->done({login => $login});
        });

    # Mocking deposit to deposit demo account
    $mock_mt5->mock('deposit', sub { return Future->done({status => 1}); });

    # Mocking get_group to return group in from mt5
    $mock_mt5->mock(
        'get_group',
        sub {
            return Future->done(
                +{
                    'currency' => 'USD',
                    'group'    => $_[0],
                    'leverage' => 1,
                    'company'  => 'Deriv Limited'
                });
        });

    my ($user, $wallet_generator) = BOM::Test::Helper::Client::create_wallet_factory('za', 'Gauteng');

    my ($wallet, $token) = $wallet_generator->(qw(CRW doughflow USD));

    $user->update_trading_password($DETAILS{password}{main});

    my $account = $c->call_ok(
        mt5_new_account => {
            token => $token,
            args  => {
                account_type => 'gaming',
                email        => $user->email,
                name         => $wallet->first_name,
                mainPassword => $DETAILS{password}{main},
                leverage     => 100,
            }})->has_no_error('gaming account successfully created')->result;

    ok($account->{login}, "Account was successfully created");
    is($user->get_accounts_links->{$account->{login}}[0]{loginid}, $wallet->loginid, 'Account is linked to the doughflow wallet');

    my $login_list = $c->call_ok(mt5_login_list => {token => $token})->has_no_error('has no error for mt5_login_list')->result;
    is scalar($login_list->@*), 1,                 "Expected number of account in the list";
    is $login_list->[0]{login}, $account->{login}, "Linked account returned in the list";

    $c->call_ok(
        mt5_new_account => {
            token => $token,
            args  => {
                account_type => 'gaming',
                email        => $user->email,
                name         => $wallet->first_name,
                mainPassword => $DETAILS{password}{main},
                leverage     => 100,
            }}
    )->has_error('gaming account successfully created')->has_error('It should fail on creating duplicate account')
        ->error_code_is('MT5CreateUserError', 'Has correct error code for duplicate account')
        ->error_message_like(qr/account already exists/, 'Fail to create duplicate account under the same wallet');

    $c->call_ok(
        mt5_new_account => {
            token => $token,
            args  => {
                account_type => 'demo',
                email        => $user->email,
                name         => $wallet->first_name,
                mainPassword => $DETAILS{password}{main},
                leverage     => 100,
            }}
    )->has_error('gaming account successfully created')->has_error('It should fail on creating duplicate account')
        ->error_code_is('TradingPlatformInvalidAccount', 'Has correct error code for duplicate account');

    $login_list = $c->call_ok(mt5_login_list => {token => $token})->has_no_error('has no error for mt5_login_list')->result;
    is scalar($login_list->@*), 1,                 "Expected number of account in the list";
    is $login_list->[0]{login}, $account->{login}, "Linked account returned in the list";

    my ($p2p_wallet, $p2p_token) = $wallet_generator->(qw(CRW p2p USD));

    my $account_p2p = $c->call_ok(
        mt5_new_account => {
            token => $p2p_token,
            args  => {
                account_type => 'gaming',
                email        => $user->email,
                name         => $wallet->first_name,
                mainPassword => $DETAILS{password}{main},
                leverage     => 100,
            }})->has_no_error('gaming account successfully created')->result;

    ok($account_p2p->{login}, "Account was successfully created");
    is($user->get_accounts_links->{$account_p2p->{login}}[0]{loginid}, $p2p_wallet->loginid, 'Account is linked to the doughflow wallet');

    $login_list = $c->call_ok(mt5_login_list => {token => $p2p_token})->has_no_error('has no error for mt5_login_list')->result;
    is scalar($login_list->@*), 1,                     "Expected number of account in the list";
    is $login_list->[0]{login}, $account_p2p->{login}, "Linked account returned in the list";

    my ($virtual_wallet, $virtual_token) = $wallet_generator->(qw(VRW virtual USD));

    $c->call_ok(
        mt5_new_account => {
            token => $virtual_token,
            args  => {
                account_type => 'gaming',
                email        => $user->email,
                name         => $wallet->first_name,
                mainPassword => $DETAILS{password}{main},
                leverage     => 100,
            }}
    )->has_error('gaming account successfully created')->has_error('Fail to create real money account from virtual wallet')
        ->error_code_is('AccountShouldBeReal', 'Has correct error code')
        ->error_message_like(qr/Only real accounts are allowed to open MT5 real accounts/, 'Has correnct error message');

    my $account_virtual = $c->call_ok(
        mt5_new_account => {
            token => $virtual_token,
            args  => {
                account_type => 'demo',
                email        => $user->email,
                name         => $wallet->first_name,
                mainPassword => $DETAILS{password}{main},
                leverage     => 100,
            }})->has_no_error('gaming account successfully created')->result;

    ok($account_virtual->{login}, "Account was successfully created");
    is($user->get_accounts_links->{$account_virtual->{login}}[0]{loginid}, $virtual_wallet->loginid, 'Account is linked to the doughflow wallet');

    $login_list = $c->call_ok(mt5_login_list => {token => $virtual_token})->has_no_error('has no error for mt5_login_list')->result;
    is scalar($login_list->@*), 1,                         "Expected number of account in the list";
    is $login_list->[0]{login}, $account_virtual->{login}, "Linked account returned in the list";

    my ($crypto_wallet, $crypto_token) = $wallet_generator->(qw(CRW crypto BTC));

    $c->call_ok(
        mt5_new_account => {
            token => $crypto_token,
            args  => {
                account_type => 'gaming',
                email        => $user->email,
                name         => $wallet->first_name,
                mainPassword => $DETAILS{password}{main},
                leverage     => 100,
            }}
    )->has_error('gaming account successfully created')->has_error('It should fail on creating duplicate account')
        ->error_code_is('TradingPlatformInvalidAccount', 'Has correct error code for duplicate account');

    $login_list = $c->call_ok(mt5_login_list => {token => $crypto_token})->has_no_error('has no error for mt5_login_list')->result;
    is scalar($login_list->@*), 0, "Expected number of account in the list";

    my ($mfw_wallet, $mfw_token) = $wallet_generator->(qw(MFW doughflow USD));

    my $account_mfw = $c->call_ok(
        mt5_new_account => {
            token => $mfw_token,
            args  => {
                account_type     => 'financial',
                mt5_account_type => 'financial',
                company          => 'maltainvest',
                email            => $user->email,
                name             => $wallet->first_name,
                mainPassword     => $DETAILS{password}{main},
                leverage         => 100,
            }})->has_no_error('gaming account successfully created')->result;

    ok($account_mfw->{login}, "Account was successfully created");
    is($user->get_accounts_links->{$account_mfw->{login}}[0]{loginid}, $mfw_wallet->loginid, 'Account is linked to the doughflow wallet');

    $login_list = $c->call_ok(mt5_login_list => {token => $mfw_token})->has_no_error('has no error for mt5_login_list')->result;
    is scalar($login_list->@*), 1,                     "Expected number of account in the list";
    is $login_list->[0]{login}, $account_mfw->{login}, "Linked account returned in the list";
};

done_testing();
