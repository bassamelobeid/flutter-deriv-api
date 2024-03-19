#!perl

use strict;
use warnings;

use Test::Most tests => 11;
use File::Spec;
use YAML::XS qw(LoadFile);
use Test::Warnings;

use Date::Utility;
use Test::MockObject::Extends;
use Format::Util::Numbers qw(roundcommon);
use Quant::Framework;
use BOM::Config::Chronicle;
use BOM::Test::Data::Utility::UnitTestDatabase   qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase   qw(:init);
use BOM::User::Client;
use BOM::Transaction;
use BOM::Transaction::Validation;
use BOM::Product::ContractFactory           qw( produce_contract make_similar_contract );
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Helper::Client               qw(create_client top_up);
use BOM::Test::Helper::ExchangeRates        qw/populate_exchange_rates/;
use Math::Util::CalculatedValue::Validatable;
use BOM::Config;
use Business::Config::LandingCompany;
use BOM::Test::Helper::FinancialAssessment;
use BOM::User::Script::AMLClientsUpdate;

use JSON::MaybeUTF8 qw(encode_json_utf8);
use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;

use Test::MockModule;

initialize_realtime_ticks_db();

my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');

$mock_validation->mock(check_tax_information => sub { note "mocked Transaction::Validation->check_tax_information returning nothing"; undef });

#create an empty un-used even so ask_price won't fail preparing market data for pricing engine
#Because the code to prepare market data is called for all pricings in Contract
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'economic_events',
    {
        events => [{
                symbol       => 'USD',
                release_date => 1,
                source       => 'forexfactory',
                impact       => 1,
                event_name   => 'FOMC',
            }]});

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => Date::Utility->new,
    }) for (qw/USD JPY GBP JPY-USD/);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'randomindex',
    {
        symbol        => 'R_50',
        recorded_date => Date::Utility->new
    });

my $now         = Date::Utility->new;
my $random_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch,
    underlying => 'R_50',
});

my $client     = BOM::User::Client->new({loginid => 'MX1001'});
my $currency   = 'GBP';
my $account    = $client->default_account;
my $loginid    = $client->loginid;
my $underlying = create_underlying('frxUSDJPY');

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => $_,
        recorded_date => Date::Utility->new($now->epoch - 100),
    }) for qw/frxUSDJPY frxGBPJPY frxGBPUSD/;

my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch,
    underlying => 'frxUSDJPY',
});

populate_exchange_rates();

my $contract = produce_contract({
    underlying  => $underlying,
    bet_type    => 'CALL',
    currency    => $currency,
    payout      => 1000,
    date_start  => $now,
    date_expiry => $now->epoch + 300,
    barrier     => 'S0P',
});

my $mock_call = Test::MockModule->new('BOM::Product::Contract::Call');
subtest 'IOM withdrawal limit' => sub {
    my $withdraw_limit = Business::Config::LandingCompany->new()->payment_limit()->{withdrawal_limits}->{iom}->{limit_for_days};

    $client->payment_free_gift(
        currency     => 'GBP',
        amount       => $withdraw_limit + 2000,
        remark       => 'here is money',
        payment_type => 'free_gift'
    );

    $client->payment_free_gift(
        currency     => 'GBP',
        amount       => -1 * ($withdraw_limit / 2),
        remark       => 'here is money',
        payment_type => 'free_gift'
    );

    my $error;
    lives_ok {
        my $transaction = BOM::Transaction->new({
            client        => $client,
            contract      => $contract,
            purchase_date => Date::Utility->new(),
        });
        $error = BOM::Transaction::Validation->new({
                transaction => $transaction,
                clients     => [$client]})->_validate_iom_withdrawal_limit($client);
    }
    'validate withdrawal limit';
    is($error, undef, 'pass withdrawal limit check');

    $client->payment_free_gift(
        currency     => 'GBP',
        amount       => -1 * ($withdraw_limit / 2 + 1000),
        remark       => 'here is money',
        payment_type => 'free_gift'
    );

    lives_ok {
        my $transaction = BOM::Transaction->new({
            client        => $client,
            contract      => $contract,
            purchase_date => Date::Utility->new(),
        });
        $error = BOM::Transaction::Validation->new({
                transaction => $transaction,
                clients     => [$client]})->_validate_iom_withdrawal_limit($client);
    }
    'validate withdrawal limit';

    is($error->get_type, 'iomWithdrawalLimit', 'unauthenticated IOM client - withdrawal has exceeded limit');
    like(
        $error->{-message_to_client},
        qr/Due to regulatory requirements, you are required to authenticate your account in order to continue trading/,
        'iom client exceeded withdrawal limit msg'
    );
};

