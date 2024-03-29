use strict;
use warnings;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client;
use Test::More;
use Test::Fatal;
use Test::Deep;
use Test::MockModule;
use Test::Exception;
use Log::Any::Test;
use Log::Any qw($log);

use BOM::Rules::Engine;
use BOM::TradingPlatform;
use BOM::Config::Runtime;
use BOM::Config;
use Data::Dump 'pp';

subtest "cTrader Account Creation" => sub {
    my $ctconfig           = BOM::Config::Runtime->instance->app_config->system->ctrader;
    my $ctid               = 1001;
    my $loginid            = 100001;
    my $ctrader_config     = BOM::Config::ctrader_general_configurations();
    my $max_accounts_limit = $ctrader_config->{new_account}->{max_accounts_limit}->{real};

    my $mock_apidata = {
        ctid_create                 => sub { {userId => $ctid} },
        ctid_getuserid              => sub { {userId => $ctid} },
        ctradermanager_getgrouplist => sub { [{name => 'ctrader_all_svg_std_usd', groupId => 1}] },
        trader_create               => sub {
            {
                login                 => $loginid,
                groupName             => 'ctrader_all_svg_std_usd',
                registrationTimestamp => 123456,
                depositCurrency       => 'USD',
                balance               => 0,
                moneyDigits           => 2,
            }
        },
        trader_get => sub {
            {
                login           => $loginid,
                depositCurrency => 'USD',
                balance         => 0,
            }
        },
        tradermanager_gettraderlightlist => sub { [{traderId => $ctid, login => $loginid}] },
        ctid_linktrader                  => sub { {ctidTraderAccountId => $ctid} },
        tradermanager_deposit            => sub { {balanceHistoryId    => 1} },
    };

    my $mocked_ctrader = Test::MockModule->new('BOM::TradingPlatform::CTrader');
    $mocked_ctrader->redefine(
        call_api => sub {
            my ($self, %payload) = @_;
            return $mock_apidata->{$payload{method}}->();
        });

    # Mock set method to avoid account creation locking mechanism
    my $mocked_redis = Test::MockModule->new('RedisDB');
    $mocked_redis->mock('set', sub { return 'OK' });

    subtest "cTrader Create Account" => sub {
        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
        $client->email('ctraderaccount@test.com');
        my $user = BOM::User->create(
            email    => $client->email,
            password => 'test'
        );
        $user->add_client($client);
        $client->set_default_account('USD');
        $client->binary_user_id($user->id);
        $client->save;

        my %params = (
            account_type => "real",
            market_type  => "all",
            platform     => "ctrader"
        );

        my $ctrader = BOM::TradingPlatform->new(
            platform    => 'ctrader',
            client      => $client,
            user        => $user,
            rule_engine => BOM::Rules::Engine->new(client => $client));
        isa_ok($ctrader, 'BOM::TradingPlatform::CTrader');

        my $expected_response = {
            'landing_company_short' => 'svg',
            'balance'               => '0.00',
            'market_type'           => 'all',
            'display_balance'       => '0.00',
            'currency'              => 'USD',
            'login'                 => '100001',
            'account_id'            => 'CTR100001',
            'account_type'          => 'real',
            'platform'              => 'ctrader',
        };

        my $response = $ctrader->new_account(%params);
        cmp_deeply($response, $expected_response, 'Can create cTrader real account');

        $params{account_type}              = 'demo';
        $response                          = $ctrader->new_account(%params);
        $expected_response->{account_id}   = 'CTD100001';
        $expected_response->{account_type} = 'demo';
        cmp_deeply($response, $expected_response, 'Can create cTrader demo account');
        cmp_deeply(
            exception { $ctrader->new_account(%params) },
            {
                error_code => 'CTraderExistingAccountLimitExceeded',
                params     => ['demo', 1]
            },
            'Cannot create demo account more than 1'
        );

        $response = $ctrader->get_account_info('CTD100001');
        is $response->{account_id},   'CTD100001', 'get_account_info account id';
        is $response->{account_type}, 'demo',      'get_account_info account_type';
    };

    subtest "cTrader Create Account Errors" => sub {
        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
        $client->email('ctradernewaccounterrors@test.com');
        my $user = BOM::User->create(
            email    => $client->email,
            password => 'test'
        );
        $user->add_client($client);
        $client->set_default_account('USD');
        $client->binary_user_id($user->id);
        $client->residence('jp');
        $client->save;

        my %params = (
            account_type => "real",
            market_type  => "all",
            platform     => "ctrader"
        );

        my $ctrader = BOM::TradingPlatform->new(
            platform    => 'ctrader',
            client      => $client,
            user        => $user,
            rule_engine => BOM::Rules::Engine->new(client => $client));
        isa_ok($ctrader, 'BOM::TradingPlatform::CTrader');

        $ctconfig->suspend->all(0);
        $ctconfig->suspend->demo(0);
        $ctconfig->suspend->real(0);

        $ctconfig->suspend->all(1);
        cmp_deeply(exception { $ctrader->new_account(%params) }, {error_code => 'CTraderSuspended'}, 'Cannot create account when all suspended');
        $ctconfig->suspend->all(0);

        $ctconfig->suspend->real(1);
        cmp_deeply(
            exception { $ctrader->new_account(%params) },
            {error_code => 'CTraderServerSuspended'},
            'Cannot create real account when real suspended'
        );
        $ctconfig->suspend->real(0);

        $ctconfig->suspend->demo(1);
        $params{account_type} = 'demo';
        cmp_deeply(
            exception { $ctrader->new_account(%params) },
            {error_code => 'CTraderServerSuspended'},
            'Cannot create demo account when demo suspended'
        );
        $ctconfig->suspend->demo(0);
        $params{account_type} = 'real';

        $params{account_type} = 'unreal';
        cmp_deeply(
            exception { $ctrader->new_account(%params) },
            {error_code => 'CTraderInvalidAccountType'},
            'Cannot create cTrader with invalid account type'
        );
        $params{account_type} = 'real';

        cmp_deeply(
            exception { $ctrader->new_account(%params) },
            {
                error_code => 'TradingAccountNotAllowed',
                rule       => 'trading_account.should_match_landing_company',
                params     => ['cTrader']
            },
            'Cannot create cTrader for unsupported country- failed by rules'
        );
        $client->residence('id');

        $params{market_type} = 'unknownmarket';
        cmp_deeply(
            exception { $ctrader->new_account(%params) },
            {error_code => 'CTraderInvalidMarketType'},
            'Cannot create cTrader with invalid account type'
        );
        $params{market_type} = 'all';

        $mock_apidata->{ctradermanager_getgrouplist} = sub { [{name => 'ctrader_all_svg_std_myr', groupId => 1}] };
        cmp_deeply(
            exception { $ctrader->new_account(%params) },
            {error_code => 'CTraderInvalidGroup'},
            'Cannot create cTrader with invalid group type'
        );
        $mock_apidata->{ctradermanager_getgrouplist} = sub { [{name => 'ctrader_all_svg_std_usd', groupId => 1}] };

        $mock_apidata->{tradermanager_gettraderlightlist} = sub { [{traderId => 1001, login => 999991}] };
        cmp_deeply(
            exception { $ctrader->new_account(%params) },
            {error_code => 'CTraderAccountCreateFailed'},
            'Stop cTrader account creation if traderId not found'
        );
        $mock_apidata->{tradermanager_gettraderlightlist} = sub { [{traderId => $ctid, login => $loginid}] };

        $mock_apidata->{ctid_create}    = sub { {} };
        $mock_apidata->{ctid_getuserid} = sub { {} };
        cmp_deeply(exception { $ctrader->new_account(%params) }, {error_code => 'CTIDGetFailed'}, 'Stop cTrader account if CTID cannot be retrieved');

        $mocked_ctrader->mock(
            '_add_ctid_userid',
            sub {
                return {error => "dummy error"};
            });

        cmp_deeply(
            exception { $ctrader->new_account(%params) },
            {error_code => 'CTIDGetFailed'},
            'Stop cTrader account if CTID cannot be saved to DB'
        );
        $mocked_ctrader->unmock('_add_ctid_userid');

        $mock_apidata->{ctid_linktrader} = {};
        $ctid++;
        $loginid++;
        $mock_apidata->{ctid_create}     = $mock_apidata->{ctid_getuserid} = sub { {userId => $ctid} };
        $mock_apidata->{ctid_linktrader} = sub { {} };
        cmp_deeply(
            exception { $ctrader->new_account(%params) },
            {error_code => 'CTraderAccountLinkFailed'},
            'Stop cTrader account if CTID cannot be linked'
        );
        $mock_apidata->{ctid_linktrader} = sub { {ctidTraderAccountId => $ctid} };
    };

    subtest 'wallets' => sub {
        my (%clients, %platforms, %accs);
        my ($user, $wallet_factory) = BOM::Test::Helper::Client::create_wallet_factory;
        $clients{legacy} = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR', email => $user->email});
        $clients{legacy}->account('USD');
        $user->add_client($clients{legacy});
        ($clients{real})    = $wallet_factory->('CRW', 'doughflow', 'USD');
        ($clients{virtual}) = $wallet_factory->('VRW', 'virtual',   'USD');

        for my $c (sort keys %clients) {
            $platforms{$c} = BOM::TradingPlatform->new(
                platform    => 'ctrader',
                client      => $clients{$c},
                user        => $user,
                rule_engine => BOM::Rules::Engine->new(
                    client => $clients{$c},
                    user   => $user
                ));

            $ctid++;
            $loginid++;
            my $account_type = $c eq 'virtual' ? 'demo' : 'real';
            $accs{$c} = $platforms{$c}->new_account(
                account_type => $account_type,
                market_type  => 'all'
            );
            ok $accs{$c}->{account_id}, "create $c account ok";
        }

        for my $c1 (sort keys %clients) {
            for my $c2 (sort keys %clients) {
                is $platforms{$c1}->get_account_info($accs{$c2}->{account_id})->{account_id}, $accs{$c2}->{account_id},
                    "$c1 can see $c2 account in get_account_info()";
            }

            cmp_deeply(
                [map { $_->{account_id} } $platforms{$c1}->get_accounts->@*],
                [$accs{$c1}->{account_id}],
                "$c1 only sees $c1 account in get_accounts"
            );

        }
    };

    subtest "each client can create up to ${max_accounts_limit} cTrader real accounts" => sub {
        # Create a new client and user
        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
        $client->email('ctraderaccount_5@test.com');
        my $user = BOM::User->create(
            email    => $client->email,
            password => 'test'
        );
        $user->add_client($client);
        $client->set_default_account('USD');
        $client->save;

        my %params = (
            account_type => "real",
            market_type  => "all",
            platform     => "ctrader"
        );

        my $ctrader = BOM::TradingPlatform->new(
            platform    => 'ctrader',
            client      => $client,
            user        => $user,
            rule_engine => BOM::Rules::Engine->new(client => $client));
        isa_ok($ctrader, 'BOM::TradingPlatform::CTrader');

        for my $i (1 .. $max_accounts_limit) {
            $ctid = 2001;
            $loginid++;
            my $account = $ctrader->new_account(%params);

            ok $account->{account_id}, "Created cTrader real account $i";
        }

        # Attempt to create one more account (should fail)
        cmp_deeply(
            exception { $ctrader->new_account(%params) },
            {
                error_code => 'CTraderExistingAccountLimitExceeded',
                params     => ['real', $max_accounts_limit]
            },
            "Cannot create more than $max_accounts_limit cTrader real accounts"
        );
    };

    subtest 'account creation locking mechanism' => sub {
        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
        $client->email('account_creation_lock@test.com');
        my $user = BOM::User->create(
            email    => $client->email,
            password => 'test'
        );
        $user->add_client($client);
        $client->set_default_account('USD');
        $client->save;

        my %params = (
            account_type => "real",
            market_type  => "all",
            platform     => "ctrader"
        );

        my $ctrader = BOM::TradingPlatform->new(
            platform    => 'ctrader',
            client      => $client,
            user        => $user,
            rule_engine => BOM::Rules::Engine->new(client => $client));
        isa_ok($ctrader, 'BOM::TradingPlatform::CTrader');

        # Mock the 'set' method to simulate the lock
        $mocked_redis->mock('set', sub { return undef });

        cmp_deeply(
            exception { $ctrader->new_account(%params) },
            {error_code => 'CTraderAccountCreationInProgress'},
            "Cannot create cTrader real accounts when lock is present"
        );
    };

    $mocked_redis->unmock_all();
};

