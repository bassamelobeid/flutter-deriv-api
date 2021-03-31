use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Test::Deep;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Script::DevExperts;
use BOM::Platform::Token::API;
use BOM::Test::RPC::QueueClient;
use BOM::Test::Helper::Client;
use BOM::Config::Runtime;

BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->all(0);

my $c = BOM::Test::RPC::QueueClient->new();

subtest 'dxtrader accounts' => sub {

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});

    BOM::User->create(
        email    => 'dxaccounts@test.com',
        password => 'test'
    )->add_client($client);
    $client->account('USD');

    my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

    my $params = {language => 'EN'};

    $c->call_ok('trading_platform_new_account', $params)->has_no_system_error->has_error->error_code_is('InvalidToken', 'must be logged in');

    $params->{token} = $token;
    $params->{args}{platform} = 'xxx';

    $c->call_ok('trading_platform_new_account', $params)->has_no_system_error->has_error->error_code_is('TradingPlatformError', 'bad params');

    $params->{args} = {
        platform     => 'dxtrade',
        account_type => 'demo',
        market_type  => 'financial',
        password     => 'test',
    };

    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->all(1);

    $c->call_ok('trading_platform_new_account', $params)->has_no_system_error->has_error->error_code_is('DXSuspended', 'dxtrade suspended')
        ->error_message_is('Deriv X account management is currently suspended.');

    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->all(0);

    my $acc = $c->call_ok('trading_platform_new_account', $params)->has_no_system_error->has_no_error->result;
    like $acc->{account_id}, qr/DXD\d{4}/, 'account id';

    $c->call_ok('trading_platform_new_account', $params)
        ->has_no_system_error->has_error->error_code_is('DXExistingAccount', 'error code for duplicate account.')
        ->error_message_like(qr/You already have Deriv X account of this type/, 'error message for duplicate account');

    $params->{args} = {
        platform => 'dxtrade',
    };

    my $list = $c->call_ok('trading_platform_accounts', $params)->has_no_system_error->has_no_error->result;
    delete $list->[0]{stash};
    delete $acc->{stash};
    cmp_deeply($list, [$acc], 'account list returns created account',);

    cmp_deeply($list, [$acc], 'account list returns created account',);
};

subtest 'dxtrade password change' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});

    BOM::User->create(
        email    => 'test@test.com',
        password => 'test'
    )->add_client($client);
    $client->account('USD');

    $c->call_ok('trading_platform_password_change', {})->has_no_system_error->has_error->error_code_is('InvalidToken', 'must be logged in');

    my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

    # Try without a dx client

    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            new_password => 'C0rrect0',
            old_password => 'InC0rrect0',
        }};

    $c->call_ok('trading_platform_password_change', $params)->has_no_system_error->has_no_error->result_is_deeply(1, 'Password successfully changed');

    # Add dxtrade account

    $params = {
        language => 'EN',
        token    => $token,
        args     => {
            platform     => 'dxtrade',
            account_type => 'demo',
            market_type  => 'financial',
            password     => 'test',
        }};

    $c->call_ok('trading_platform_new_account', $params)->has_no_system_error->has_no_error->result;

    # change trading password

    $params = {
        language => 'EN',
        token    => $token,
        args     => {

        }};

    $c->call_ok('trading_platform_password_change', $params)
        ->has_no_system_error->has_error->error_code_is('PasswordRequired', 'Password is required');

    $params = {
        language => 'EN',
        token    => $token,
        args     => {
            new_password => 'C0rrect0',
            old_password => 'InC0rrect0',
        }};

    $c->call_ok('trading_platform_password_change', $params)->has_no_system_error->has_no_error->result_is_deeply(1, 'Password successfully changed');
};

subtest 'dxtrade password reset' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    my $verification_code;

    my $mock_token = Test::MockModule->new('BOM::Platform::Token');
    $mock_token->mock(
        'token',
        sub {
            $verification_code = $mock_token->original('token')->(@_);
        });

    my $user = BOM::User->create(
        email    => 'test2@test.com',
        password => 'test'
    )->add_client($client);

    my $params = {
        language => 'EN',
        args     => {
            verify_email => $user->email,
            type         => 'trading_platform_password_reset',
        }};

    $c->call_ok('verify_email', $params)->has_no_system_error->has_no_error->result_is_deeply({
            status => 1,
            stash  => {
                app_markup_percentage      => 0,
                valid_source               => 1,
                source_bypass_verification => 0
            },
        },
        'Verification code generated'
    );

    ok $verification_code, 'Got a verification code';

    $c->call_ok('trading_platform_password_reset', {})->has_no_system_error->has_error->error_code_is('InvalidToken', 'must be logged in');

    my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');
    $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account           => 'DX1000',
            platform          => 'dxtrade',
            new_password      => 'C0rrect0',
            verification_code => $verification_code,
        }};

    $c->call_ok('trading_platform_password_reset', $params)->has_no_system_error->has_no_error->result_is_deeply(1, 'Password successfully reset');
    $mock_token->unmock_all;
};

done_testing();