subtest 'Is contract valid to buy' => sub {
    my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
    $mock_contract->mock('is_valid_to_buy', sub { 1 });

    $now = Date::Utility->new;
    my $contract1 = produce_contract({
        underlying  => $underlying,
        bet_type    => 'CALL',
        currency    => $currency,
        payout      => 1000,
        date_start  => $now,
        date_expiry => $now->epoch + 500,
        barrier     => 'S0P',
    });

    my $transaction = BOM::Transaction->new({
        client        => $client,
        contract      => $contract1,
        purchase_date => Date::Utility->new(),
    });

    is(
        BOM::Transaction::Validation->new({
                transaction => $transaction,
                clients     => [{client => $client}]}
        )->_is_valid_to_buy($client),
        undef,
        'Contract is valid to buy'
    );

    $mock_contract->unmock_all;

    $contract1->_add_error({
        severity          => 1,
        message           => 'Adding error message',
        message_to_client => 'Error message to be sent to client',
    });

    my $error = BOM::Transaction::Validation->new({
            transaction => $transaction,
            clients     => [{client => $client}]})->_is_valid_to_buy($client);
    is($error->get_type, 'InvalidtoBuy', 'Contract is invalid to buy as it contains errors: _is_valid_to_buy - error type');
    my $db     = BOM::Database::ClientDB->new({broker_code => $client->broker_code})->db;
    my @output = $db->dbh->selectrow_array("select * from data_collection.rejected_trades where action_type = ?", undef, 'buy');
    is $output[1], 'MX1001',                             'client id stored';
    is $output[6], 'Error message to be sent to client', 'correct reason';
};

subtest 'Is contract valid to sell' => sub {
    my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
    $mock_contract->mock('is_valid_to_sell', sub { 1 });

    $now = Date::Utility->new;

    my $contract1 = produce_contract({
        underlying  => $underlying,
        bet_type    => 'CALL',
        currency    => $currency,
        payout      => 1000,
        date_start  => $now,
        date_expiry => $now->epoch + 300,
        barrier     => 'S0P',
    });

    my $transaction = BOM::Transaction->new({
        client        => $client,
        contract      => $contract1,
        purchase_date => Date::Utility->new(),
    });

    is(
        BOM::Transaction::Validation->new({
                transaction => $transaction,
                clients     => [{client => $client}]}
        )->_is_valid_to_sell($client),
        undef,
        'Contract is valid to sell'
    );

    $mock_contract->unmock_all;
    $mock_contract->mock('_validate_trading_times',         sub { undef });
    $mock_contract->mock('_validate_start_and_expiry_date', sub { undef });

    $contract1   = make_similar_contract($contract1, {date_expiry => $now->epoch + 10});
    $transaction = BOM::Transaction->new({
        client        => $client,
        contract      => $contract1,
        purchase_date => Date::Utility->new(),
    });

    my $error = BOM::Transaction::Validation->new({
            transaction => $transaction,
            clients     => [{client => $client}]})->_is_valid_to_sell($client);
    is($error->get_type, 'InvalidtoSell', 'Contract is invalid to sell as expiry is too low: _is_valid_to_sell - error type');

    my $db     = BOM::Database::ClientDB->new({broker_code => $client->broker_code})->db;
    my @output = $db->dbh->selectrow_array("select * from data_collection.rejected_trades where action_type = ?", undef, 'sell');
    is $output[1], 'MX1001',                  'client id stored';
    is $output[6], 'Waiting for entry tick.', 'correct reason';
};