subtest "cTrader Deleted Inactive Demo Account" => sub {
    my $ctconfig = BOM::Config::Runtime->instance->app_config->system->ctrader;
    my $ctid     = 1006;
    my $loginid  = 100006;

    my $mock_apidata = {
        ctid_create                 => sub { {userId => $ctid} },
        ctid_getuserid              => sub { {userId => $ctid} },
        ctradermanager_getgrouplist => sub { [{name => 'ctrader_all_svg_std_usd', groupId => 1}] },
        trader_create               => sub {
            {
                login                 => $loginid,
                groupName             => 'ctrader_all_svg_std_usd',
                registrationTimestamp => 123456,
                depositCurrency       => 'USD',
                balance               => 0,
                moneyDigits           => 2,
            }
        },
        trader_get => sub {
            {
                login           => $loginid,
                depositCurrency => 'USD',
                balance         => 0,
            }
        },
        tradermanager_gettraderlightlist => sub { [{traderId => $ctid, login => $loginid}] },
        ctid_linktrader                  => sub { {ctidTraderAccountId => $ctid} },
        tradermanager_deposit            => sub { {balanceHistoryId    => 1} },
    };

    my $mocked_ctrader = Test::MockModule->new('BOM::TradingPlatform::CTrader');
    $mocked_ctrader->redefine(
        call_api => sub {
            my ($self, %payload) = @_;
            return $mock_apidata->{$payload{method}}->();
        });

    subtest "cTrader Demo Deleted Account" => sub {
        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
        $client->email('ctraderdemodeletaccount@test.com');
        my $user = BOM::User->create(
            email    => $client->email,
            password => 'test'
        );
        $user->add_client($client);
        $client->set_default_account('USD');
        $client->binary_user_id($user->id);
        $client->save;

        my %params = (
            account_type => "demo",
            market_type  => "all",
            platform     => "ctrader"
        );

        my $ctrader = BOM::TradingPlatform->new(
            platform    => 'ctrader',
            client      => $client,
            user        => $user,
            rule_engine => BOM::Rules::Engine->new(client => $client));
        isa_ok($ctrader, 'BOM::TradingPlatform::CTrader');

        my $expected_response = {
            'landing_company_short' => 'svg',
            'balance'               => '0.00',
            'market_type'           => 'all',
            'display_balance'       => '0.00',
            'currency'              => 'USD',
            'login'                 => '100006',
            'account_id'            => 'CTD100006',
            'account_type'          => 'demo',
            'platform'              => 'ctrader',
        };

        my $response = $ctrader->new_account(%params);
        cmp_deeply($response, $expected_response, 'Can create cTrader demo account');

        $response = $ctrader->get_account_info('CTD100006');
        is $response->{account_id},   'CTD100006', 'get_account_info account id';
        is $response->{account_type}, 'demo',      'get_account_info account_type';

        my @local_accounts = $ctrader->local_accounts();
        is $local_accounts[0]->{status}, undef, 'Account status is undefined';

        my $resp = {
            content => {
                error => {
                    description => "sample description",
                    errorCode   => "TRADER_NOT_FOUND"
                }}};

        my %args = (
            method  => 'trader_get',
            server  => 'real',
            payload => {loginid => $loginid});

        dies_ok { $ctrader->handle_api_error($resp, undef, %args) } 'handle_api_error method throws an exception';
        @local_accounts = $ctrader->local_accounts();
        is scalar @local_accounts,       1,     'Local accounts still have 1 account';
        is $local_accounts[0]->{status}, undef, 'Account status is still undefined if it fails for real server call';

        my $login_details = $client->user->loginid_details;
        is $login_details->{'CTD100006'}->{status}, undef, 'Demo account status is archived';

        $args{server} = 'demo';
        dies_ok { $ctrader->handle_api_error($resp, undef, %args) } 'handle_api_error method throws an exception';
        @local_accounts = $ctrader->local_accounts();
        is scalar @local_accounts, 0, 'Local accounts now return 0 account due to demo account is archived';

        $login_details = $client->user->loginid_details;
        is $login_details->{'CTD100006'}->{status}, 'archived', 'Demo account status is archived';

        $loginid++;

        $expected_response->{account_id} = 'CTD100007';
        $expected_response->{login}      = '100007';
        $response                        = $ctrader->new_account(%params);
        cmp_deeply($response, $expected_response, 'Can create second cTrader demo account after old account gets archived');
    };
};

