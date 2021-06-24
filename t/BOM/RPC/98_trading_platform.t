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
use BOM::User::Password;
use BOM::Test::Helper::Client;
use BOM::Config::Runtime;
use Brands::Countries;

BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->all(0);
BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->demo(0);
BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->real(0);

my $c = BOM::Test::RPC::QueueClient->new();

my $last_event;
my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_events->mock('emit', sub { $last_event = \@_ });

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

    $params->{args} = {
        platform => 'xxx',
        password => 'Abcd1234',
    };
    $c->call_ok('trading_platform_new_account', $params)->has_no_system_error->has_error->error_code_is('TradingPlatformError', 'bad params');

    $params->{args} = {
        platform     => 'dxtrade',
        account_type => 'demo',
        market_type  => 'financial',
        password     => '',
    };
    $c->call_ok('trading_platform_new_account', $params)->has_no_system_error->has_error->error_code_is('PasswordRequired', 'bad params');

    $params->{args} = {
        platform     => 'dxtrade',
        account_type => 'demo',
        market_type  => 'financial',
        password     => 'Abcd1234',
        currency     => 'USD',
    };

    my $acc = $c->call_ok('trading_platform_new_account', $params)->has_no_system_error->has_no_error->result;

    cmp_deeply(
        $last_event,
        [
            'trading_platform_account_created',
            {
                loginid    => $client->loginid,
                properties => {
                    account_type => 'demo',
                    market_type  => 'financial',
                    account_id   => $acc->{account_id},
                    login        => $acc->{login},
                    first_name   => $client->first_name,
                }}
        ],
        'new account event emitted'
    );

    ok BOM::User::Password::checkpw('Abcd1234', $client->user->trading_password), 'trading password was set';

    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->all(1);

    $c->call_ok('trading_platform_new_account', $params)->has_no_system_error->has_error->error_code_is('DXSuspended', 'dxtrade suspended')
        ->error_message_is('Deriv X account management is currently suspended.');

    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->all(0);

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

    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->demo(1);
    $c->call_ok('trading_platform_accounts', $params)->has_no_system_error->has_error->error_code_is('DXServerSuspended', 'server suspended');
    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->demo(0);

    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->all(1);
    $c->call_ok('trading_platform_accounts', $params)->has_no_system_error->has_error->error_code_is('DXSuspended', 'all suspended');
    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->all(0);

    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->real(1);
    $c->call_ok('trading_platform_accounts', $params)->has_no_system_error->has_no_error('real suspended has no effect');
    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->real(0);

    $params->{args} = {
        platform     => 'dxtrade',
        account_type => 'real',
        market_type  => 'financial',
        password     => 'Abcd1234',
    };
    my $acc2 = $c->call_ok('trading_platform_new_account', $params)->has_no_system_error->has_no_error('create 2nd account')->result;

    my $tba_acc = {
        account_type => 'dxtrade',
        balance      => $acc2->{balance},
        currency     => $acc2->{currency},
        demo_account => 0,
        loginid      => $acc2->{account_id},
        market_type  => $acc2->{market_type},
    };

    cmp_deeply(
        $c->call_ok(
            'transfer_between_accounts',
            {
                token => $token,
                args  => {accounts => 'all'}}
        )->has_no_error->result->{accounts},
        supersetof($tba_acc),
        'transfer_between_accounts returns the real account'
    );

    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->all(1);
    cmp_deeply(
        $c->call_ok(
            'transfer_between_accounts',
            {
                token => $token,
                args  => {accounts => 'all'}}
        )->has_no_error->result->{accounts},
        none($tba_acc),
        'transfer_between_accounts hides real account when all suspended'
    );
    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->all(0);

    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->real(1);
    cmp_deeply(
        $c->call_ok(
            'transfer_between_accounts',
            {
                token => $token,
                args  => {accounts => 'all'}}
        )->has_no_error->result->{accounts},
        none($tba_acc),
        'transfer_between_accounts hides real account when real suspended'
    );
    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->real(0);

    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->demo(1);
    cmp_deeply(
        $c->call_ok(
            'transfer_between_accounts',
            {
                token => $token,
                args  => {accounts => 'all'}}
        )->has_no_error->result->{accounts},
        supersetof($tba_acc),
        'transfer_between_accounts returns the real account when demo is suspended'
    );
    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->demo(0);

    $params->{args}{password} = 'wrong';
    for my $attempt (1 .. 6) {
        my $res = $c->call_ok('trading_platform_new_account', $params);
        $res->error_code_is('PasswordError', 'error code for 5th bad password') if $attempt == 5;
        $res->error_code_is('PasswordReset', 'error code for 6th bad password') if $attempt == 6;
    }
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
            old_password => 'test',
            new_password => 'C0rrect0',
        }};
    $c->call_ok('trading_platform_password_change', $params)
        ->has_no_system_error->has_error->error_code_is('NoOldPassword', 'cannot provide old password yet');

    $params = {
        language => 'EN',
        token    => $token,
        args     => {
            new_password => 'C0rrect0',
        }};
    $c->call_ok('trading_platform_password_change', $params)->has_no_system_error->has_no_error->result_is_deeply(1, 'New password successfully set');

    # Add dxtrade account

    $params = {
        language => 'EN',
        token    => $token,
        args     => {
            platform     => 'dxtrade',
            account_type => 'demo',
            market_type  => 'financial',
            password     => 'test',
            currency     => 'USD',
        }};
    $c->call_ok('trading_platform_new_account', $params)->has_no_system_error->has_error->error_code_is('PasswordError')
        ->error_message_like(qr/password is incorrect/, 'wrong password');

    $params->{args}{password} = 'C0rrect0';
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
            new_password => 'C0rrect1',
            old_password => 'C0rrect0',
        }};

    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->demo(1);
    $c->call_ok('trading_platform_password_change', $params)
        ->has_no_system_error->has_error->error_code_is('PlatformPasswordChangeError', 'server suspended');
    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->demo(0);

    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->all(1);
    $c->call_ok('trading_platform_password_change', $params)
        ->has_no_system_error->has_error->error_code_is('PlatformPasswordChangeSuspended', 'all suspended');
    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->all(0);

    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->real(1);
    $c->call_ok('trading_platform_password_change', $params)->has_no_system_error->has_no_error('real suspended has no effect');
    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->real(0);

    for my $attempt (1 .. 6) {
        my $res = $c->call_ok('trading_platform_password_change', $params);
        $res->error_code_is('PasswordError', 'error code for 5th bad password') if $attempt == 5;
        $res->error_code_is('PasswordReset', 'error code for 6th bad password') if $attempt == 6;
    }

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
    $client->account('USD');

    my $params = {
        language => 'EN',
        token    => BOM::Platform::Token::API->new->create_token($client->loginid, 'test token'),
        args     => {
            platform     => 'dxtrade',
            account_type => 'demo',
            market_type  => 'financial',
            password     => 'Test1234',
            currency     => 'USD',
        }};

    $c->call_ok('trading_platform_new_account', $params)->has_no_system_error->has_no_error;

    $params = {
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

    $params = {
        language => 'EN',
        args     => {
            platform          => 'dxtrade',
            new_password      => 'C0rrect0',
            verification_code => $verification_code,
        }};

    $c->call_ok('trading_platform_password_reset', $params)->has_no_system_error->has_no_error->result_is_deeply(1, 'Password successfully reset');

    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->all(1);

    $params = {
        language => 'EN',
        args     => {
            verify_email => $user->email,
            type         => 'trading_platform_password_reset',
        }};

    $c->call_ok('verify_email', $params)->has_no_system_error->has_no_error;

    $params = {
        language => 'EN',
        args     => {
            platform          => 'dxtrade',
            new_password      => 'C0rrect1',
            verification_code => $verification_code,
        }};

    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->all(1);
    $c->call_ok('trading_platform_password_reset', $params)
        ->has_no_system_error->has_error->error_code_is('PlatformPasswordChangeSuspended', 'all suspended');
    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->all(0);

    $mock_token->unmock_all;
};

