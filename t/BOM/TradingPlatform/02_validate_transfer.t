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

my $mock_fees = Test::MockModule->new('BOM::Config::CurrencyConfig', no_auto => 1);
$mock_fees->mock(
    transfer_between_accounts_fees => sub {
        return {
            'USD' => {'EUR' => 20},
            'EUR' => {'USD' => 5}};
    });

subtest 'common' => sub {

    for my $action ('deposit', 'withdrawal') {

        my $client_vr   = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'VRTC'});
        my $client_real = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
        # todo: wallet tests

        my $dxtrader = BOM::TradingPlatform->new_base(client => $client_real);

        BOM::Config::Runtime->instance->app_config->system->suspend->payments(1);
        cmp_deeply(
            exception { $dxtrader->validate_transfer(action => $action, amount => 10, currency => 'USD', account_type => 'real') },
            {error_code => 'PlatformTransferSuspended'},
            "payments suspended for $action"
        );
        BOM::Config::Runtime->instance->app_config->system->suspend->payments(0);

        BOM::Config::Runtime->instance->app_config->system->suspend->transfer_between_accounts(1);
        cmp_deeply(
            exception { $dxtrader->validate_transfer(action => $action, amount => 10, currency => 'USD', account_type => 'real') },
            {error_code => 'PlatformTransferSuspended'},
            "transfer between accounts suspended for $action"
        );
        BOM::Config::Runtime->instance->app_config->system->suspend->transfer_between_accounts(0);

        $client_real->status->set('transfers_blocked', 'system', 'test');
        cmp_deeply(
            exception { $dxtrader->validate_transfer(action => $action, amount => 10, currency => 'USD', account_type => 'real') },
            {error_code => 'PlatformTransferBlocked'},
            "$action: client has transfers_blocked status"
        );
        $client_real->status->clear_transfers_blocked;

        cmp_deeply(
            exception { $dxtrader->validate_transfer(action => $action, amount => 10, currency => 'USD', account_type => 'real') },
            {error_code => 'PlatformTransferNocurrency'},
            "$action: currency not yet chosen"
        );

        $client_vr->account('USD');
        $client_real->account('USD');

        my $dxtrader_vr = BOM::TradingPlatform->new_base(client => $client_vr);

        cmp_deeply(
            exception { $dxtrader_vr->validate_transfer(action => $action, amount => 10, currency => 'USD', account_type => 'real') },
            {error_code => 'PlatformTransferNoVirtual'},
            "demo client cannot $action on real"
        );

        cmp_deeply(
            exception { $dxtrader_vr->validate_transfer(action => $action, amount => 10, currency => 'USD', account_type => 'demo') },
            {error_code => 'PlatformTransferNoVirtual'},
            "demo client cannot $action on demo"
        );

        cmp_deeply(
            exception { $dxtrader_vr->validate_transfer(action => $action, amount => 10, currency => 'USD', account_type => 'demo') },
            {error_code => 'PlatformTransferNoVirtual'},
            "real client cannot $action on demo"
        );

        my $client_eur = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
        $client_eur->account('EUR');
        my $dxtrader_eur = BOM::TradingPlatform->new_base(client => $client_eur);

        BOM::Config::Runtime->instance->app_config->system->suspend->transfer_currencies(['EUR', 'BTC']);

        cmp_deeply(
            exception { $dxtrader_eur->validate_transfer(action => $action, amount => 10, currency => 'USD', account_type => 'real') },
            {
                error_code     => 'PlatformTransferCurrencySuspended',
                message_params => ['EUR']
            },
            "$action: deriv transfer currency suspended"
        );

        cmp_deeply(
            exception { $dxtrader->validate_transfer(action => $action, amount => 10, currency => 'EUR', account_type => 'real') },
            {
                error_code     => 'PlatformTransferCurrencySuspended',
                message_params => ['EUR']
            },
            "$action: dxtrade transfer currency suspended"
        );

        BOM::Config::Runtime->instance->app_config->system->suspend->transfer_currencies([]);

        # todo: wallet tests
    }

};

subtest 'deposit' => sub {

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    $client->account('USD');
    BOM::User->create(
        email    => 'deposit@test.com',
        password => 'test'
    )->add_client($client);
    my $dxtrader = BOM::TradingPlatform->new_base(client => $client);

    cmp_deeply(
        exception { $dxtrader->validate_transfer(action => 'deposit', amount => 10, currency => 'USD', account_type => 'real') },
        {
            error_code     => 'PlatformTransferError',
            message_params => [re('exceeds client balance')]
        },
        'insufficient balance'
    );

    BOM::Test::Helper::Client::top_up($client, $client->account->currency_code, 10);

    cmp_deeply(
        $dxtrader->validate_transfer(
            action       => 'deposit',
            amount       => 10,
            currency     => 'USD',
            account_type => 'real'
        ),
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
        exception { $dxtrader->validate_transfer(action => 'deposit', amount => 10, currency => 'EUR', account_type => 'real') },
        {error_code => 'PlatformTransferTemporarilyUnavailable'},
        'no exchange rate'
    );

    populate_exchange_rates({EUR => 2});

    cmp_deeply(
        $dxtrader->validate_transfer(
            action       => 'deposit',
            amount       => 10,
            currency     => 'EUR',
            account_type => 'real'
        ),
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

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    $client->account('USD');
    BOM::User->create(
        email    => 'withdrawal@test.com',
        password => 'test'
    )->add_client($client);
    my $dxtrader = BOM::TradingPlatform->new_base(client => $client);

    cmp_deeply(
        $dxtrader->validate_transfer(
            action       => 'withdrawal',
            amount       => 10,
            currency     => 'USD',
            account_type => 'real'
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
            action       => 'withdrawal',
            amount       => 10,
            currency     => 'EUR',
            account_type => 'real'
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

};

done_testing();
