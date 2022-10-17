use strict;
use warnings;

use Test::Most;
use Test::FailWarnings;
use Test::MockModule;
use File::Spec;
use Test::MockModule;
use Test::MockObject::Extends;
use Crypt::NamedKeys;
Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';

use YAML::XS;
use Cache::RedisDB;
use BOM::Test::Data::Utility::UnitTestDatabase   qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase;
use BOM::Test::Helper::Client qw(create_client top_up );
use BOM::User::Client;
use BOM::Config::Runtime;
use BOM::Transaction;
use BOM::Transaction::Validation;
use BOM::Product::ContractFactory           qw( produce_contract make_similar_contract );
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Database::DataMapper::FinancialMarketBet;

use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;

initialize_realtime_ticks_db();

my $now = Date::Utility->new('2021-11-15');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => $_,
        date   => $now,
    }) for (qw/USD JPY JPY-USD EUR/);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => $_,
        recorded_date => $now,
    }) for qw(frxUSDJPY frxBROUSD);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_moneyness',
    {
        symbol        => 'OTC_GDAXI',
        recorded_date => $now,
    });

my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch,
    underlying => 'frxUSDJPY',
});

my $client = BOM::User::Client->new({loginid => 'CR2002'});

my $loginid  = $client->loginid;
my $currency = 'USD';
my $account  = $client->account($currency);

my $underlying = create_underlying('frxUSDJPY');
my $contract   = produce_contract({
    underlying   => $underlying,
    bet_type     => 'CALL',
    currency     => $currency,
    payout       => 1000,
    date_start   => $now,
    date_expiry  => $now->epoch + 300,
    current_tick => $tick,
    barrier      => 'S0P',
});

subtest 'Validate legal_allowed_underlyings' => sub {

    my $contract_args = {
        underlying => 'frxUSDJPY',
        bet_type   => 'CALL',
        currency   => 'USD',
        date_start => $now,
        duration   => '5h',
        payout     => 10,
        barrier    => 'S0P',
    };

    my $cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    $cr->account('USD');
    my $c           = produce_contract($contract_args);
    my $transaction = BOM::Transaction->new({
        client        => $cr,
        contract      => $c,
        purchase_date => $contract->date_start,
    });
    ok !BOM::Transaction::Validation->new({
            clients     => [$cr],
            transaction => $transaction
        })->_validate_jurisdictional_restrictions($cr), 'no error for frxUSDJPY for CR account';
};

subtest 'Validate legal allowed contract types' => sub {

    my $contract_args = {
        underlying => 'frxUSDJPY',
        bet_type   => 'CALL',
        currency   => 'USD',
        date_start => $now,
        duration   => '5h',
        payout     => 10,
        barrier    => 'S0P',
    };

    my $cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    $cr->account('USD');
    my $c           = produce_contract($contract_args);
    my $transaction = BOM::Transaction->new({
        purchase_date => $contract->date_start,
        client        => $cr,
        contract      => $c,
    });
    ok !BOM::Transaction::Validation->new({
            clients     => [$cr],
            transaction => $transaction
        })->_validate_jurisdictional_restrictions($cr), 'no error for CALL for CR account';

    $contract_args->{bet_type} = 'CALLE';
    $c                         = produce_contract($contract_args);
    $transaction               = BOM::Transaction->new({
        purchase_date => $contract->date_start,
        client        => $cr,
        contract      => $c,
    });
    ok !BOM::Transaction::Validation->new({
            clients     => [$cr],
            transaction => $transaction
        })->_validate_jurisdictional_restrictions($cr);
};