subtest 'new account rules failure scenarios' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
        residence   => 'py',
    });

    my $user = BOM::User->create(
        email    => 'failure@test.com',
        password => 'test'
    );

    $user->add_client($client);

    my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            platform     => 'dxtrade',
            account_type => 'real',
            market_type  => 'financial',
            password     => 'Abcd1234',
            currency     => 'USD',
        },
    };

    $c->call_ok('trading_platform_new_account', $params)
        ->has_no_system_error->has_error->error_code_is('SetExistingAccountCurrency', 'must set currency');

    # Give currency
    $client->account('USD');
    $c->call_ok('trading_platform_new_account', $params)->has_no_system_error->has_error->error_code_is('InvalidAccount', 'Restricted country');

    # Move to Brazil
    $client->residence('br');
    $client->save;

    $c->call_ok('trading_platform_new_account', $params)->has_no_system_error->has_error->error_code_is('RealAccountMissing', 'Real account missing')
        ->error_message_is('You are on a virtual account. To open a Deriv X account, please upgrade to a real account.', 'Expected error message');

    # Give real account
    my $real = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        residence   => 'br',
    });

    $user->add_client($real);

    # even though real account was given, only a real accout can open real dxtrade account
    $c->call_ok('trading_platform_new_account', $params)
        ->has_no_system_error->has_error->error_code_is('AccountShouldBeReal', 'Demo account cannot open real dxtrader')
        ->error_message_is('Only real accounts are allowed to open Deriv X real accounts', 'Expected error message');

    $token = BOM::Platform::Token::API->new->create_token($real->loginid, 'real token');
    $params->{token} = $token;

    # dang, the currency
    $c->call_ok('trading_platform_new_account', $params)
        ->has_no_system_error->has_error->error_code_is('SetExistingAccountCurrency', 'must set currency');

    # give currency to the real account
    $real->account('USD');

    # mocking lc
    my $lc_short;
    my $mock_lc = Test::MockModule->new('LandingCompany');
    $mock_lc->mock(
        'short',
        sub {
            return $lc_short;
        });

    # company won't match
    $lc_short = 'some_fancy_name';
    $c->call_ok('trading_platform_new_account', $params)
        ->has_no_system_error->has_error->error_code_is('FinancialAccountMissing', 'Financial account is missing due to mocked LC')
        ->error_message_is('Your existing account does not allow Deriv X trading. To open a Deriv X account, please upgrade to a financial account.',
        'Expected error message');

    # company won't match for gaming
    $params->{args}->{market_type} = 'gaming';
    $lc_short = 'other_fancy_name';
    $c->call_ok('trading_platform_new_account', $params)
        ->has_no_system_error->has_error->error_code_is('GamingAccountMissing', 'Gaming account is missing due to mocked LC')
        ->error_message_is('Your existing account does not allow Deriv X trading. To open a Deriv X account, please upgrade to a gaming account.',
        'Expected error message');

    # unmock LC short
    $mock_lc->unmock('short');

    # get back to financial
    $params->{args}->{market_type} = 'financial';

    # Move to the U.K.
    $real->residence('gb');
    $real->save;
    # Only svg countries
    $c->call_ok('trading_platform_new_account', $params)
        ->has_no_system_error->has_error->error_code_is('TradingAccountNotAllowed', 'only svg countries')
        ->error_message_is('This trading platform account is not available in your country yet.', 'Expected error message');

    # Move back to Brazil
    $real->residence('br');
    $real->save;

    # try to open with not supported currency
    $params->{args}->{currency} = 'JPY';
    $c->call_ok('trading_platform_new_account', $params)
        ->has_no_system_error->has_error->error_code_is('TradingAccountCurrencyNotAllowed', 'must use a valid currency');

    # go back to valid currency USD
    $params->{args}->{currency} = 'USD';

    # take away some data
    $real->first_name('');
    $real->save;

    $c->call_ok('trading_platform_new_account', $params)
        ->has_no_system_error->has_error->error_details_is({missing => ['first_name']}, 'Missing details are properly reported')
        ->error_code_is('InsufficientAccountDetails', 'Real account needs complete details');

    # take away some more
    $real->last_name('');
    $real->save;

    $c->call_ok('trading_platform_new_account', $params)
        ->has_no_system_error->has_error->error_details_is({missing => ['first_name', 'last_name']}, 'Missing details are properly reported')
        ->error_code_is('InsufficientAccountDetails', 'Real account needs complete details');

    $real->first_name('Mister');
    $real->last_name('Familyman');
    $real->save;

    # Some mocky mockery
    my $mock_country   = Test::MockModule->new('Brands::Countries');
    my $country_config = Brands::Countries->new->countries_list->{br};
    $mock_country->mock(
        'countries_list',
        sub {
            return {$real->residence => $country_config};
        });

    $country_config->{trading_age_verification} = 1;
    $c->call_ok('trading_platform_new_account', $params)
        ->has_no_system_error->has_error->error_code_is('NoAgeVerification', 'should be age verified');

    # give age verification
    $real->status->set('age_verification', 'test', 'test');

    # Mock the client
    my $is_financial_assessment_complete = 0;
    my $mock_client                      = Test::MockModule->new('BOM::User::Client');
    $mock_client->mock(
        'is_financial_assessment_complete',
        sub {
            return $is_financial_assessment_complete;
        });

    $c->call_ok('trading_platform_new_account', $params)
        ->has_no_system_error->has_error->error_code_is('FinancialAssessmentMandatory', 'should complete F.A.')
        ->error_message_is('Please complete your financial assessment.', 'Expected error message');

    # Complete F.A.
    $is_financial_assessment_complete = 1;

    # Mock Landing Company requirements
    $mock_lc->mock(
        'requirements',
        sub {
            return {
                compliance => {
                    tax_information => 1,
                }};
        });

    $country_config->{tax_details_required} = 1;
    $c->call_ok('trading_platform_new_account', $params)
        ->has_no_system_error->has_error->error_code_is('TINDetailsMandatory', 'should complete tax details')
        ->error_message_is('We require your tax information for regulatory purposes. Please fill in your tax information.', 'Expected error message');

    # complete tax details
    $real->status->set('crs_tin_information', 'test', 'test');
    my $acc = $c->call_ok('trading_platform_new_account', $params)->has_no_system_error->has_no_error->result;

    cmp_deeply $acc,
        {
        login       => re('^[a-z0-9]+$'),
        market_type => 'financial',
        platform    => 'dxtrade',
        stash       => {
            app_markup_percentage      => '0',
            valid_source               => 1,
            source_bypass_verification => 0
        },
        display_balance       => '0.00',
        balance               => '0.00',
        landing_company_short => 'svg',
        account_id            => re('^DX.*$'),
        currency              => 'USD',
        account_type          => 'real',
        },
        'DXtrader account successfully created';

    $mock_lc->unmock_all;
    $mock_country->unmock_all;
    $mock_client->unmock_all;
};

done_testing();
