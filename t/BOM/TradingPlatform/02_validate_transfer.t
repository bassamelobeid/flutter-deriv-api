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

    for my $action ('deposit', 'withdrawal') {
        my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'VRTC',
            email       => $action . '+testvr@binary.com'
        });
        my $client_real = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
            email       => $action . '+test@binary.com'
        });
        # todo: wallet tests

        my $user = BOM::User->create(
            email    => $client_real->email,
            password => 'test'
        );

        $client_vr->account('USD');
        $client_real->account('USD');
        $user->add_client($client_vr);
        $user->add_client($client_real);

        my $dxtrader_vr = BOM::TradingPlatform->new_base(
            client      => $client_vr,
            rule_engine => BOM::Rules::Engine->new(client => $client_vr));
        my $dxtrader_real = BOM::TradingPlatform->new_base(
            client      => $client_real,
            rule_engine => BOM::Rules::Engine->new(client => $client_real));

        BOM::Config::Runtime->instance->app_config->system->suspend->payments(1);

        cmp_deeply(
            exception {
                $dxtrader_real->validate_transfer(
                    action               => $action,
                    amount               => 10,
                    platform_currency    => 'USD',
                    account_type         => 'real',
                    landing_company_from => 'svg',
                    landing_company_to   => 'svg',
                );
            },
            {error_code => 'PlatformTransferSuspended'},
            "payments suspended for $action"
        );
        BOM::Config::Runtime->instance->app_config->system->suspend->payments(0);

        BOM::Config::Runtime->instance->app_config->system->suspend->transfer_between_accounts(1);
        cmp_deeply(
            exception {
                $dxtrader_real->validate_transfer(
                    action               => $action,
                    amount               => 10,
                    platform_currency    => 'USD',
                    account_type         => 'real',
                    landing_company_from => 'svg',
                    landing_company_to   => 'svg',
                )
            },
            {error_code => 'PlatformTransferSuspended'},
            "transfer between accounts suspended for $action"
        );
        BOM::Config::Runtime->instance->app_config->system->suspend->transfer_between_accounts(0);

        $client_real->status->set('transfers_blocked', 'system', 'test');
        cmp_deeply(
            exception {
                $dxtrader_real->validate_transfer(
                    action               => $action,
                    amount               => 10,
                    platform_currency    => 'USD',
                    account_type         => 'real',
                    landing_company_from => 'svg',
                    landing_company_to   => 'svg',
                )
            },
            {error_code => 'PlatformTransferBlocked'},
            "$action: client has transfers_blocked status"
        );
        $client_real->status->clear_transfers_blocked;

        cmp_deeply(
            exception {
                $dxtrader_vr->validate_transfer(
                    action               => $action,
                    amount               => 10,
                    platform_currency    => 'USD',
                    account_type         => 'real',
                    landing_company_from => 'svg',
                    landing_company_to   => 'svg',
                )
            },
            {error_code => 'PlatformTransferNoVirtual'},
            "vr client cannot $action on real"
        );

        cmp_deeply(
            exception {
                $dxtrader_vr->validate_transfer(
                    action            => $action,
                    amount            => 10,
                    platform_currency => 'USD',
                    account_type      => 'demo',
                )
            },
            {error_code => 'PlatformTransferNoVirtual'},
            "demo client cannot $action on demo"
        );

        cmp_deeply(
            exception {
                $dxtrader_real->validate_transfer(
                    action            => $action,
                    amount            => 10,
                    platform_currency => 'USD',
                    account_type      => 'demo'
                )
            },
            {error_code => 'PlatformTransferNoVirtual'},
            "real client cannot $action on demo"
        );

        BOM::Config::Runtime->instance->app_config->system->suspend->transfer_currencies(['USD', 'EUR']);
        cmp_deeply(
            exception {
                $dxtrader_real->validate_transfer(
                    action               => $action,
                    amount               => 10,
                    platform_currency    => 'USD',
                    account_type         => 'real',
                    landing_company_from => 'svg',
                    landing_company_to   => 'svg',
                )
            },
            {
                error_code     => 'PlatformTransferCurrencySuspended',
                message_params => ['USD']
            },
            "$action: deriv transfer currency suspended"
        );

        BOM::Config::Runtime->instance->app_config->system->suspend->transfer_currencies([]);

        # todo: wallet tests
    }

};