subtest 'contract date pricing Validation' => sub {
    my $now = Date::Utility->new;

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'currency',
        {
            symbol        => $_,
            recorded_date => Date::Utility->new($now->epoch + 300),
        }) for (qw/USD JPY GBP JPY-USD/);

    my $contract = produce_contract({
        underlying   => create_underlying('frxUSDJPY'),
        barrier      => 'S0P',
        bet_type     => 'CALL',
        currency     => 'GBP',
        payout       => 100,
        date_start   => $now,
        date_expiry  => $now->epoch + 300,
        date_pricing => Date::Utility->new($now->epoch - 100),
    });

    my $error;
    lives_ok {
        my $transaction = BOM::Transaction->new({
            client        => $client,
            contract      => $contract,
            purchase_date => Date::Utility->new(),
        });
        $error = BOM::Transaction::Validation->new({
                transaction => $transaction,
                clients     => [$client]})->_validate_date_pricing($client);
    }
    'validate date pricing';

    is($error->get_type, 'InvalidDatePricing', 'Invalid Date Pricing, time has passed > 20 sec from date_pricing');
    like($error->{-message_to_client}, qr/This contract cannot be properly validated at this time/, 'Invalid Date Pricing msg to client');
};

subtest 'valid currency test' => sub {
    my $mock_contract = Test::MockModule->new('BOM::User::Client');

    subtest 'invalid currency' => sub {
        $mock_contract->mock('currency', sub { 'ABC' });

        BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
            'currency',
            {
                symbol        => $_,
                recorded_date => Date::Utility->new($now->epoch - 100),
            }) for (qw/USD JPY GBP JPY-USD/);

        my $contract = produce_contract({
            underlying   => create_underlying('frxUSDJPY'),
            bet_type     => 'CALL',
            currency     => 'EUR',                                   # this can be mocked later on to invalid currency
            payout       => 100,
            date_start   => $now,
            date_expiry  => $now->epoch + 300,
            date_pricing => Date::Utility->new($now->epoch - 100),
            barrier      => 'S0P',
        });

        my $transaction = BOM::Transaction->new({
            client        => $client,
            contract      => $contract,
            purchase_date => Date::Utility->new(),
        });

        my $error = BOM::Transaction::Validation->new({
                transaction => $transaction,
                clients     => [$client]})->_validate_currency($client);

        my $curr = $contract->currency;
        is($error->get_type, 'InvalidCurrency', 'Invalid currency: _validate_currency - error type');
        like($error->{-message_to_client}, qr/The provided currency $curr is invalid./, 'Invalid currency: _validate_currency - error message');
        $mock_contract->unmock('currency');
    };

    subtest 'not default currency for client' => sub {
        BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
            'currency',
            {
                symbol        => $_,
                recorded_date => Date::Utility->new($now->epoch - 100),
            }) for (qw/USD JPY GBP JPY-USD/);

        my $contract = produce_contract({
            underlying   => create_underlying('frxUSDJPY'),
            bet_type     => 'CALL',
            currency     => 'USD',
            payout       => 100,
            date_start   => $now,
            date_expiry  => $now->epoch + 300,
            date_pricing => Date::Utility->new($now->epoch - 100),
            barrier      => 'S0P',
        });

        my $transaction = BOM::Transaction->new({
            client        => $client,
            contract      => $contract,
            purchase_date => Date::Utility->new(),
        });

        my $error = BOM::Transaction::Validation->new({
                transaction => $transaction,
                clients     => [$client]})->_validate_currency($client);

        my $curr   = $contract->currency;
        my $broker = $client->broker;

        is($error->get_type, 'NotDefaultCurrency', 'wrong default currency');
        like($error->{-message_to_client}, qr/The provided currency USD is not the default currency/, 'wrong default currency - error message');
    };
};