subtest 'Validate Jurisdiction Restriction' => sub {
    plan tests => 24;

    top_up $client, 'USD', 5000;

    my $mocked_contract = Test::MockModule->new('BOM::Product::Contract::Call');
    $mocked_contract->mock('is_valid_to_buy', sub { return 1 });
    $mocked_contract->mock('ask_probability' => sub { return 0.5 });
    $mocked_contract->mock('ask_price'       => sub { return 50 });

    my $mocked_transaction_val = Test::MockModule->new('BOM::Transaction::Validation');
    $mocked_transaction_val->mock('_validate_date_pricing',             sub { return });
    $mocked_transaction_val->mock('check_tax_information',              sub { return undef });
    $mocked_transaction_val->mock('compliance_checks',                  sub { return undef });
    $mocked_transaction_val->mock('check_client_professional',          sub { return undef });
    $mocked_transaction_val->mock('_validate_trade_pricing_adjustment', sub { return undef });

    my $mocked_transaction = Test::MockModule->new('BOM::Transaction');
    $mocked_transaction->mock('_build_pricing_comment', sub { return ['', {}] });

    lives_ok { $client->residence('') } 'set residence to null to test jurisdiction validation';
    lives_ok { $client->save({'log' => 0, 'clerk' => 'raunak'}); } "Can save residence changes back to the client";

    my $transaction = BOM::Transaction->new({
        purchase_date => $contract->date_start,
        client        => $client,
        contract      => $contract,
    });

    my $error = BOM::Transaction::Validation->new({
            clients     => [$client],
            transaction => $transaction
        })->_validate_jurisdictional_restrictions($client);
    is($error->get_type, 'NoResidenceCountry', 'No residence provided for client: _validate_jurisdictional_restrictions - error type');
    like(
        $error->{-message_to_client},
        qr/In order for you to place contracts, we need to know your Residence/,
        'No residence provided for client: _validate_jurisdictional_restrictions - error message'
    );

    lives_ok { $client->residence('de') } 'set residence to Germany to test jurisdiction validation for random';

    my $new_underlying = create_underlying('R_100');
    my $new_contract   = produce_contract({
        underlying   => $new_underlying,
        bet_type     => 'CALL',
        currency     => $currency,
        payout       => 1000,
        date_start   => $now,
        date_pricing => $now,
        date_expiry  => $now->epoch + 300,
        current_tick => $tick,
        barrier      => 'S0P',
    });

    $error = BOM::Transaction->new({
            purchase_date => $contract->date_start,
            client        => $client,
            contract      => $new_contract,
            amount_type   => 'payout',
            price         => $new_contract->ask_price,
        })->buy;

    ok !$error, 'no error for Germany since synthetic indices are no longer restricted';

    #Checking that bets can be placed on other underlyings.

    my $new_underlying2 = create_underlying('frxAUDJPY');
    my $new_contract2   = produce_contract({
        underlying   => $new_underlying2,
        bet_type     => 'CALL',
        currency     => $currency,
        payout       => 1000,
        date_start   => $now,
        date_pricing => $now,
        date_expiry  => $now->epoch + 900,
        current_tick => $tick,
        barrier      => 'S0P',
    });

    $error = BOM::Transaction->new({
            purchase_date => $new_contract2->date_start,
            client        => $client,
            contract      => $new_contract2,
            amount_type   => 'payout',
            price         => $new_contract2->ask_price,
        })->buy;

    is($error, undef, 'German clients are allowed to trade forex underlyings');

    my $new_underlying3 = create_underlying('OTC_GDAXI');
    my $new_contract3   = produce_contract({
        underlying   => $new_underlying3,
        bet_type     => 'CALL',
        currency     => $currency,
        payout       => 1000,
        date_start   => $now,
        date_pricing => $now,
        date_expiry  => $now->plus_time_interval('7d'),
        current_tick => $tick,
        barrier      => 'S0P',
    });

    $error = BOM::Transaction->new({
            purchase_date => $new_contract3->date_start,
            client        => $client,
            contract      => $new_contract3,
            amount_type   => 'payout',
            price         => $new_contract3->ask_price,
        })->buy;

    is($error, undef, 'German clients are allowed to trade index underlyings');

    my $new_underlying4 = create_underlying('frxBROUSD');
    my $new_contract4   = produce_contract({
        underlying   => $new_underlying4,
        bet_type     => 'CALL',
        currency     => $currency,
        payout       => 1000,
        date_start   => $now,
        date_pricing => $now,
        date_expiry  => $now->epoch + 300,
        current_tick => $tick,
        barrier      => 'S0P',
    });

    $error = BOM::Transaction->new({
            purchase_date => $new_contract4->date_start,
            client        => $client,
            contract      => $new_contract4,
            amount_type   => 'payout',
            price         => $new_contract4->ask_price,
        })->buy;

    is($error->get_type, 'InvalidOfferings', 'German clients are NOT allowed to trade commodity underlyings');

    lives_ok { $client->residence('sg') } 'set residence to Singapore to test jurisdiction validation for random';

    $error = BOM::Transaction->new({
            purchase_date => $contract->date_start,
            client        => $client,
            contract      => $new_contract,
            amount_type   => 'payout',
            price         => $new_contract->ask_price,
        })->buy;

    is($error->get_type, 'InvalidOfferings', 'Singapore clients are not allowed to place Random contracts as their country is restricted.');

    lives_ok { $client->residence('es') } 'set residence to Spain to test jurisdiction validation for random';
    $error = BOM::Transaction->new({
            purchase_date => $contract->date_start,
            client        => $client,
            contract      => $new_contract,
            amount_type   => 'payout',
            price         => $new_contract->ask_price,
        })->buy;
    ok !$error, 'no error, synthetic indices are no longer restricted';

    lives_ok { $client->residence('gr') } 'set residence to Greece to test jurisdiction validation for random';
    $error = BOM::Transaction->new({
            purchase_date => $contract->date_start,
            client        => $client,
            contract      => $new_contract,
            amount_type   => 'payout',
            price         => $new_contract->ask_price,
        })->buy;
    ok !$error, 'no error, synthetic indices are no longer restricted';

    lives_ok { $client->residence('lu') } 'set residence to Luxembourg to test jurisdiction validation for random';
    $error = BOM::Transaction->new({
            purchase_date => $contract->date_start,
            client        => $client,
            contract      => $new_contract,
            amount_type   => 'payout',
            price         => $new_contract->ask_price,
        })->buy;
    ok !$error, 'no error, synthetic indices are no longer restricted';

    lives_ok { $client->residence('fr') } 'set residence to France to test jurisdiction validation for random';
    $error = BOM::Transaction->new({
            purchase_date => $contract->date_start,
            client        => $client,
            contract      => $new_contract,
            amount_type   => 'payout',
            price         => $new_contract->ask_price,
        })->buy;
    ok !$error, 'no error, synthetic indices are no longer restricted';

    lives_ok { $client->residence('it') } 'set residence to Italy to test jurisdiction validation for random';
    $error = BOM::Transaction->new({
            purchase_date => $contract->date_start,
            client        => $client,
            contract      => $new_contract,
            amount_type   => 'payout',
            price         => $new_contract->ask_price,
        })->buy;
    ok !$error, 'no error, synthetic indices are no longer restricted';

    #changing client residence to gb and confirming that random contracts can be placed

    lives_ok { $client->residence('gb') } 'set residence back to gb';
    lives_ok { $client->save({'log' => 0, 'clerk' => 'raunak'}); } "Can save residence changes back to the client";

    my $new_underlying5 = create_underlying('R_100');
    my $new_contract5   = produce_contract({
        underlying   => $new_underlying,
        bet_type     => 'CALL',
        currency     => $currency,
        payout       => 1000,
        date_start   => $now,
        date_pricing => $now,
        date_expiry  => $now->epoch + 300,
        current_tick => $tick,
        barrier      => 'S0P',
    });

    $error = BOM::Transaction->new({
            purchase_date => $new_contract5->date_start,
            client        => $client,
            contract      => $new_contract5,
            amount_type   => 'payout',
            price         => $new_contract5->ask_price,
        })->buy;

    ok !$error, 'no error, can buy random';
};

