use strict;
use warnings;

use Test::Most;
use Test::FailWarnings;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);
use Test::MockModule;
use Test::MockObject::Extends;
use Crypt::NamedKeys;
Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';

use YAML::XS;
use Cache::RedisDB;
use BOM::Test::Runtime qw(:normal);
use BOM::Market::AggTicks;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase;
use BOM::Platform::Client;
use BOM::Platform::Runtime;
use BOM::Product::Transaction;
use BOM::Product::ContractFactory qw( produce_contract make_similar_contract );
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Database::DataMapper::FinancialMarketBet;

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

my $client = BOM::Platform::Client->new({loginid => 'CR2002'});

my $loginid  = $client->loginid;
my $currency = 'USD';
my $account  = $client->default_account;

my $underlying = BOM::Market::Underlying->new('frxUSDJPY');
my $contract   = produce_contract({
    underlying   => $underlying,
    bet_type     => 'FLASHU',
    currency     => $currency,
    payout       => 1000,
    date_start   => $now,
    date_expiry  => $now->epoch + 300,
    current_tick => $tick,
    barrier      => 'S0P',
});

subtest 'validate legal allowed contract categories' => sub {
    my $cr = BOM::Platform::Client->new({loginid => 'CR2002'});

    my $loginid  = $cr->loginid;
    my $currency = 'USD';
    my $account  = $cr->default_account;
    my $c        = produce_contract({
        underlying       => 'R_100',
        bet_type         => 'SPREADU',
        currency         => $currency,
        date_start       => $now,
        amount_per_point => 1,
        stop_loss        => 10,
        stop_profit      => 10,
        stop_type        => 'point',
        spread           => 2,
    });
    my $transaction = BOM::Product::Transaction->new({
        client   => $cr,
        contract => $c,
    });
    ok !$transaction->_validate_jurisdictional_restrictions, 'no error for CR';

    my $mlt = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'MLT'});
    $loginid     = $mlt->loginid;
    $account     = $mlt->default_account;
    $transaction = BOM::Product::Transaction->new({
        client   => $mlt,
        contract => $c,
    });
    ok !$transaction->_validate_jurisdictional_restrictions, 'no error for MLT';

    my $mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'MF'});
    $loginid     = $mf->loginid;
    $account     = $mf->default_account;
    $transaction = BOM::Product::Transaction->new({
        client   => $mf,
        contract => $c,
    });
    my $error = $transaction->_validate_jurisdictional_restrictions;
    is $error->{'-type'}, 'NotLegalContractCategory', 'error for MF';
};