subtest 'Purchase Sell Contract' => sub {
    $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'MLT'});
    BOM::User->create(
        email    => 'tset' . $$ . '@test.com',
        password => 'xxx'
    )->add_client($client);

    my $currency = 'USD';
    $client->set_default_account($currency);

    $client->payment_free_gift(
        amount   => 2000,
        remark   => 'free money',
        currency => $currency
    );

    $now = Date::Utility->new;
    my $expiry = $now->plus_time_interval('1d');
    $expiry = $expiry->truncate_to_day->plus_time_interval('23h59m59s');

    my $bet_type = 'CALL';
    $contract = produce_contract({
        underlying   => 'R_50',
        bet_type     => $bet_type,
        currency     => $currency,
        payout       => 100,
        date_start   => Date::Utility->new($now->epoch),
        date_pricing => $now->epoch,
        date_expiry  => $expiry,
        entry_tick   => $random_tick,
        current_tick => $random_tick,
        barrier      => 'S0P',
    });

    my $bpt = BOM::Transaction->new({
        client        => $client,
        contract      => $contract,
        price         => $contract->ask_price,
        amount_type   => 'payout',
        purchase_date => $contract->date_start,
    });

    my $error = $bpt->buy;
    like($error, qr/ASK_TNC_APPROVAL/, 'TNC validation failed');

    my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');

    $mock_validation->mock(validate_tnc => sub { note "mocked Transaction::Validation->validate_tnc returning nothing"; undef });

    $error = $bpt->buy;
    like($error, qr/PleaseAuthenticate/, 'Account authentication validation failed');
    $mock_validation->mock(
        check_authentication_required => sub { note "mocked Transaction::Validation->check_authentication_required returning nothing"; undef });
    $mock_validation->mock(
        check_client_professional => sub { note "mocked Transaction::Validation->check_client_professional returning nothing"; undef });

    $error = $bpt->buy;
    ok $error, 'error thrown when trying to buy contract with malta';
    is($error->{'-mesg'},              'Invalid underlying symbol',              'Invalid underlying symbol');
    is($error->{'-message_to_client'}, 'Trading is not offered for this asset.', 'message to client - Trading is not offered for this asset.');
};

subtest 'validate stake limit' => sub {
    my $contract = produce_contract({
        underlying   => create_underlying('frxUSDJPY'),
        bet_type     => 'CALL',
        currency     => 'GBP',
        payout       => 100,
        date_start   => $now,
        date_expiry  => $now->epoch + 300,
        date_pricing => Date::Utility->new($now->epoch - 100),
        current_tick => $tick,
        barrier      => 'S0P',
    });
    Test::MockObject::Extends->new($contract);
    $contract->mock('ask_price', sub { 0.5 });
    my $transaction = BOM::Transaction->new({
            client        => $client,
            contract      => $contract,
            action        => 'BUY',
            price         => 0.5,
            payout        => 100,
            amount_type   => 'stake',
            purchase_date => $contract->date_start,

    });
    ok !BOM::Transaction::Validation->new({
            transaction => $transaction,
            clients     => [$client]})->_validate_stake_limit($client), 'can buy with minimum stake of 0.5 for non MF broker';
    $contract->mock('ask_price', sub { 0.49 });
    lives_ok {
        my $err = BOM::Transaction::Validation->new({
                transaction => $transaction,
                clients     => [$client]})->_validate_stake_limit($client);
        like($err->{-message_to_client}, qr/This contract's price is/, 'correct error message');
    }
    'error out on 0.49 stake for non MF borker';
    $client   = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'MF'});
    $contract = produce_contract({
        underlying      => create_underlying('frxUSDJPY'),
        bet_type        => 'CALL',
        currency        => 'GBP',
        payout          => 100,
        date_start      => $now,
        date_expiry     => $now->epoch + 300,
        date_pricing    => Date::Utility->new($now->epoch - 100),
        current_tick    => $tick,
        barrier         => 'S0P',
        landing_company => 'maltainvest',
    });
    Test::MockObject::Extends->new($contract);
    $contract->mock('ask_price', sub { 5 });
    $transaction = BOM::Transaction->new({
        client        => $client,
        contract      => $contract,
        action        => 'BUY',
        price         => 5,
        payout        => 100,
        amount_type   => 'stake',
        purchase_date => $contract->date_start,
    });
    ok !BOM::Transaction::Validation->new({
            transaction => $transaction,
            clients     => [$client]})->_validate_stake_limit($client), 'can buy with minimum stake of 5 for MF broker';
    $contract->mock('ask_price', sub { 4.9 });
    lives_ok {
        my $err = BOM::Transaction::Validation->new({
                transaction => $transaction,
                clients     => [$client]})->_validate_stake_limit($client);
        like($err->{-message_to_client}, qr/This contract's price is/, 'correct error message');
    }
    'error out on 4.9 stake for MF borker';
};

