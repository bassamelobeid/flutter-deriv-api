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

# Mocking all of the necessary exchange rates in redis.
my $redis_exchangerates = BOM::Config::Redis::redis_exchangerates_write();
my @all_currencies      = qw(EUR ETH AUD eUSDT tUSDT BTC LTC UST USDC USD GBP XRP);

for my $currency (@all_currencies) {
    $redis_exchangerates->hmset(
        'exchange_rates::' . $currency . '_USD',
        quote => 1,
        epoch => time
    );
}

# Used it to enable wallet migration in progress
sub _enable_wallet_migration {
    my $user       = shift;
    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->system->suspend->wallets(0);
    my $redis_rw = BOM::Config::Redis::redis_replicated_write();
    $redis_rw->set(
        "WALLET::MIGRATION::IN_PROGRESS::" . $user->id, 1,
        EX => 30 * 60,
        "NX"
    );
}
# Used it to disable wallet migration
sub _disable_wallet_migration {
    my $user       = shift;
    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->system->suspend->wallets(1);
    my $redis_rw = BOM::Config::Redis::redis_replicated_write();
    $redis_rw->del("WALLET::MIGRATION::IN_PROGRESS::" . $user->id);
}

subtest 'dxtrader accounts' => sub {
    my $user = BOM::User->create(
        email    => 'dxaccounts@test.com',
        password => 'test'
    );
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        binary_user_id => $user->id,
    });

    $user->add_client($client);
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

    BOM::Config::Runtime->instance->app_config->system->dxtrade->enable_all_market_type->demo(1);

    $params->{args} = {
        platform     => 'dxtrade',
        account_type => 'demo',
        market_type  => 'all',
        password     => '',
    };
    $c->call_ok('trading_platform_new_account', $params)->has_no_system_error->has_error->error_code_is('PasswordRequired', 'bad params');

    $params->{args} = {
        platform     => 'dxtrade',
        account_type => 'demo',
        market_type  => 'all',
        password     => 'Abcd1234',
        currency     => 'USD',
    };

    _enable_wallet_migration($client->user);
    $c->call_ok('trading_platform_new_account', $params)
        ->has_no_system_error->has_error->error_code_is('WalletMigrationInprogress', 'The wallet migration is in progress.')
        ->error_message_is(
        'This may take up to 2 minutes. During this time, you will not be able to deposit, withdraw, transfer, and add new accounts.');
    _disable_wallet_migration($client->user);

    my $acc = $c->call_ok('trading_platform_new_account', $params)->has_no_system_error->has_no_error->result;

    cmp_deeply(
        $last_event,
        [
            'trading_platform_account_created',
            {
                loginid    => $client->loginid,
                properties => {
                    account_type => 'demo',
                    market_type  => 'all',
                    account_id   => $acc->{account_id},
                    login        => $acc->{login},
                    first_name   => $client->first_name,
                    platform     => 'dxtrade'
                }}
        ],
        'new account event emitted'
    );

    ok BOM::User::Password::checkpw('Abcd1234', $client->user->dx_trading_password), 'trading password was set';

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
    my $acc_demo_suspend = $c->call_ok('trading_platform_accounts', $params)->has_no_system_error->has_no_error->result;
    cmp_deeply(
        $acc_demo_suspend,
        [{
                'account_id'            => $acc->{account_id},
                'login'                 => $acc->{login},
                'currency'              => 'USD',
                'platform'              => 'dxtrade',
                'account_type'          => 'demo',
                'landing_company_short' => 'svg',
                'market_type'           => 'all',
                'enabled'               => 0,
            }
        ],
        'Suspended demo server return result with enabled=0'
    );
    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->demo(0);

    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->all(1);
    my $acc_all_suspend = $c->call_ok('trading_platform_accounts', $params)->has_no_system_error->has_no_error->result;
    cmp_deeply(
        $acc_all_suspend,
        [{
                'account_id'            => $acc->{account_id},
                'login'                 => $acc->{login},
                'landing_company_short' => 'svg',
                'currency'              => 'USD',
                'platform'              => 'dxtrade',
                'account_type'          => 'demo',
                'enabled'               => 0,
                'market_type'           => 'all'
            }
        ],
        'Suspended all server return result with enabled=0'
    );
    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->all(0);

    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->real(1);
    $c->call_ok('trading_platform_accounts', $params)->has_no_system_error->has_no_error('real suspended has no effect');
    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->real(0);

    $params->{args} = {
        platform     => 'dxtrade',
        account_type => 'real',
        market_type  => 'all',
        password     => 'Abcd1234',
    };
    my $acc2 = $c->call_ok('trading_platform_new_account', $params)->has_no_system_error->has_no_error('create 2nd account')->result;

    my $tba_acc = {
        balance               => $acc2->{balance},
        currency              => $acc2->{currency},
        demo_account          => 0,
        loginid               => $acc2->{account_id},
        market_type           => 'all',
        account_type          => 'dxtrade',
        account_category      => 'trading',
        transfers             => 'all',
        landing_company_short => 'svg',
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

subtest 'dxtrade for MF + CR' => sub {
    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    $client_cr->account('USD');
    my $client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'MF'});
    $client_mf->account('USD');

    my $user = BOM::User->create(
        email    => 'dxaccounts1@test.com',
        password => 'test'
    );
    $user->add_client($client_mf);
    $user->add_client($client_cr);

    my $params = {language => 'EN'};
    $params->{token} = BOM::Platform::Token::API->new->create_token($client_mf->loginid, 'test token');

    $params->{args} = {
        platform     => 'dxtrade',
        account_type => 'real',
        market_type  => 'all',
        password     => 'Abcd1234',
    };

    $c->call_ok('trading_platform_new_account', $params)
        ->has_no_system_error->error_code_is('GamingAccountMissing', 'Dxtrader not possible to create from MF account');

    $params->{token} = BOM::Platform::Token::API->new->create_token($client_cr->loginid, 'test token');

    my $res = $c->call_ok('trading_platform_new_account', $params)->has_no_system_error->has_no_error->result;
    like $res->{account_id}, qr/^DXR\d+$/, 'DX account was created correctly from CR account';
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
            platform     => 'dxtrade'
        }};
    $c->call_ok('trading_platform_password_change', $params)
        ->has_no_system_error->has_error->error_code_is('NoOldPassword', 'cannot provide old password yet');

    $params = {
        language => 'EN',
        token    => $token,
        args     => {
            new_password => 'C0rrect0',
            platform     => 'dxtrade'

        }};
    $c->call_ok('trading_platform_password_change', $params)->has_no_system_error->has_no_error->result_is_deeply(1, 'New password successfully set');

    # Add dxtrade account

    $params = {
        language => 'EN',
        token    => $token,
        args     => {
            platform     => 'dxtrade',
            account_type => 'demo',
            market_type  => 'all',
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
            platform     => 'dxtrade'
        }};

    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->demo(1);
    $c->call_ok('trading_platform_password_change', $params)->has_no_system_error->has_error->error_code_is('DXServerSuspended', 'server suspended');
    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->demo(0);

    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->all(1);
    $c->call_ok('trading_platform_password_change', $params)->has_no_system_error->has_error->error_code_is('DXSuspended', 'all suspended');
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
        email    => $client->email,
        password => 'test'
    )->add_client($client);
    $client->account('USD');

    BOM::Config::Runtime->instance->app_config->system->dxtrade->enable_all_market_type->demo(1);

    my $params = {
        language => 'EN',
        token    => BOM::Platform::Token::API->new->create_token($client->loginid, 'test token'),
        args     => {
            platform     => 'dxtrade',
            account_type => 'demo',
            market_type  => 'all',
            password     => 'Test1234',
            currency     => 'USD',
        }};

    $c->call_ok('trading_platform_new_account', $params)->has_no_system_error->has_no_error;

    $params = {
        language => 'EN',
        args     => {
            verify_email => $user->email,
            type         => 'trading_platform_dxtrade_password_reset',
        }};

    my $result = $c->call_ok('verify_email', $params)->has_no_system_error->has_no_error->result_is_deeply({
            status => 1,
            stash  => {
                app_markup_percentage      => 0,
                valid_source               => 1,
                source_bypass_verification => 0,
                source_type                => 'official',
            },
        },
        'Verification code generated'
    );

    ok $verification_code, 'Got a verification code';

    $params = {
        language => 'EN',
        token    => BOM::Platform::Token::API->new->create_token($client->loginid, 'test token'),
        args     => {
            platform          => 'dxtrade',
            new_password      => 'C0rrect0',
            verification_code => $verification_code,
            platform          => 'dxtrade'
        }};

    $c->call_ok('trading_platform_password_reset', $params)->has_no_system_error->has_no_error->result_is_deeply(1, 'Password successfully reset');

    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->all(1);

    $params = {
        language => 'EN',
        args     => {
            verify_email => $user->email,
            type         => 'trading_platform_dxtrade_password_reset'
        }};

    $c->call_ok('verify_email', $params)->has_no_system_error->has_no_error;

    $params = {
        language => 'EN',
        token    => BOM::Platform::Token::API->new->create_token($client->loginid, 'test token'),
        args     => {
            platform          => 'dxtrade',
            new_password      => 'C0rrect1',
            verification_code => $verification_code,
        }};

    BOM::Config::Runtime->instance->app_config->system->dxtrade->suspend->all(1);
    $c->call_ok('trading_platform_password_reset', $params)->has_no_system_error->has_error->error_code_is('DXSuspended', 'all suspended');
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

    BOM::Config::Runtime->instance->app_config->system->dxtrade->enable_all_market_type->real(0);

    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            platform     => 'dxtrade',
            account_type => 'real',
            market_type  => 'all',
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

    # get back to financial
    $params->{args}->{market_type} = 'all';

    # Move to the U.K.
    $real->residence('gb');
    $real->save;
    # The U.K. is disabled
    $c->call_ok('trading_platform_new_account', $params)->has_no_system_error->has_error->error_code_is('InvalidAccount', 'the uk has been disabled')
        ->error_message_is('Sorry, account opening is unavailable.', 'Expected error message');

    # Move to Germany
    $real->residence('de');
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
        market_type => 'all',
        platform    => 'dxtrade',
        stash       => {
            app_markup_percentage      => '0',
            valid_source               => 1,
            source_bypass_verification => 0,
            source_type                => 'official',
        },
        display_balance       => '0.00',
        balance               => '0.00',
        landing_company_short => 'svg',
        account_id            => re('^DX.*$'),
        currency              => 'USD',
        account_type          => 'real',
        enabled               => 1,
        },
        'DXtrader account successfully created';

    $mock_lc->unmock_all;
    $mock_country->unmock_all;
    $mock_client->unmock_all;
};