subtest 'Validate Unwelcome Client' => sub {
    plan tests => 4;
    my $reason = "test to set unwelcome login";
    lives_ok { $client->status->set('unwelcome', 'raunak', $reason) } "set client unwelcome login";

    my $transaction = BOM::Transaction->new({
        purchase_date => $contract->date_start,
        client        => $client,
        contract      => $contract,
    });

    my $error = BOM::Transaction::Validation->new({
            clients     => [$client],
            transaction => $transaction
        })->_validate_client_status($client);
    is($error->get_type, 'ClientUnwelcome', 'Client is unwelcome : _validate_client_status - error type');
    like(
        $error->{-message_to_client},
        qr/Sorry, your account is not authorised for any further contract purchases/,
        'Client is unwelcome : _validate_client_status - error message'
    );

    lives_ok { $client->status->clear_unwelcome } "delete client from unwelcome login";
};

subtest 'Validate no_trading Client' => sub {
    plan tests => 4;
    my $reason = "test to set no_trading login";
    lives_ok { $client->status->set('no_trading', 'test', $reason) } "set client no_trading login";

    my $transaction = BOM::Transaction->new({
        purchase_date => $contract->date_start,
        client        => $client,
        contract      => $contract,
    });

    my $error = BOM::Transaction::Validation->new({
            clients     => [$client],
            transaction => $transaction
        })->_validate_client_status($client);
    is($error->get_type, 'ClientUnwelcome', 'Client is no_trading : _validate_client_status - error type');
    like(
        $error->{-message_to_client},
        qr/Sorry, your account is not authorised for any further contract purchases/,
        'Client is no_trading : _validate_client_status - error message'
    );

    lives_ok { $client->status->clear_no_trading } "delete client from no_trading login";
};