subtest 'synthetic_age_verification_check' => sub {

    $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
        residence   => 'id'
    });
    BOM::User->create(
        email    => 'ukgc@test.com',
        password => 'xxx'
    )->add_client($client);

    my $currency = 'USD';
    $client->set_default_account($currency);

    $client->payment_free_gift(
        amount   => 100,
        remark   => 'free money',
        currency => $currency
    );

    $now = Date::Utility->new;
    my $expiry = $now->plus_time_interval('1d');

    my %contract_params = (
        underlying   => 'R_50',
        bet_type     => 'CALL',
        currency     => $currency,
        payout       => 10,
        date_start   => Date::Utility->new($now->epoch),
        date_pricing => $now->epoch,
        date_expiry  => $expiry,
        entry_tick   => $random_tick,
        current_tick => $random_tick,
        barrier      => 'S0P',
    );

    $contract = produce_contract({%contract_params, underlying => 'R_50'});

    my $tx = BOM::Transaction->new({
        client        => $client,
        contract      => $contract,
        price         => $contract->ask_price,
        amount_type   => 'stake',
        purchase_date => $contract->date_start,
    });

    my $mock_countries = Test::MockModule->new('Brands::Countries');
    $mock_countries->mock(countries_list => {id => {require_age_verified_for_synthetic => 1}});

    my $error = $tx->buy;
    is $error->get_type,             'NeedAuthenticateForSynthetic',                                    'error code ok';
    is $error->{-message_to_client}, 'Please authenticate your account to trade on synthetic markets.', 'error message ok';

    my $trading_calendar = Quant::Framework->new->trading_calendar(BOM::Config::Chronicle::get_chronicle_reader);
    my $exchange         = Finance::Exchange->create_exchange('FOREX');
    SKIP: {
        $contract = produce_contract({%contract_params, underlying => 'frxUSDJPY'});

        # We're not checking for if a contract is valid to buy here. We're specifically checking for age verification for synthetic indices.
        # So, it is fine to mock this.
        my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
        $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

        $tx = BOM::Transaction->new({
            client        => $client,
            contract      => $contract,
            price         => $contract->ask_price,
            amount_type   => 'stake',
            purchase_date => $contract->date_start,
        });

        is $tx->buy, undef, 'can buy financial contract ok';
    }

    $client->status->set('age_verification', 'staff', 'testing');

    $contract = produce_contract({%contract_params, underlying => 'R_50'});

    $tx = BOM::Transaction->new({
        client        => $client,
        contract      => $contract,
        price         => $contract->ask_price,
        amount_type   => 'stake',
        purchase_date => $contract->date_start,
    });

    is $tx->buy, undef, 'can buy synthetic contract when age verified';
};