subtest "cTrader Available Account" => sub {
    my $ctid               = 1008;
    my $loginid            = 100008;
    my $ctrader_config     = BOM::Config::ctrader_general_configurations();
    my $max_accounts_limit = $ctrader_config->{new_account}->{max_accounts_limit}->{real};

    my $mock_apidata = {
        ctid_create                 => sub { {userId => $ctid} },
        ctid_getuserid              => sub { {userId => $ctid} },
        ctradermanager_getgrouplist => sub { [{name => 'ctrader_all_svg_std_usd', groupId => 1}] },
        trader_create               => sub {
            {
                login                 => $loginid,
                groupName             => 'ctrader_all_svg_std_usd',
                registrationTimestamp => 123456,
                depositCurrency       => 'USD',
                balance               => 0,
                moneyDigits           => 2,
            }
        },
        trader_get => sub {
            {
                login           => $loginid,
                depositCurrency => 'USD',
                balance         => 0,
            }
        },
        tradermanager_gettraderlightlist => sub { [{traderId => $ctid, login => $loginid}] },
        ctid_linktrader                  => sub { {ctidTraderAccountId => $ctid} },
        tradermanager_deposit            => sub { {balanceHistoryId    => 1} },
    };

    my $mocked_ctrader = Test::MockModule->new('BOM::TradingPlatform::CTrader');
    $mocked_ctrader->redefine(
        call_api => sub {
            my ($self, %payload) = @_;
            return $mock_apidata->{$payload{method}}->();
        });

    # Mock set method to avoid account creation locking mechanism
    my $mocked_redis = Test::MockModule->new('RedisDB');
    $mocked_redis->mock('set', sub { return 'OK' });

    subtest "cTrader Available Accounts Supported Country" => sub {
        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
        $client->email('ctraderaccountsupportedcountry@test.com');
        my $user = BOM::User->create(
            email    => $client->email,
            password => 'test'
        )->add_client($client);
        $client->set_default_account('USD');
        $client->binary_user_id($user->id);
        $client->residence('id');
        $client->save;

        my $ctrader = BOM::TradingPlatform->new(
            platform    => 'ctrader',
            client      => $client,
            user        => $user,
            rule_engine => BOM::Rules::Engine->new(client => $client));
        isa_ok($ctrader, 'BOM::TradingPlatform::CTrader');

        my $expected_response = [{
                linkable_landing_companies => ["svg"],
                market_type                => "all",
                name                       => "Deriv (SVG) LLC",
                requirements               => {
                    signup     => ["first_name",   "last_name", "residence", "date_of_birth"],
                    withdrawal => ["address_city", "address_line_1"],
                },
                shortcode        => "svg",
                sub_account_type => "standard",
                available_count  => 1,
                max_count        => 1,
            },
        ];

        my $response = $ctrader->available_accounts();
        cmp_deeply($response, $expected_response, 'Can get cTrader available accounts');

        my $expected_new_account_response = {
            'landing_company_short' => 'svg',
            'balance'               => '0.00',
            'market_type'           => 'all',
            'display_balance'       => '0.00',
            'currency'              => 'USD',
            'login'                 => '100008',
            'account_id'            => 'CTR100008',
            'account_type'          => 'real',
            'platform'              => 'ctrader',
        };

        my %params = (
            account_type => "real",
            market_type  => "all",
            platform     => "ctrader"
        );

        $response = $ctrader->new_account(%params);
        cmp_deeply($response, $expected_new_account_response, 'Can create cTrader real account');

        $expected_response->[0]->{available_count} = 0;
        $response = $ctrader->available_accounts();
        cmp_deeply($response, $expected_response, 'Can get cTrader available accounts');
    };

    subtest "cTrader Available Accounts Un-Supported Country" => sub {
        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
        $client->email('ctraderaccountunsupportedcountry@test.com');
        my $user = BOM::User->create(
            email    => $client->email,
            password => 'test'
        )->add_client($client);
        $client->set_default_account('USD');
        $client->binary_user_id($user->id);
        $client->residence('ae');
        $client->save;

        my $ctrader = BOM::TradingPlatform->new(
            platform    => 'ctrader',
            client      => $client,
            rule_engine => BOM::Rules::Engine->new(client => $client));
        isa_ok($ctrader, 'BOM::TradingPlatform::CTrader');

        my $expected_response = [];

        my $response = $ctrader->available_accounts();
        cmp_deeply($response, $expected_response, 'Get nothing from cTrader available accounts');
    };

    $mocked_redis->unmock_all();
    $mocked_ctrader->unmock_all();
};

