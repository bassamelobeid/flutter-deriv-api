use strict;
use warnings;
use Test::More;
use Test::Fatal;
use Test::Deep;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::TradingPlatform;
use BOM::Test::Helper::Client;
use BOM::Test::Helper::ExchangeRates qw(populate_exchange_rates);
use BOM::Config::Runtime;
use BOM::Rules::Engine;
my $mock_fees = Test::MockModule->new('BOM::Config::CurrencyConfig', no_auto => 1);
$mock_fees->mock(
    transfer_between_accounts_fees => sub {
        return {
            'USD' => {
                'EUR' => 20,
                'BTC' => 10
            },
            'EUR' => {'USD' => 5},
        };
    });

my $mock_trading_platform = Test::MockModule->new('BOM::TradingPlatform', no_auto => 1);
$mock_trading_platform->mock(
    name => sub {
        return 'dxtrade';
    });

subtest 'common' => sub {

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'test@binary.com'
    });

    my $user = BOM::User->create(
        email    => $client->email,
        password => 'test'
    );
    $client->account('USD');
    BOM::Test::Helper::Client::top_up($client, $client->account->currency_code, 100);
    $user->add_client($client);

    $user->add_loginid('DXR001', 'dxtrade', 'real', 'USD');

    my $platform = BOM::TradingPlatform->new_base(
        client      => $client,
        rule_engine => BOM::Rules::Engine->new(
            client => $client,
            user   => $user
        ));

    my %args = (
        action               => 'deposit',
        amount               => 1,
        amount_currency      => 'USD',
        platform_currency    => 'USD',
        account_type         => 'real',
        from_account         => $client->loginid,
        to_account           => 'DXR001',
        landing_company_from => 'svg',
        landing_company_to   => 'svg',
    );

    is exception { $platform->validate_transfer(%args) }, undef, 'no error initially';

    # make any rule from following rule actions fail to make sure that action is triggered
    # TODO: make sure each action contains expected rules - we are missing coverage for this everywhere, this should probably be done in bom-rules
    cmp_deeply(
        exception { $platform->validate_transfer(%args, from_account => 'DXR001') },
        {
            error_code => 'SameAccountNotAllowed',
            rule       => 'transfers.same_account_not_allowed'
        },
        'account_transfer rule action is triggered'
    );

    cmp_deeply(
        exception { $platform->validate_transfer(%args, landing_company_from => 'x') },
        {
            error_code => 'DifferentLandingCompanies',
            rule       => 'transfers.landing_companies_are_the_same'
        },
        'trading_account_deposit rule action is triggered'
    );

    cmp_deeply(
        exception { $platform->validate_transfer(%args, action => 'withdrawal', landing_company_from => 'x') },
        {
            error_code => 'DifferentLandingCompanies',
            rule       => 'transfers.landing_companies_are_the_same'
        },
        'trading_account_withdrawal rule action is triggered'
    );

    BOM::Config::Runtime->instance->app_config->system->suspend->payments(1);
    cmp_deeply(exception { $platform->validate_transfer(%args) }, {error_code => 'PlatformTransferSuspended'}, 'payments suspended',);
    BOM::Config::Runtime->instance->app_config->system->suspend->payments(0);

    BOM::Config::Runtime->instance->app_config->system->suspend->transfer_between_accounts(1);
    cmp_deeply(exception { $platform->validate_transfer(%args) }, {error_code => 'PlatformTransferSuspended'},
        'transfer between accounts suspended',);
    BOM::Config::Runtime->instance->app_config->system->suspend->transfer_between_accounts(0);

    $client->status->set('transfers_blocked', 'system', 'test');
    cmp_deeply(exception { $platform->validate_transfer(%args) }, {error_code => 'PlatformTransferBlocked'}, 'client has transfers_blocked status',);
    $client->status->clear_transfers_blocked;

    BOM::Config::Runtime->instance->app_config->system->suspend->transfer_currencies(['USD', 'EUR']);
    cmp_deeply(
        exception { $platform->validate_transfer(%args) },
        {
            error_code => 'PlatformTransferCurrencySuspended',
            params     => ['USD']
        },
        'transfer currency suspended',
    );
    BOM::Config::Runtime->instance->app_config->system->suspend->transfer_currencies([]);
};