subtest 'high_risk_verification_check CR account' => sub {
    my $broker_code = 'CR';
    my $email       = 'testingcr@test.com';

    $mock_validation->unmock("check_authentication_required");

    $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => $broker_code,
        residence   => 'id'
    });
    BOM::User->create(
        email    => $email,
        password => 'xxx'
    )->add_client($client);

    $client->aml_risk_classification('high');
    $client->save;
    BOM::User::Script::AMLClientsUpdate::update_locks_high_risk_change($client);

    my $currency = 'USD';
    $client->set_default_account($currency);

    $client->payment_free_gift(
        amount   => 100,
        remark   => 'free money',
        currency => $currency
    );

    $now = Date::Utility->new;
    my $expiry = $now->plus_time_interval('1d');

    my %contract_params = (
        underlying   => 'R_50',
        bet_type     => 'CALL',
        currency     => $currency,
        payout       => 10,
        date_start   => Date::Utility->new($now->epoch),
        date_pricing => $now->epoch,
        date_expiry  => $expiry,
        entry_tick   => $random_tick,
        current_tick => $random_tick,
        barrier      => 'S0P',
    );

    $contract = produce_contract({%contract_params, underlying => 'R_50'});

    my $tx = BOM::Transaction->new({
        client        => $client,
        contract      => $contract,
        price         => $contract->ask_price,
        amount_type   => 'stake',
        purchase_date => $contract->date_start,
    });

    my $error = $tx->buy;

    ok !$error, "CR account buy without error.";
    is $client->status->withdrawal_locked->{reason}, 'Pending authentication or FA', 'withdrawal lock applied on high risk';

};

subtest 'standard_risk_verification_check MF account' => sub {
    my $broker_code = 'MF';
    my $email       = 'testingmf@test.com';
    $mock_validation->mock(_bailout_early => sub { note "mocked Transaction::Validation->_bailout_early returning nothing"; undef });

    $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => $broker_code,
        residence   => 'es'
    });
    BOM::User->create(
        email    => $email,
        password => 'xxx'
    )->add_client($client);

    $client->aml_risk_classification('standard');
    $client->save;
    BOM::User::Script::AMLClientsUpdate::update_locks_high_risk_change($client);

    my $currency = 'USD';
    $client->set_default_account($currency);

    $client->payment_free_gift(
        amount   => 100,
        remark   => 'free money',
        currency => $currency
    );

    my %contract_params = (
        underlying   => 'cryBTCUSD',
        bet_type     => 'MULTUP',
        currency     => $currency,
        multiplier   => 50,
        amount       => 10,
        amount_type  => 'stake',
        current_tick => $random_tick,
    );

    $contract = produce_contract({%contract_params, underlying => 'cryBTCUSD'});

    my $tx = BOM::Transaction->new({
        client        => $client,
        contract      => $contract,
        price         => $contract->ask_price,
        amount_type   => 'stake',
        purchase_date => $contract->date_start,
    });

    my $error = $tx->buy;

    is $error->get_type,             'FinancialAssessmentRequired',                                                               'error code ok';
    is $error->{-message_to_client}, 'Please complete the financial assessment form to lift your withdrawal and trading limits.', 'error message ok';
    is $client->status->withdrawal_locked->{reason}, 'FA needs to be completed';

    $client->set_authentication('ID_DOCUMENT', {status => 'pass'});

    my $data = BOM::Test::Helper::FinancialAssessment::get_fulfilled_hash();
    $client->financial_assessment({
        data => encode_json_utf8($data),
    });
    $client->save();

    ok $client->fully_authenticated,              'The account is fully authenticated';
    ok $client->is_financial_assessment_complete, 'The account is FA completed';

    $error = $tx->buy;
    ok !$error, "MF account buy without error when FA completed and fully authenticated.";
};

done_testing();