subtest 'Validate Disabled Client' => sub {
    plan tests => 4;
    my $reason = "test to set disabled login";
    lives_ok { $client->status->set('disabled', 'raunak', $reason) } "set client disabled login";

    my $transaction = BOM::Transaction->new({
        purchase_date => $contract->date_start,
        client        => $client,
        contract      => $contract,
    });

    my $error = BOM::Transaction::Validation->new({
            clients     => [$client],
            transaction => $transaction
        })->_validate_client_status($client);
    is($error->get_type, 'ClientUnwelcome', 'Client is unwelcome : _validate_client_status - error type');
    like(
        $error->{-message_to_client},
        qr/Sorry, your account is not authorised for any further contract purchases/,
        'Client is unwelcome : _validate_client_status - error message'
    );

    lives_ok { $client->status->clear_disabled } "delete client from disabled login";
};

subtest 'Payment agent restriction' => sub {
    my $services_allowed = {};
    my $mock_pa          = Test::MockObject->new;
    $mock_pa->mock(service_is_allowed => sub { $services_allowed->{$_[1]} });

    my $mock_client = Test::MockModule->new('BOM::User::Client');
    $mock_client->redefine(
        get_payment_agent => sub {
            return $mock_pa;
        });

    my $transaction = BOM::Transaction->new({
        purchase_date => $contract->date_start,
        client        => $client,
        contract      => $contract,
    });

    my $validation = BOM::Transaction::Validation->new({
        clients     => [$client],
        transaction => $transaction
    });
    my $error = $validation->_validate_payment_agent_restriction($client);
    is($error->get_type, 'ServiceNotAllowedForPA', 'Trading service is not available for Payment agents.');
    like($error->{-message_to_client}, qr/This service is not available for payment agents/, 'Payment agent restruction error message');

    $services_allowed->{trading} = 1;
    is $validation->_validate_payment_agent_restriction($client), undef, 'No error if tarding is allowed for the payment agent';

    $mock_client->unmock_all;
};

done_testing;