subtest "Error Email Filtering Test" => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    $client->email('ctradererrorfilter@test.com');
    my $user = BOM::User->create(
        email    => $client->email,
        password => 'test'
    )->add_client($client);
    $client->set_default_account('USD');
    $client->binary_user_id($user->id);
    $client->save;

    my $ctrader = BOM::TradingPlatform->new(
        platform    => 'ctrader',
        client      => $client,
        rule_engine => BOM::Rules::Engine->new(client => $client));
    isa_ok($ctrader, 'BOM::TradingPlatform::CTrader');

    my $resp = [{
            error => {
                description => "sample description john.doe\@example.com.au",
                errorCode   => "CH_EMAIL_ALREADY_EXISTS"
            }
        },
        "Bad Request",
        "400"
    ];

    my %args = (
        server  => 'demo',
        method  => 'test_method',
        payload => {
                  email => "ww\@ww"
                . " john.doe!#$%&’*+-/=?^_`{|}~test\@example.com"
                . " john.doe!#$%&’*+-/=?^_`{|}~test\@example123.com321"
                . " dsadanonymous.fm\@my.sub.my-secret-organisation.org"
                . " simple\@example.com"
                . " very.common\@example.com"
                . " abc\@example.co.uk"
                . " disposable.style.email.with+symbol\@example.com"
                . " other.email-with-hyphen\@example.com"
                . " fully-qualified-domain\@example.com"
                . " user.name+tag+sorting\@example.com"
                . " example-indeed\@strange-example.com"
                . " example-indeed\@strange-example.inininini"
                . " everything123.!#$%&’*+/=?^_`{|}~-\@test.com"
                . " 1234567890123456789012345678901234567890123456789012345678901234+x\@example.com @"
        });

    dies_ok { $ctrader->handle_api_error($resp, 'CTraderGeneral', %args) } 'handle_api_error method throws an exception';
    my $exception = $@;
    is($exception->{error_code}, 'CTraderGeneral', 'Exception has the expected error code');

    my $expected_msg_description = qq('description' => 'sample description *****');
    my $expected_msg_email       = qq('email' => 'ww\@ww ***** ***** ***** ***** ***** ***** ***** ***** ***** ***** ***** ***** ***** ***** @');

    my $msgs = $log->msgs;
    is($msgs->[2]->{level},    'warning',                       'Log message has the expected level');
    is($msgs->[2]->{category}, 'BOM::TradingPlatform::CTrader', 'Log message has the expected category');
    my $expected_msg_regex_description = quotemeta $expected_msg_description;
    my $expected_msg_regex_email       = quotemeta $expected_msg_email;
    like($msgs->[2]->{message}, qr/$expected_msg_regex_description/, 'Log message contains the expected error message');
    like($msgs->[2]->{message}, qr/$expected_msg_regex_email/,       'Log message contains the expected error message');
};

done_testing();
