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
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase;
use Client::Account;
use BOM::Platform::Runtime;
use BOM::Transaction;
use BOM::Transaction::Validation;
use BOM::Product::ContractFactory qw( produce_contract make_similar_contract );
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Database::DataMapper::FinancialMarketBet;

use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;

initialize_realtime_ticks_db();

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => $_,
        date   => Date::Utility->new,
    }) for (qw/USD JPY JPY-USD/);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => Date::Utility->new,
    });

my $now  = Date::Utility->new;
my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch,
    underlying => 'frxUSDJPY',
});

my $client = Client::Account->new({loginid => 'CR2002'});

my $loginid  = $client->loginid;
my $currency = 'USD';
my $account  = $client->default_account;

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
    my $jp = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'JP'});

    my $loginid       = $jp->loginid;
    my $account       = $jp->default_account;
    my $contract_args = {
        underlying => 'frxUSDJPY',
        bet_type   => 'CALLE',
        currency   => 'JPY',
        date_start => $now,
        duration   => '5h',
        payout     => 10,
        barrier    => 'S0P',
    };
    my $c           = produce_contract($contract_args);
    my $transaction = BOM::Transaction->new({
        purchase_date => $contract->date_start,
        client        => $jp,
        contract      => $c,
    });
    ok !BOM::Transaction::Validation->new({
            clients     => [$jp],
            transaction => $transaction
        })->_validate_jurisdictional_restrictions($jp), 'no error for frxUSDJPY for JP account';

    $contract_args->{underlying} = 'frxAUDCAD';
    $c                           = produce_contract($contract_args);
    $transaction                 = BOM::Transaction->new({
        purchase_date => $contract->date_start,
        client        => $jp,
        contract      => $c,
    });
    my $error = BOM::Transaction::Validation->new({
            clients     => [$jp],
            transaction => $transaction
        })->_validate_jurisdictional_restrictions($jp);
    is $error->{'-type'}, 'NotLegalUnderlying', 'error for frxAUDCAD for JP account';

    my $cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    $cr->default_account;
    $contract_args->{currency} = 'USD';
    $contract_args->{bet_type} = 'CALL';
    $c                         = produce_contract($contract_args);
    $transaction               = BOM::Transaction->new({
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
    my $jp = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'JP'});

    my $loginid       = $jp->loginid;
    my $account       = $jp->default_account;
    my $contract_args = {
        underlying => 'frxUSDJPY',
        bet_type   => 'CALLE',
        currency   => 'JPY',
        date_start => $now,
        duration   => '5h',
        payout     => 10,
        barrier    => 'S0P',
    };
    my $c           = produce_contract($contract_args);
    my $transaction = BOM::Transaction->new({
        purchase_date => $contract->date_start,
        client        => $jp,
        contract      => $c,
    });
    ok !BOM::Transaction::Validation->new({
            clients     => [$jp],
            transaction => $transaction
        })->_validate_jurisdictional_restrictions($jp), 'no error for CALLE for JP account';

    $contract_args->{bet_type} = 'CALL';
    $c                         = produce_contract($contract_args);
    $transaction               = BOM::Transaction->new({
        client        => $jp,
        purchase_date => $contract->date_start,
        contract      => $c,
    });
    my $error = BOM::Transaction::Validation->new({
            clients     => [$jp],
            transaction => $transaction
        })->_validate_jurisdictional_restrictions($jp);
    is $error->{'-type'}, 'NotLegalContractCategory', 'error for CALL for JP account';

    my $cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    $cr->default_account;
    $contract_args->{currency} = 'USD';
    $c                         = produce_contract($contract_args);
    $transaction               = BOM::Transaction->new({
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
    plan tests => 35;
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
        date_expiry  => $now->epoch + 300,
        current_tick => $tick,
        barrier      => 'S0P',
    });

    my $new_transaction = BOM::Transaction->new({
        purchase_date => $contract->date_start,
        client        => $client,
        contract      => $new_contract,
    });

    $error = BOM::Transaction::Validation->new({
            clients     => [$client],
            transaction => $new_transaction
        })->_validate_jurisdictional_restrictions($client);
    is($error->get_type, 'RandomRestrictedCountry', 'Germany clients are not allowed to place Random contracts as their country is restricted.');
    like(
        $error->{-message_to_client},
        qr/Sorry, contracts on Volatility Indices are not available in your country of residence/,
        'Germany clients are not allowed to place Random contracts as their country is restricted due to vat regulations'
    );

    #Checking that bets can be placed on other underlyings.

    my $new_underlying2 = create_underlying('frxAUDJPY');
    my $new_contract2   = produce_contract({
        underlying   => $new_underlying2,
        bet_type     => 'CALL',
        currency     => $currency,
        payout       => 1000,
        date_start   => $now,
        date_expiry  => $now->epoch + 300,
        current_tick => $tick,
        barrier      => 'S0P',
    });

    my $new_transaction2 = BOM::Transaction->new({
        purchase_date => $contract->date_start,
        client        => $client,
        contract      => $new_contract2,
    });

    $error = BOM::Transaction::Validation->new({
            clients     => [$client],
            transaction => $new_transaction2
        })->_validate_jurisdictional_restrictions($client);
    is($error, undef, 'German clients are allowed to trade forex underlyings');

    my $new_underlying3 = create_underlying('GDAXI');
    my $new_contract3   = produce_contract({
        underlying   => $new_underlying3,
        bet_type     => 'CALL',
        currency     => $currency,
        payout       => 1000,
        date_start   => $now,
        date_expiry  => $now->epoch + 300,
        current_tick => $tick,
        barrier      => 'S0P',
    });

    my $new_transaction3 = BOM::Transaction->new({
        purchase_date => $contract->date_start,
        client        => $client,
        contract      => $new_contract3,
    });

    $error = BOM::Transaction::Validation->new({
            clients     => [$client],
            transaction => $new_transaction3
        })->_validate_jurisdictional_restrictions($client);
    is($error, undef, 'German clients are allowed to trade index underlyings');

    my $new_underlying4 = create_underlying('frxBROUSD');
    my $new_contract4   = produce_contract({
        underlying   => $new_underlying4,
        bet_type     => 'CALL',
        currency     => $currency,
        payout       => 1000,
        date_start   => $now,
        date_expiry  => $now->epoch + 300,
        current_tick => $tick,
        barrier      => 'S0P',
    });

    my $new_transaction4 = BOM::Transaction->new({
        purchase_date => $contract->date_start,
        client        => $client,
        contract      => $new_contract4,
    });

    $error = BOM::Transaction::Validation->new({
            clients     => [$client],
            transaction => $new_transaction4
        })->_validate_jurisdictional_restrictions($client);
    is($error, undef, 'German clients are allowed to trade commodity underlyings');

    lives_ok { $client->residence('sg') } 'set residence to Singapore to test jurisdiction validation for random';
    $new_transaction = BOM::Transaction->new({
        purchase_date => $contract->date_start,
        client        => $client,
        contract      => $new_contract,
    });
    $error = BOM::Transaction::Validation->new({
            clients     => [$client],
            transaction => $new_transaction
        })->_validate_jurisdictional_restrictions($client);
    is($error->get_type, 'RandomRestrictedCountry', 'Singapore clients are not allowed to place Random contracts as their country is restricted.');

    lives_ok { $client->residence('es') } 'set residence to Spain to test jurisdiction validation for random';
    $new_transaction = BOM::Transaction->new({
        purchase_date => $contract->date_start,
        client        => $client,
        contract      => $new_contract,
    });
    $error = BOM::Transaction::Validation->new({
            clients     => [$client],
            transaction => $new_transaction
        })->_validate_jurisdictional_restrictions($client);
    is($error->get_type, 'RandomRestrictedCountry', 'Spain clients are not allowed to place Random contracts as their country is restricted.');

    lives_ok { $client->residence('gr') } 'set residence to Greece to test jurisdiction validation for random';
    $new_transaction = BOM::Transaction->new({
        purchase_date => $contract->date_start,
        client        => $client,
        contract      => $new_contract,
    });
    $error = BOM::Transaction::Validation->new({
            clients     => [$client],
            transaction => $new_transaction
        })->_validate_jurisdictional_restrictions($client);
    is($error->get_type, 'RandomRestrictedCountry', 'Greece clients are not allowed to place Random contracts as their country is restricted.');

    lives_ok { $client->residence('lu') } 'set residence to Luxembourg to test jurisdiction validation for random';
    $new_transaction = BOM::Transaction->new({
        purchase_date => $contract->date_start,
        client        => $client,
        contract      => $new_contract,
    });
    $error = BOM::Transaction::Validation->new({
            clients     => [$client],
            transaction => $new_transaction
        })->_validate_jurisdictional_restrictions($client);
    is($error->get_type, 'RandomRestrictedCountry', 'Luxembourg clients are not allowed to place Random contracts as their country is restricted.');

    lives_ok { $client->residence('fr') } 'set residence to France to test jurisdiction validation for random';
    $new_transaction = BOM::Transaction->new({
        purchase_date => $contract->date_start,
        client        => $client,
        contract      => $new_contract,
    });
    $error = BOM::Transaction::Validation->new({
            clients     => [$client],
            transaction => $new_transaction
        })->_validate_jurisdictional_restrictions($client);
    is($error->get_type, 'RandomRestrictedCountry', 'France clients are not allowed to place Random contracts as their country is restricted.');

    lives_ok { $client->residence('it') } 'set residence to Italy to test jurisdiction validation for random';
    $new_transaction = BOM::Transaction->new({
        purchase_date => $contract->date_start,
        client        => $client,
        contract      => $new_contract,
    });
    $error = BOM::Transaction::Validation->new({
            clients     => [$client],
            transaction => $new_transaction
        })->_validate_jurisdictional_restrictions($client);
    is($error->get_type, 'RandomRestrictedCountry', 'Italy clients are not allowed to place Random contracts as their country is restricted.');

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
        date_expiry  => $now->epoch + 300,
        current_tick => $tick,
        barrier      => 'S0P',
    });

    my $new_transaction5 = BOM::Transaction->new({
        purchase_date => $contract->date_start,
        client        => $client,
        contract      => $new_contract5,
    });

    $error = BOM::Transaction::Validation->new({
            clients     => [$client],
            transaction => $new_transaction
        })->_validate_jurisdictional_restrictions($client);
    is($error, undef, 'British clients are allowed to trade random underlyings');

    lives_ok { $client->residence('be') } 'set residence to Belgium to test jurisdiction validation for random and financial binaries contracts';

    $new_transaction = BOM::Transaction->new({
        purchase_date => $contract->date_start,
        client        => $client,
        contract      => $new_contract5,
    });

    $error = BOM::Transaction::Validation->new({
            clients     => [$client],
            transaction => $new_transaction
        })->_validate_jurisdictional_restrictions($client);

    is($error, undef, 'Belgium clients are allowed to trade random underlyings');

    $new_transaction = BOM::Transaction->new({
        purchase_date => $contract->date_start,
        client        => $client,
        contract      => $new_contract2,
    });

    $error = BOM::Transaction::Validation->new({
            clients     => [$client],
            transaction => $new_transaction
        })->_validate_jurisdictional_restrictions($client);
    is(
        $error->get_type,
        'FinancialBinariesRestrictedCountry',
        'Belgium clients are not allowed to place forex contracts as their country is restricted.'
    );
    like(
        $error->{-message_to_client},
        qr/Sorry, contracts on Financial Products are not available in your country of residence/,
        'Belgium clients are not allowed to place forex contracts as their country is restricted due to vat regulations'
    );

    $new_transaction = BOM::Transaction->new({
        purchase_date => $contract->date_start,
        client        => $client,
        contract      => $new_contract3,
    });

    $error = BOM::Transaction::Validation->new({
            clients     => [$client],
            transaction => $new_transaction
        })->_validate_jurisdictional_restrictions($client);
    is(
        $error->get_type,
        'FinancialBinariesRestrictedCountry',
        'Belgium clients are not allowed to place indices contracts as their country is restricted.'
    );
    like(
        $error->{-message_to_client},
        qr/Sorry, contracts on Financial Products are not available in your country of residence/,
        'Belgium clients are not allowed to place indices contracts as their country is restricted due to vat regulations'
    );

    $new_transaction = BOM::Transaction->new({
        purchase_date => $contract->date_start,
        client        => $client,
        contract      => $new_contract4,
    });

    $error = BOM::Transaction::Validation->new({
            clients     => [$client],
            transaction => $new_transaction
        })->_validate_jurisdictional_restrictions($client);
    is(
        $error->get_type,
        'FinancialBinariesRestrictedCountry',
        'Belgium clients are not allowed to place commodities contracts as their country is restricted.'
    );
    like(
        $error->{-message_to_client},
        qr/Sorry, contracts on Financial Products are not available in your country of residence/,
        'Belgium clients are not allowed to place commodities contracts as their country is restricted due to vat regulations'
    );

    # check if market name is allowed for landing company
    $new_underlying = create_underlying('R50');
    $new_contract   = produce_contract({
        underlying   => $new_underlying,
        bet_type     => 'CALL',
        currency     => $currency,
        payout       => 1000,
        date_start   => $now,
        date_expiry  => $now->epoch + 300,
        current_tick => $tick,
        barrier      => 'S0P',
    });

    $new_transaction = BOM::Transaction->new({
        purchase_date => $contract->date_start,
        client        => $client,
        contract      => $new_contract,
    });

    $error = BOM::Transaction::Validation->new({
            clients     => [$client],
            transaction => $new_transaction
        })->_validate_jurisdictional_restrictions($client);
    is($error->get_type, 'NotLegalMarket', 'Market name is not in the list of legal allowed markets.');
    like(
        $error->{-message_to_client},
        qr/Please switch accounts to trade this market./,
        'Market name is not in the list of legal allowed markets. Please switch accounts'
    );

};

subtest 'Validate Unwelcome Client' => sub {
    plan tests => 6;
    my $reason = "test to set unwelcome login";
    lives_ok { $client->set_status('unwelcome', 'raunak', $reason) } "set client unwelcome login";
    lives_ok { $client->save() } "can save to unwelcome login file";

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

    lives_ok { $client->clr_status('unwelcome') } "delete client from unwelcome login";
    lives_ok { $client->save() } "can save to unwelcome login file";
};

subtest 'Validate Disabled Client' => sub {
    plan tests => 6;
    my $reason = "test to set disabled login";
    lives_ok { $client->set_status('disabled', 'raunak', $reason) } "set client disabled login";
    lives_ok { $client->save() } "can save to disabled login file";

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

    lives_ok { $client->clr_status('disabled') } "delete client from disabled login";
    lives_ok { $client->save() } "can save to disabled login file";
};

done_testing;