subtest 'landing_company call' => sub {
    my %tests = (
        au => {},
        mt => {},
        jp => {},
        id => {all => 1},
    );

    for my $test (sort keys %tests) {
        my $result = $c->call_ok('landing_company', {args => {landing_company => $test}})->result;

        for my $type ('all') {
            is exists $result->{"dxtrade_${type}_company"}, exists $tests{$test}->{$type}, "$type availability for $test";
        }
    }
};

subtest 'trading_platform_available_accounts' => sub {
    $c->call_ok('trading_platform_available_accounts', {})
        ->has_no_system_error->has_error->error_code_is('TradingPlatformError', 'platform must be specified');

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR', residence => 'id'});

    BOM::User->create(
        email    => 'testme@test.com',
        password => 'test'
    )->add_client($client);
    $client->account('USD');
    my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

    # Try without a dx client

    my $params = {
        language => 'EN',
        token    => $token,
        args     => {platform => 'mt5'}};
    my $result = $c->call_ok('trading_platform_available_accounts', $params)->has_no_system_error->has_no_error->result;
    ok ref $result eq 'ARRAY', 'result is an array reference';

    my $expected_keys = [qw(market_type name requirements shortcode sub_account_type linkable_landing_companies product)];
    foreach my $account ($result->@*) {
        cmp_bag([keys %$account], $expected_keys, 'response of trading_platform_accounts is as expected');
    }

    my $jurisdiction = {
        bvi => {
            standard   => [qw/br/],
            high       => [],
            restricted => [qw/id ru/],
            revision   => 1,
        },
        vanuatu => {
            standard   => [qw/br/],
            high       => [],
            restricted => [qw/id/],
            revision   => 1,
        },
        labuan => {
            standard   => [qw/br/],
            high       => [],
            restricted => [qw/id/],
            revision   => 1,
        }};
    my $mock_config = Test::MockModule->new('BOM::Config::Compliance');
    $mock_config->redefine(
        get_risk_thresholds          => {},
        get_jurisdiction_risk_rating => sub { $jurisdiction });
    $result = $c->call_ok('trading_platform_available_accounts', $params)->has_no_system_error->has_no_error->result;

    is scalar(@{$result}), 3, 'got correct number of platforms';
    foreach my $account ($result->@*) {
        like $account->{shortcode}, qr/^svg$/, 'response of trading_platform_accounts is as expected';
    }
    $mock_config->unmock_all;
};

subtest 'disable derivez account creation api call' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR', residence => 'id'});

    BOM::User->create(
        email    => 'derivez_account_disable@test.com',
        password => 'test'
    )->add_client($client);
    $client->account('USD');

    $c->call_ok('trading_platform_new_account', {})->has_no_system_error->has_error->error_code_is('InvalidToken', 'must be logged in');

    my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            platform    => 'derivez',
            company     => 'svg',
            currency    => 'USD',
            market_type => 'all'
        }};

    my $result = $c->call_ok('trading_platform_new_account', $params)
        ->has_no_system_error->has_error->error_code_is('DerivEZUnavailable', 'derivez new account disable');
};

done_testing();