subtest 'deposit' => sub {

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'deposit2@test.com'
    });
    $client->account('USD');

    my $user = BOM::User->create(
        email    => $client->email,
        password => 'test'
    );

    $user->add_client($client);
    $user->add_loginid('DXR002', 'dxtrade', 'real', 'USD');

    my $platform = BOM::TradingPlatform->new_base(
        client      => $client,
        rule_engine => BOM::Rules::Engine->new(
            client => $client,
            user   => $user
        ),
    );

    my %args = (
        action               => 'deposit',
        amount               => 10,
        amount_currency      => 'USD',
        platform_currency    => 'USD',
        account_type         => 'real',
        from_account         => $client->loginid,
        to_account           => 'DXR002',
        landing_company_from => 'svg',
        landing_company_to   => 'svg',
    );

    cmp_deeply(
        exception {
            $platform->validate_transfer(%args)
        },
        {
            error_code => 'PlatformTransferError',
            params     => [re('account has zero balance')]
        },
        'zero balance'
    );

    BOM::Test::Helper::Client::top_up($client, $client->account->currency_code, 5);

    cmp_deeply(
        exception {
            $platform->validate_transfer(%args)
        },
        {
            error_code => 'PlatformTransferError',
            params     => [re('exceeds client balance')]
        },
        'insufficient balance'
    );

    BOM::Test::Helper::Client::top_up($client, $client->account->currency_code, 5);

    cmp_deeply(
        $platform->validate_transfer(%args),
        {
            recv_amount               => num(10),
            fee_calculated_by_percent => num(0),
            fees                      => num(0),
            fees_percent              => num(0),
            min_fee                   => num(0),
            fees_in_client_currency   => undef,
        },
        'same currency'
    );

    cmp_deeply(
        exception {
            $platform->validate_transfer(%args, platform_currency => 'EUR')
        },
        {error_code => 'PlatformTransferTemporarilyUnavailable'},
        'no exchange rate'
    );

    populate_exchange_rates({EUR => 2});

    my $app_config = BOM::Config::Runtime->instance->app_config();
    $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());
    $app_config->set({'payments.transfer_between_accounts.minimum.dxtrade' => '{"default":{"currency":"USD","amount":100}}'});
    $app_config->set({'payments.transfer_between_accounts.maximum.dxtrade' => '{"default":{"currency":"USD","amount":1000}}'});

    cmp_deeply(
        exception {
            $platform->validate_transfer(%args, platform_currency => 'EUR')
        },
        {
            error_code => 'InvalidMinAmount',
            params     => ['100.00', 'USD'],
            rule       => 'transfers.limits',
        },
        'Minimum limit reached'
    );

    $app_config->set({'payments.transfer_between_accounts.minimum.dxtrade' => '{"default":{"currency":"USD","amount":1}}'});
    $app_config->set({'payments.transfer_between_accounts.maximum.dxtrade' => '{"default":{"currency":"USD","amount":5}}'});

    cmp_deeply(
        exception {
            $platform->validate_transfer(%args, platform_currency => 'EUR')
        },
        {
            error_code => 'InvalidMaxAmount',
            params     => ['5.00', 'USD'],
            rule       => 'transfers.limits',
        },
        'Maximum limit reached'
    );
    $app_config->set({'payments.transfer_between_accounts.maximum.dxtrade' => '{"default":{"currency":"USD","amount":100}}'});

    cmp_deeply(
        $platform->validate_transfer(%args, platform_currency => 'EUR'),
        {
            recv_amount               => num(4),
            fee_calculated_by_percent => num(2),
            fees                      => num(2),
            fees_percent              => num(20),
            min_fee                   => num(0.01),
            fees_in_client_currency   => undef,
        },
        'currency conversion with fees'
    );

};

subtest 'withdrawal' => sub {

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'withdrawal@test.com'
    });
    $client->account('USD');

    my $user = BOM::User->create(
        email    => $client->email,
        password => 'test'
    );
    $user->add_client($client);
    $user->add_loginid('DXR003', 'dxtrade', 'real', 'USD');

    my $platform = BOM::TradingPlatform->new_base(
        client      => $client,
        rule_engine => BOM::Rules::Engine->new(
            client => $client,
            user   => $user
        ));

    my %args = (
        action               => 'withdrawal',
        amount               => 10,
        amount_currency      => 'USD',
        platform_currency    => 'USD',
        account_type         => 'real',
        from_account         => 'DXR003',
        to_account           => $client->loginid,
        landing_company_from => 'svg',
        landing_company_to   => 'svg',
    );

    cmp_deeply(
        $platform->validate_transfer(%args),
        {
            recv_amount               => num(10),
            fee_calculated_by_percent => num(0),
            fees                      => num(0),
            fees_percent              => num(0),
            min_fee                   => num(0),
            fees_in_client_currency   => num(0),
        },
        'same currency'
    );

    cmp_deeply(
        $platform->validate_transfer(%args, platform_currency => 'EUR'),
        {
            recv_amount               => num(19),
            fee_calculated_by_percent => num(0.5),
            fees                      => num(0.5),
            fees_percent              => num(5),
            min_fee                   => num(0.01),
            fees_in_client_currency   => num(1),
        },
        'currency conversion with fees'
    );

    # crypto to fiat
    my $client_btc = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'withdrawal@test.com'
    });
    $client_btc->account('BTC');
    populate_exchange_rates({BTC => 10000});
    $user->add_client($client_btc);

    my $platform_btc = BOM::TradingPlatform->new_base(
        client      => $client_btc,
        rule_engine => BOM::Rules::Engine->new(
            client => $client_btc,
            user   => $user
        ));

    $args{to_account} = $client_btc->loginid;

    cmp_deeply(
        exception { $platform_btc->validate_transfer(%args, amount => 101) },
        {
            error_code => 'InvalidMaxAmount',
            params     => ['100.00', 'USD'],
            rule       => 'transfers.limits',
        },
        'Correct max limit for USD withdrawal from BTC account',
    );

    cmp_deeply(
        $platform_btc->validate_transfer(%args, amount => 100),
        {
            fee_calculated_by_percent => '10',
            fees                      => 10,
            fees_in_client_currency   => '0.00100000',
            fees_percent              => 10,
            min_fee                   => '0.01',
            recv_amount               => '0.00900000'
        },
        'currency conversion with fees'
    );
};

done_testing();