subtest 'deposit' => sub {

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'deposit2@test.com'
    });
    $client->account('USD');
    BOM::User->create(
        email    => $client->email,
        password => 'test'
    )->add_client($client);
    my $dxtrader = BOM::TradingPlatform->new_base(
        client      => $client,
        rule_engine => BOM::Rules::Engine->new(client => $client),
    );

    my %args = (
        action               => 'deposit',
        amount               => 10,
        platform_currency    => 'USD',
        account_type         => 'real',
        landing_company_from => 'svg',
        landing_company_to   => 'svg',
    );

    cmp_deeply(
        exception {
            $dxtrader->validate_transfer(%args)
        },
        {
            error_code     => 'PlatformTransferError',
            message_params => [re('account has zero balance')]
        },
        'zero balance'
    );

    BOM::Test::Helper::Client::top_up($client, $client->account->currency_code, 5);

    cmp_deeply(
        exception {
            $dxtrader->validate_transfer(%args)
        },
        {
            error_code     => 'PlatformTransferError',
            message_params => [re('exceeds client balance')]
        },
        'insufficient balance'
    );

    BOM::Test::Helper::Client::top_up($client, $client->account->currency_code, 5);

    cmp_deeply(
        $dxtrader->validate_transfer(%args),
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
            $dxtrader->validate_transfer(%args, platform_currency => 'EUR')
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
            $dxtrader->validate_transfer(%args, platform_currency => 'EUR')
        },
        {
            error_code     => 'InvalidMinAmount',
            message_params => ['100.00', 'USD'],
            rule           => 'transfers.limits',
        },
        'Minimum limit reached'
    );

    $app_config->set({'payments.transfer_between_accounts.minimum.dxtrade' => '{"default":{"currency":"USD","amount":1}}'});
    $app_config->set({'payments.transfer_between_accounts.maximum.dxtrade' => '{"default":{"currency":"USD","amount":5}}'});

    cmp_deeply(
        exception {
            $dxtrader->validate_transfer(%args, platform_currency => 'EUR')
        },
        {
            error_code     => 'InvalidMaxAmount',
            message_params => ['5.00', 'USD'],
            rule           => 'transfers.limits',
        },
        'Maximum limit reached'
    );
    $app_config->set({'payments.transfer_between_accounts.maximum.dxtrade' => '{"default":{"currency":"USD","amount":100}}'});

    cmp_deeply(
        $dxtrader->validate_transfer(%args, platform_currency => 'EUR'),
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
    my $dxtrader = BOM::TradingPlatform->new_base(
        client      => $client,
        rule_engine => BOM::Rules::Engine->new(client => $client));

    cmp_deeply(
        $dxtrader->validate_transfer(
            action               => 'withdrawal',
            amount               => 10,
            platform_currency    => 'USD',
            account_type         => 'real',
            landing_company_from => 'svg',
            landing_company_to   => 'svg',
        ),
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
        $dxtrader->validate_transfer(
            action               => 'withdrawal',
            amount               => 10,
            platform_currency    => 'EUR',
            account_type         => 'real',
            landing_company_from => 'svg',
            landing_company_to   => 'svg',
        ),
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
    $user->add_client($client_btc);
    my $dxtrader_btc = BOM::TradingPlatform->new_base(
        client      => $client_btc,
        rule_engine => BOM::Rules::Engine->new(client => $client_btc));

    populate_exchange_rates({BTC => 10000});
    BOM::Test::Helper::Client::top_up($client_btc, 'BTC', 1);
    cmp_deeply exception {
        $dxtrader_btc->validate_transfer(
            action            => 'withdrawal',
            amount            => 101,
            platform_currency => 'USD',
            account_type      => 'real',
        )
    },
        {
        error_code     => 'InvalidMaxAmount',
        message_params => ['100.00', 'USD'],
        rule           => 'transfers.limits',
        },
        'Correct max limit for USD withdrawal from BTC account';

    cmp_deeply(
        $dxtrader_btc->validate_transfer(
            action               => 'withdrawal',
            amount               => 100,
            platform_currency    => 'USD',
            account_type         => 'real',
            landing_company_from => 'svg',
            landing_company_to   => 'svg',
        ),
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
