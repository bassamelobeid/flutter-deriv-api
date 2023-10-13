use strict;
use warnings;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client;
use Test::More;
use Test::Fatal;
use Test::Deep;
use Test::MockModule;

use BOM::Rules::Engine;
use BOM::TradingPlatform;
use BOM::Config::Runtime;
use Data::Dump 'pp';

subtest "cTrader Account Creation" => sub {
    my $ctconfig       = BOM::Config::Runtime->instance->app_config->system->ctrader;
    my $mocked_ctrader = Test::MockModule->new('BOM::TradingPlatform::CTrader');
    my $mock_apidata   = {
        ctid_create                 => {userId => 1001},
        ctid_getuserid              => {userId => 1001},
        ctradermanager_getgrouplist => [{name => 'ctrader_all_svg_std_usd', groupId => 1}],
        trader_create               => {
            login                 => 100001,
            groupName             => 'ctrader_all_svg_std_usd',
            registrationTimestamp => 123456,
            depositCurrency       => 'USD',
            balance               => 0,
            moneyDigits           => 2
        },
        tradermanager_gettraderlightlist => [{traderId => 1001, login => 100001}],
        ctid_linktrader                  => {ctidTraderAccountId => 1001},
        tradermanager_deposit            => {balanceHistoryId    => 1}};

    my %ctrader_mock = (
        call_api => sub {
            $mocked_ctrader->mock(
                'call_api',
                shift // sub {
                    my ($self, %payload) = @_;
                    return $mock_apidata->{$payload{method}};
                });
        },
    );

    $ctrader_mock{call_api}->();

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
        cmp_deeply(
            exception { $ctrader->new_account(%params) },
            {error_code => 'CTraderExistingActiveAccount'},
            'Cannot create duplicate real account'
        );

        $params{account_type}              = 'demo';
        $response                          = $ctrader->new_account(%params);
        $expected_response->{account_id}   = 'CTD100001';
        $expected_response->{account_type} = 'demo';
        cmp_deeply($response, $expected_response, 'Can create cTrader demo account');
        cmp_deeply(
            exception { $ctrader->new_account(%params) },
            {error_code => 'CTraderExistingActiveAccount'},
            'Cannot create duplicate demo account'
        );

        $response = $ctrader->get_account_info('CTD100001');
        is $response->{account_id},   'CTD100001', 'get_account_info account id';
        is $response->{account_type}, 'demo',      'get_account_info account id';
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

        $mock_apidata->{ctradermanager_getgrouplist} = [{name => 'ctrader_all_svg_std_myr', groupId => 1}];
        cmp_deeply(
            exception { $ctrader->new_account(%params) },
            {error_code => 'CTraderInvalidGroup'},
            'Cannot create cTrader with invalid group type'
        );
        $mock_apidata->{ctradermanager_getgrouplist} = [{name => 'ctrader_all_svg_std_usd', groupId => 1}];

        $mock_apidata->{tradermanager_gettraderlightlist} = [{traderId => 1001, login => 999991}];
        cmp_deeply(
            exception { $ctrader->new_account(%params) },
            {error_code => 'CTraderAccountCreateFailed'},
            'Stop cTrader account creation if traderId not found'
        );
        $mock_apidata->{tradermanager_gettraderlightlist} = [{traderId => 1001, login => 100001}];

        $mock_apidata->{ctid_create}    = {};
        $mock_apidata->{ctid_getuserid} = {};
        cmp_deeply(exception { $ctrader->new_account(%params) }, {error_code => 'CTIDGetFailed'}, 'Stop cTrader account if CTID cannot be retrieved');
        $mock_apidata->{ctid_create}    = {userId => 1002};
        $mock_apidata->{ctid_getuserid} = {userId => 1002};

        $mock_apidata->{ctid_linktrader} = {};
        cmp_deeply(
            exception { $ctrader->new_account(%params) },
            {error_code => 'CTraderAccountLinkFailed'},
            'Stop cTrader account if CTID cannot be linked'
        );
        $mock_apidata->{ctid_linktrader} = {ctidTraderAccountId => 1001};
    };
};

subtest "cTrader Available Account" => sub {
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
            },
        ];

        my $response = $ctrader->available_accounts();
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
};

#Unsupported Country adhoc test
#Group to group id adhoc test

done_testing();