subtest 'Validate Jurisdiction Restriction' => sub {
    plan tests => 27;
    lives_ok { $client->residence('') } 'set residence to null to test jurisdiction validation';
    lives_ok { $client->save({'log' => 0, 'clerk' => 'raunak'}); } "Can save residence changes back to the client";

    my $transaction = BOM::Product::Transaction->new({
        client   => $client,
        contract => $contract,
    });

    my $error = $transaction->_validate_jurisdictional_restrictions;
    is($error->get_type, 'NoResidenceCountry', 'No residence provided for client: _validate_jurisdictional_restrictions - error type');
    like(
        $error->{-message_to_client},
        qr/In order for you to place contracts, we need to know your Residence/,
        'No residence provided for client: _validate_jurisdictional_restrictions - error message'
    );

    lives_ok { $client->residence('de') } 'set residence to Germany to test jurisdiction validation for random';

    my $new_underlying = BOM::Market::Underlying->new('R_100');
    my $new_contract   = produce_contract({
        underlying   => $new_underlying,
        bet_type     => 'FLASHU',
        currency     => $currency,
        payout       => 1000,
        date_start   => $now,
        date_expiry  => $now->epoch + 300,
        current_tick => $tick,
        barrier      => 'S0P',
    });

    my $new_transaction = BOM::Product::Transaction->new({
        client   => $client,
        contract => $new_contract,
    });

    $error = $new_transaction->_validate_jurisdictional_restrictions;
    is($error->get_type, 'RandomRestrictedCountry', 'Germany clients are not allowed to place Random contracts as their country is restricted.');
    like(
        $error->{-message_to_client},
        qr/Sorry, contracts on Random Indices are not available in your country of residence/,
        'Germany clients are not allowed to place Random contracts as their country is restricted due to vat regulations'
    );

    #Checking that bets can be placed on other underlyings.

    my $new_underlying2 = BOM::Market::Underlying->new('frxAUDJPY');
    my $new_contract2   = produce_contract({
        underlying   => $new_underlying2,
        bet_type     => 'FLASHU',
        currency     => $currency,
        payout       => 1000,
        date_start   => $now,
        date_expiry  => $now->epoch + 300,
        current_tick => $tick,
        barrier      => 'S0P',
    });

    my $new_transaction2 = BOM::Product::Transaction->new({
        client   => $client,
        contract => $new_contract2,
    });

    $error = $new_transaction2->_validate_jurisdictional_restrictions;
    is($error, undef, 'German clients are allowed to trade forex underlyings');

    my $new_underlying3 = BOM::Market::Underlying->new('frxAUDJPY');
    my $new_contract3   = produce_contract({
        underlying   => $new_underlying3,
        bet_type     => 'FLASHU',
        currency     => $currency,
        payout       => 1000,
        date_start   => $now,
        date_expiry  => $now->epoch + 300,
        current_tick => $tick,
        barrier      => 'S0P',
    });

    my $new_transaction3 = BOM::Product::Transaction->new({
        client   => $client,
        contract => $new_contract3,
    });

    $error = $new_transaction3->_validate_jurisdictional_restrictions;
    is($error, undef, 'German clients are allowed to trade index underlyings');

    my $new_underlying4 = BOM::Market::Underlying->new('frxBROUSD');
    my $new_contract4   = produce_contract({
        underlying   => $new_underlying4,
        bet_type     => 'FLASHU',
        currency     => $currency,
        payout       => 1000,
        date_start   => $now,
        date_expiry  => $now->epoch + 300,
        current_tick => $tick,
        barrier      => 'S0P',
    });

    my $new_transaction4 = BOM::Product::Transaction->new({
        client   => $client,
        contract => $new_contract4,
    });

    $error = $new_transaction4->_validate_jurisdictional_restrictions;
    is($error, undef, 'German clients are allowed to trade commodity underlyings');

    lives_ok { $client->residence('sg') } 'set residence to Singapore to test jurisdiction validation for random';
    $new_transaction = BOM::Product::Transaction->new({
        client   => $client,
        contract => $new_contract,
    });
    $error = $new_transaction->_validate_jurisdictional_restrictions;
    is($error->get_type, 'RandomRestrictedCountry', 'Singapore clients are not allowed to place Random contracts as their country is restricted.');

    lives_ok { $client->residence('es') } 'set residence to Spain to test jurisdiction validation for random';
    $new_transaction = BOM::Product::Transaction->new({
        client   => $client,
        contract => $new_contract,
    });
    $error = $new_transaction->_validate_jurisdictional_restrictions;
    is($error->get_type, 'RandomRestrictedCountry', 'Spain clients are not allowed to place Random contracts as their country is restricted.');

    lives_ok { $client->residence('gr') } 'set residence to Greece to test jurisdiction validation for random';
    $new_transaction = BOM::Product::Transaction->new({
        client   => $client,
        contract => $new_contract,
    });
    $error = $new_transaction->_validate_jurisdictional_restrictions;
    is($error->get_type, 'RandomRestrictedCountry', 'Greece clients are not allowed to place Random contracts as their country is restricted.');

    lives_ok { $client->residence('lu') } 'set residence to Luxembourg to test jurisdiction validation for random';
    $new_transaction = BOM::Product::Transaction->new({
        client   => $client,
        contract => $new_contract,
    });
    $error = $new_transaction->_validate_jurisdictional_restrictions;
    is($error->get_type, 'RandomRestrictedCountry', 'Luxembourg clients are not allowed to place Random contracts as their country is restricted.');

    lives_ok { $client->residence('fr') } 'set residence to France to test jurisdiction validation for random';
    $new_transaction = BOM::Product::Transaction->new({
        client   => $client,
        contract => $new_contract,
    });
    $error = $new_transaction->_validate_jurisdictional_restrictions;
    is($error->get_type, 'RandomRestrictedCountry', 'France clients are not allowed to place Random contracts as their country is restricted.');

    lives_ok { $client->residence('it') } 'set residence to Italy to test jurisdiction validation for random';
    $new_transaction = BOM::Product::Transaction->new({
        client   => $client,
        contract => $new_contract,
    });
    $error = $new_transaction->_validate_jurisdictional_restrictions;
    is($error->get_type, 'RandomRestrictedCountry', 'Italy clients are not allowed to place Random contracts as their country is restricted.');

    #changing client residence to gb and confirming that random contracts can be placed

    lives_ok { $client->residence('gb') } 'set residence back to gb';
    lives_ok { $client->save({'log' => 0, 'clerk' => 'raunak'}); } "Can save residence changes back to the client";

    my $new_underlying5 = BOM::Market::Underlying->new('R_100');
    my $new_contract5   = produce_contract({
        underlying   => $new_underlying,
        bet_type     => 'FLASHU',
        currency     => $currency,
        payout       => 1000,
        date_start   => $now,
        date_expiry  => $now->epoch + 300,
        current_tick => $tick,
        barrier      => 'S0P',
    });

    my $new_transaction5 = BOM::Product::Transaction->new({
        client   => $client,
        contract => $new_contract5,
    });

    $error = $new_transaction->_validate_jurisdictional_restrictions;
    is($error, undef, 'British clients are allowed to trade random underlyings');

    # check if market name is allowed for landing company
    $new_underlying = BOM::Market::Underlying->new('R50');
    $new_contract   = produce_contract({
        underlying   => $new_underlying,
        bet_type     => 'FLASHU',
        currency     => $currency,
        payout       => 1000,
        date_start   => $now,
        date_expiry  => $now->epoch + 300,
        current_tick => $tick,
        barrier      => 'S0P',
    });

    $new_transaction = BOM::Product::Transaction->new({
        client   => $client,
        contract => $new_contract,
    });

    $error = $new_transaction->_validate_jurisdictional_restrictions;
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

    my $transaction = BOM::Product::Transaction->new({
        client   => $client,
        contract => $contract,
    });

    my $error = $transaction->_validate_client_status;
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

    my $transaction = BOM::Product::Transaction->new({
        client   => $client,
        contract => $contract,
    });

    my $error = $transaction->_validate_client_status;
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
