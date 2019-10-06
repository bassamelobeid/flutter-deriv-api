#!/etc/rmg/bin/perl

use strict;
use warnings;

use JSON::MaybeXS;
use Test::MockTime qw/:all/;
use Test::MockModule;
use Test::More;    # tests => 4;
use Test::Exception;
use Guard;
use BOM::User::Client;
use BOM::User::Password;

use BOM::Platform::Client::IDAuthentication;

use BOM::Transaction;
use BOM::Transaction::Validation;
use BOM::Product::ContractFactory qw( produce_contract make_similar_contract);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Helper::Client qw(create_client top_up);

use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;

use Crypt::NamedKeys;

my $json   = JSON::MaybeXS->new;
my $mocked = Test::MockModule->new('BOM::Market::DataDecimate');
$mocked->mock(
    'get',
    sub {
        [map { {decimate_epoch => $_, epoch => $_, quote => 100 + rand(0.1)} } (0 .. 80)];
    });

Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';

my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');

$mock_validation->mock(validate_tnc => sub { note "mocked Transaction::Validation->validate_tnc returning nothing"; undef });

my $now = Date::Utility->new;
BOM::Test::Data::Utility::UnitTestMarketData::create_doc('currency', {symbol => $_})
    for ('EUR', 'USD', 'JPY', 'JPY-EUR', 'EUR-JPY', 'EUR-USD', 'WLDUSD');
# dies if no economic events is in place.
# Not going to fix the problem in this branch.
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'economic_events',
    {
        recorded_date => $now,
        events        => [{
                symbol       => 'USD',
                release_date => $now->minus_time_interval('3h')->epoch,
                impact       => 5,
                event_name   => 'Unemployment Rate',
            }]});
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => $_,
        recorded_date => $now
    }) for ('frxEURUSD', 'frxEURJPY');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'index',
    {
        symbol => 'WLDUSD',
        date   => Date::Utility->new,
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'index',
    {
        symbol => 'R_100',
        date   => Date::Utility->new,
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'index',
    {
        symbol => 'GDAXI',
        date   => Date::Utility->new,
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => $_,
        date   => Date::Utility->new,
    }) for (qw/USD EUR JPY JPY-USD/);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_moneyness',
    {
        symbol        => 'GDAXI',
        recorded_date => Date::Utility->new,
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'correlation_matrix',
    {
        recorded_date => Date::Utility->new,
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => $_,
        recorded_date => Date::Utility->new,
    }) for qw/frxUSDJPY WLDUSD/;

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'R_50',
        recorded_date => Date::Utility->new,
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'randomindex',
    {
        symbol => 'R_50',
        date   => Date::Utility->new,
    });

initialize_realtime_ticks_db();

my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch,
    underlying => 'frxUSDJPY',
});

my $underlying        = create_underlying('frxUSDJPY');
my $underlying_GDAXI  = create_underlying('GDAXI');
my $underlying_WLDUSD = create_underlying('WLDUSD');
my $underlying_R50    = create_underlying('R_50');

sub db {
    return BOM::Database::ClientDB->new({
            broker_code => 'CR',
        })->db;
}

####################################################################
# real tests begin here
####################################################################

subtest 'tick_expiry_engine_turnover_limit', sub {
    plan tests => 12;
    lives_ok {
        my $cl = create_client;

        top_up $cl, 'USD', 5000;

        isnt + (my $acc_usd = $cl->account), 'USD', 'got USD account';

        my $bal;
        is + ($bal = $acc_usd->balance + 0), 5000, 'USD balance is 5000 got: ' . $bal;

        note("tick_expiry_engine_daily_turnover's risk type is high_risk");
        note("mocked high_risk USD limit to 149.99");
        BOM::Config::quants()->{risk_profile}{high_risk}{turnover}{USD} = 149.99;
        my $contract = produce_contract({
            underlying   => $underlying,
            bet_type     => 'CALL',
            currency     => 'USD',
            payout       => 100,
            duration     => '5m',
            tick_expiry  => 1,
            tick_count   => 5,
            current_tick => $tick,
            barrier      => 'S0P',
        });

        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 50.00,
            payout        => $contract->payout,
            amount_type   => 'payout',
            purchase_date => $contract->date_start,
        });

        my $error = do {
            my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
            $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

            my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_validation->mock(_validate_trade_pricing_adjustment =>
                    sub { note "mocked Transaction::Validation->_validate_trade_pricing_adjustment returning nothing"; () });
            $mock_validation->mock(_validate_offerings => sub { note "mocked Transaction::Validation->_validate_offerings returning nothing"; () });

            my $mock_transaction = Test::MockModule->new('BOM::Transaction');
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning '[]'"; [] });

            note('mocking custom_product_limits');
            my $new = {
                xxx => {
                    "expiry_type"       => "tick",
                    "start_type"        => "spot",
                    "contract_category" => "callput",
                    "market"            => "forex",
                    "risk_profile"      => "high_risk",
                    "name"              => "tick_expiry_engine_turnover_limit"
                }};

            BOM::Config::Runtime->instance->app_config->quants->custom_product_profiles($json->encode($new));

            is $txn->buy, undef, 'bought 1st contract';
            is $txn->buy, undef, 'bought 2nd contract';

            $txn = BOM::Transaction->new({
                client        => $cl,
                contract      => $contract,
                price         => 50.00,
                payout        => $contract->payout,
                amount_type   => 'payout',
                purchase_date => $contract->date_start,
            });

            $txn->buy;
        };
        SKIP: {
            skip 'no error', 6
                if (not defined $error or ref $error ne 'Error::Base');

            is $error->get_type, 'ProductSpecificTurnoverLimitExceeded', 'error is ProductSpecificTurnoverLimitExceeded';

            is $error->{-message_to_client}, 'You have exceeded the daily limit for contracts of this type.', 'message_to_client';
            is $error->{-mesg},              'Exceeds turnover limit on tick_expiry_engine_turnover_limit',   'mesg';

            is $txn->contract_id,    undef, 'txn->contract_id';
            is $txn->transaction_id, undef, 'txn->transaction_id';
            is $txn->balance_after,  undef, 'txn->balance_after';
        }

        # now matching exactly the limit -- should succeed
        $error = do {
            my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
            $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

            my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_validation->mock(_validate_trade_pricing_adjustment =>
                    sub { note "mocked Transaction::Validation->_validate_trade_pricing_adjustment returning nothing"; () });
            $mock_validation->mock(_validate_offerings => sub { note "mocked Transaction::Validation->_validate_offerings returning nothing"; () });

            my $mock_transaction = Test::MockModule->new('BOM::Transaction');
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning '[]'"; [] });

            note("mocked high_risk USD limit to 150");
            BOM::Config::quants()->{risk_profile}{high_risk}{turnover}{USD} = 150.00;

            $contract = make_similar_contract($contract);
            # create a new transaction object to get pristine (undef) contract_id and the like
            $txn = BOM::Transaction->new({
                client        => $cl,
                contract      => $contract,
                price         => 50.00,
                payout        => $contract->payout,
                amount_type   => 'payout',
                purchase_date => $contract->date_start,
            });
            $txn->buy;
        };
        is $error, undef, 'exactly matching the limit ==> successful buy';
    }
    'survived';
};

subtest 'asian_daily_turnover_limit', sub {
    plan tests => 12;
    lives_ok {
        my $cl = create_client;

        top_up $cl, 'USD', 5000;

        isnt + (my $acc_usd = $cl->account), 'USD', 'got USD account';

        my $bal;
        is + ($bal = $acc_usd->balance + 0), 5000, 'USD balance is 5000 got: ' . $bal;

        note("asian_turnover_limit's risk type is high_risk");
        note("mocked high_risk USD limit to 149.99");
        BOM::Config::quants()->{risk_profile}{high_risk}{turnover}{USD} = 149.99;
        my $contract = produce_contract({
            underlying   => 'R_100',
            bet_type     => 'ASIANU',
            currency     => 'USD',
            payout       => 100,
            duration     => '5m',
            tick_expiry  => 1,
            tick_count   => 5,
            current_tick => $tick,
        });

        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 50.00,
            payout        => $contract->payout,
            amount_type   => 'payout',
            purchase_date => $contract->date_start,
        });

        my $error = do {
            my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
            $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

            my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_validation->mock(_validate_trade_pricing_adjustment =>
                    sub { note "mocked Transaction::Validation->_validate_trade_pricing_adjustment returning nothing"; () });
            $mock_validation->mock(_validate_offerings => sub { note "mocked Transaction::Validation->_validate_offerings returning nothing"; () });

            my $mock_transaction = Test::MockModule->new('BOM::Transaction');
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning '[]'"; [] });

            note('mocking custom_product_limits');
            my $new = {
                xxx => {
                    "expiry_type"       => "tick",
                    "contract_category" => "asian",
                    "risk_profile"      => "high_risk",
                    "name"              => "asian_turnover_limit"
                }};

            BOM::Config::Runtime->instance->app_config->quants->custom_product_profiles($json->encode($new));

            is $txn->buy, undef, 'bought 1st contract';
            is $txn->buy, undef, 'bought 2nd contract';

            # create a new transaction object to get pristine (undef) contract_id and the like
            $txn = BOM::Transaction->new({
                client        => $cl,
                contract      => $contract,
                price         => 50.00,
                payout        => $contract->payout,
                amount_type   => 'payout',
                purchase_date => $contract->date_start,
            });

            $txn->buy;
        };

        SKIP: {
            skip 'no error', 6
                if (not defined $error or ref $error ne 'Error::Base');

            is $error->get_type, 'ProductSpecificTurnoverLimitExceeded', 'error is ProductSpecificTurnoverLimitExceeded';

            is $error->{-message_to_client}, 'You have exceeded the daily limit for contracts of this type.', 'message_to_client';
            is $error->{-mesg}, 'Exceeds turnover limit on asian_turnover_limit', 'mesg';

            is $txn->contract_id,    undef, 'txn->contract_id';
            is $txn->transaction_id, undef, 'txn->transaction_id';
            is $txn->balance_after,  undef, 'txn->balance_after';
        }

        # now matching exactly the limit -- should succeed
        $error = do {
            my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
            $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

            my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_validation->mock(_validate_trade_pricing_adjustment =>
                    sub { note "mocked Transaction::Validation->_validate_trade_pricing_adjustment returning nothing"; () });
            $mock_validation->mock(_validate_offerings => sub { note "mocked Transaction::Validation->_validate_offerings returning nothing"; () });

            my $mock_transaction = Test::MockModule->new('BOM::Transaction');
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning '[]'"; [] });

            note("mocked high_risk USD limit to 150.00");
            BOM::Config::quants()->{risk_profile}{high_risk}{turnover}{USD} = 150.00;

            $contract = make_similar_contract($contract);
            # create a new transaction object to get pristine (undef) contract_id and the like
            $txn = BOM::Transaction->new({
                client        => $cl,
                contract      => $contract,
                price         => 50.00,
                payout        => $contract->payout,
                amount_type   => 'payout',
                purchase_date => $contract->date_start,
            });

            $txn->buy;
        };
        is $error, undef, 'exactly matching the limit ==> successful buy';
    }
    'survived';
};

subtest 'intraday_spot_index_turnover_limit', sub {
    plan tests => 13;
    lives_ok {
        my $cl = create_client;

        top_up $cl, 'USD', 5000;

        isnt + (my $acc_usd = $cl->account), 'USD', 'got USD account';

        my $bal;
        is + ($bal = $acc_usd->balance + 0), 5000, 'USD balance is 5000 got: ' . $bal;

        note("intraday_spot_index_turnover_limit's risk type is high_risk");
        note("mocked high_risk USD limit to 149.99");
        BOM::Config::quants()->{risk_profile}{high_risk}{turnover}{USD} = 149.99;
        my $contract = produce_contract({
            underlying   => $underlying_GDAXI,
            bet_type     => 'CALL',
            currency     => 'USD',
            payout       => 100,
            date_start   => $now->epoch,
            date_expiry  => $now->epoch + 15 * 60,
            current_tick => $tick,
            barrier      => 'S0P',
        });

        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 50.00,
            payout        => $contract->payout,
            amount_type   => 'payout',
            purchase_date => $contract->date_start,
        });

        my $error = do {
            my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
            $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });
            $mock_contract->mock(
                pricing_engine_name => sub {
                    note "mocked Contract->pricing_engine_name returning 'BOM::Product::Pricing::Engine::Intraday::Index'";
                    'BOM::Product::Pricing::Engine::Intraday::Index';
                });

            my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_validation->mock(_validate_trade_pricing_adjustment =>
                    sub { note "mocked Transaction::Validation->_validate_trade_pricing_adjustment returning nothing"; () });
            $mock_validation->mock(_validate_offerings => sub { note "mocked Transaction::Validation->_validate_offerings returning nothing"; () });
            $mock_validation->mock(
                _validate_date_pricing => sub { note "mocked Transaction::Validation->_validate_date_pricing returning nothing"; () });

            my $mock_transaction = Test::MockModule->new('BOM::Transaction');
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning '[]'"; [] });

            note('mocking custom_product_limits');
            my $new = {
                xxx => {
                    "expiry_type"       => "intraday",
                    "start_type"        => "spot",
                    "market"            => "indices",
                    "contract_category" => "callput",
                    "risk_profile"      => "high_risk",
                    "name"              => "intraday_spot_index_turnover_limit"
                }};

            BOM::Config::Runtime->instance->app_config->quants->custom_product_profiles($json->encode($new));

            is $txn->buy, undef, 'bought 1st contract';
            is $txn->buy, undef, 'bought 2nd contract';

            # create a new transaction object to get pristine (undef) contract_id and the like
            $txn = BOM::Transaction->new({
                client        => $cl,
                contract      => $contract,
                price         => 50.00,
                payout        => $contract->payout,
                amount_type   => 'payout',
                purchase_date => $contract->date_start,
            });

            $txn->buy;
        };

        SKIP: {
            skip 'no error', 6
                if (not defined $error or ref $error ne 'Error::Base');

            is $error->get_type, 'ProductSpecificTurnoverLimitExceeded', 'error is intraday_spot_index_turnover_limit';

            is $error->{-message_to_client}, 'You have exceeded the daily limit for contracts of this type.', 'message_to_client';
            $error->{-mesg} =~ s/\n//g;
            is $error->{-mesg}, 'Exceeds turnover limit on intraday_spot_index_turnover_limit', 'mesg';

            is $txn->contract_id,    undef, 'txn->contract_id';
            is $txn->transaction_id, undef, 'txn->transaction_id';
            is $txn->balance_after,  undef, 'txn->balance_after';
        }

        # can still buy a daily contract
        my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
        $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });
        $mock_contract->mock(
            pricing_engine_name => sub {
                note "mocked Contract->pricing_engine_name returning 'BOM::Product::Pricing::Engine::Intraday::Index'";
                'Pricing::Engine::EuropeanDigitalSlope';
            });
        my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');
        # _validate_trade_pricing_adjustment() is tested in trade_validation.t
        $mock_validation->mock(_validate_trade_pricing_adjustment =>
                sub { note "mocked Transaction::Validation->_validate_trade_pricing_adjustment returning nothing"; () });
        $mock_validation->mock(_validate_offerings    => sub { note "mocked Transaction::Validation->_validate_offerings returning nothing";    () });
        $mock_validation->mock(_validate_date_pricing => sub { note "mocked Transaction::Validation->_validate_date_pricing returning nothing"; () });

        my $mock_transaction = Test::MockModule->new('BOM::Transaction');
        $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning '[]'"; [] });

        my $daily_contract = produce_contract({
            underlying   => $underlying_GDAXI,
            bet_type     => 'CALL',
            currency     => 'USD',
            payout       => 100,
            date_start   => $now->epoch,
            duration     => '3d',
            current_tick => $tick,
            barrier      => 'S0P',
        });
        $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $daily_contract,
            price         => 50.00,
            payout        => $daily_contract->payout,
            amount_type   => 'payout',
            purchase_date => $daily_contract->date_start,
        });

        is $txn->buy, undef, 'can still buy daily';

        # now matching exactly the limit -- should succeed
        $error = do {
            my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
            $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });
            $mock_contract->mock(
                pricing_engine_name => sub {
                    note "mocked Contract->pricing_engine_name returning 'BOM::Product::Pricing::Engine::Intraday::Index'";
                    'BOM::Product::Pricing::Engine::Intraday::Index';
                });
            my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_validation->mock(_validate_trade_pricing_adjustment =>
                    sub { note "mocked Transaction::Validation->_validate_trade_pricing_adjustment returning nothing"; () });
            $mock_validation->mock(_validate_offerings => sub { note "mocked Transaction::Validation->_validate_offerings returning nothing"; () });
            $mock_validation->mock(
                _validate_date_pricing => sub { note "mocked Transaction::Validation->_validate_date_pricing returning nothing"; () });

            my $mock_transaction = Test::MockModule->new('BOM::Transaction');
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning '[]'"; [] });

            note("mocked high_risk USD limit to 150.00");
            BOM::Config::quants()->{risk_profile}{high_risk}{turnover}{USD} = 150.00;
            $contract = make_similar_contract($contract);
            # create a new transaction object to get pristine (undef) contract_id and the like
            $txn = BOM::Transaction->new({
                client        => $cl,
                contract      => $contract,
                price         => 50.00,
                payout        => $contract->payout,
                amount_type   => 'payout',
                purchase_date => $contract->date_start,
            });

            $txn->buy;
        };
        is $error, undef, 'exactly matching the limit ==> successful buy';
    }
    'survived';
};

subtest 'smartfx_turnover_limit', sub {
    plan tests => 12;
    lives_ok {
        my $cl = create_client;

        top_up $cl, 'USD', 5000;

        isnt + (my $acc_usd = $cl->account), 'USD', 'got USD account';

        my $bal;
        is + ($bal = $acc_usd->balance + 0), 5000, 'USD balance is 5000 got: ' . $bal;

        my $contract = produce_contract({
            underlying   => $underlying_WLDUSD,
            bet_type     => 'CALL',
            currency     => 'USD',
            payout       => 100,
            duration     => '5m',
            current_tick => $tick,
            barrier      => 'S0P',
        });

        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 50.00,
            payout        => $contract->payout,
            amount_type   => 'payout',
            purchase_date => $contract->date_start,
        });
        my $error = do {
            my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
            $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });
            my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_validation->mock(_validate_trade_pricing_adjustment =>
                    sub { note "mocked Transaction::Validation->_validate_trade_pricing_adjustment returning nothing"; () });
            $mock_validation->mock(_validate_offerings => sub { note "mocked Transaction::Validation->_validate_offerings returning nothing"; () });

            my $mock_transaction = Test::MockModule->new('BOM::Transaction');
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning '[]'"; [] });

            note("smart_fx_turnover_limit's risk type is high_risk");
            note("mocked high_risk USD limit to 149.99");
            BOM::Config::quants()->{risk_profile}{high_risk}{turnover}{USD} = 149.99;

            is $txn->buy, undef, 'bought 1st contract';
            is $txn->buy, undef, 'bought 2nd contract';

            # create a new transaction object to get pristine (undef) contract_id and the like
            $txn = BOM::Transaction->new({
                client        => $cl,
                contract      => $contract,
                price         => 50.00,
                payout        => $contract->payout,
                amount_type   => 'payout',
                purchase_date => $contract->date_start,
            });

            $txn->buy;
        };
        SKIP: {
            skip 'no error', 6
                if (not defined $error or ref $error ne 'Error::Base');

            is $error->get_type, 'ProductSpecificTurnoverLimitExceeded', 'error is ProductSpecificTurnoverLimitExceeded';

            is $error->{-message_to_client}, 'You have exceeded the daily limit for contracts of this type.', 'message_to_client';
            is $error->{-mesg},              'Exceeds turnover limit on smart_fx_turnover_limit',             'mesg';

            is $txn->contract_id,    undef, 'txn->contract_id';
            is $txn->transaction_id, undef, 'txn->transaction_id';
            is $txn->balance_after,  undef, 'txn->balance_after';
        }

        # now matching exactly the limit -- should succeed
        $error = do {
            my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
            $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

            my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_validation->mock(_validate_trade_pricing_adjustment =>
                    sub { note "mocked Transaction::Validation->_validate_trade_pricing_adjustment returning nothing"; () });
            $mock_validation->mock(_validate_offerings => sub { note "mocked Transaction::Validation->_validate_offerings returning nothing"; () });
            $mock_validation->mock(_validate_stake_limit => sub { note "mocked Transaction::Validation->_validate_stake_limit returning nothing"; () }
            );

            my $mock_transaction = Test::MockModule->new('BOM::Transaction');
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning '[]'"; [] });

            note("mocked high_risk USD limit to 150.00");
            BOM::Config::quants()->{risk_profile}{high_risk}{turnover}{USD} = 150.00;

            $contract = make_similar_contract($contract);
            # create a new transaction object to get pristine (undef) contract_id and the like
            $txn = BOM::Transaction->new({
                client        => $cl,
                contract      => $contract,
                price         => 50.00,
                payout        => $contract->payout,
                amount_type   => 'payout',
                purchase_date => $contract->date_start,
            });
            $txn->buy;
        };
        is $error, undef, 'exactly matching the limit ==> successful buy';
    }
    'survived';
};

subtest 'custom client limit' => sub {
    plan tests => 9;
    lives_ok {
        my $cl = create_client;

        top_up $cl, 'USD', 5000;

        isnt + (my $acc_usd = $cl->account), 'USD', 'got USD account';

        my $bal;
        is + ($bal = $acc_usd->balance + 0), 5000, 'USD balance is 5000 got: ' . $bal;

        note("tick_expiry_engine_daily_turnover's risk type is high_risk");
        note("mocked high_risk USD limit to 149.99");
        BOM::Config::quants()->{risk_profile}{high_risk}{turnover}{USD} = 149.99;
        my $contract = produce_contract({
            underlying   => $underlying,
            bet_type     => 'CALL',
            currency     => 'USD',
            payout       => 100,
            duration     => '5m',
            tick_expiry  => 1,
            tick_count   => 5,
            current_tick => $tick,
            barrier      => 'S0P',
        });

        my $txn = BOM::Transaction->new({
            purchase_date => $contract->date_start,
            client        => $cl,
            contract      => $contract,
            price         => 50.00,
            payout        => $contract->payout,
            amount_type   => 'payout',
        });

        my $error = do {
            my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
            $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

            my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_validation->mock(_validate_trade_pricing_adjustment =>
                    sub { note "mocked Transaction::Validation->_validate_trade_pricing_adjustment returning nothing"; () });
            $mock_validation->mock(_validate_offerings => sub { note "mocked Transaction::Validation->_validate_offerings returning nothing"; () });

            my $mock_transaction = Test::MockModule->new('BOM::Transaction');
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning '[]'"; [] });

            note('mocking custom_product_profiles');
            my $new = {
                xxx => {
                    "expiry_type"       => "tick",
                    "start_type"        => "spot",
                    "contract_category" => "callput",
                    "market"            => "forex",
                    "risk_profile"      => "high_risk",
                    "name"              => "tick_expiry_engine_turnover_limit"
                }};
            BOM::Config::Runtime->instance->app_config->quants->custom_product_profiles($json->encode($new));

            note('mocking custom_client_profiles to no_business profile');
            my $fake = {
                $cl->loginid => {
                    custom_limits => {
                        xxx => {
                            risk_profile => 'no_business',
                            expiry_type  => 'tick'
                        }}
                },
            };
            BOM::Config::Runtime->instance->app_config->quants->custom_client_profiles($json->encode($fake));

            $txn->buy;
        };
        SKIP: {
            skip 'no error', 6
                if (not defined $error or ref $error ne 'Error::Base');

            is $error->get_type, 'NoBusiness', 'error is NoBusiness';

            is $error->{-message_to_client}, 'This contract is unavailable on this account.', 'message_to_client';
            like($error->{-mesg}, qr/^\D+\d+ manually disabled by quants$/, 'mesg');

            is $txn->contract_id,    undef, 'txn->contract_id';
            is $txn->transaction_id, undef, 'txn->transaction_id';
            is $txn->balance_after,  undef, 'txn->balance_after';
        }
    }
    'survived';
};

subtest 'non atm turnover checks' => sub {
    lives_ok {
        my $cl = create_client;

        top_up $cl, 'USD', 5000;

        isnt + (my $acc_usd = $cl->account), 'USD', 'got USD account';

        my $bal;
        is + ($bal = $acc_usd->balance + 0), 5000, 'USD balance is 5000 got: ' . $bal;

        note("sets non_atm tick expiry forex to extreme risk");
        note("mocked extreme_risk USD limit to 149.99");
        BOM::Config::quants()->{risk_profile}{extreme_risk}{turnover}{USD} = 149.99;
        my $contract = produce_contract({
            underlying   => $underlying,
            bet_type     => 'CALL',
            currency     => 'USD',
            payout       => 100,
            duration     => '5t',
            tick_expiry  => 1,
            tick_count   => 5,
            current_tick => $tick,
            barrier      => 'S10P',
        });

        my $txn = BOM::Transaction->new({
            purchase_date => $contract->date_start,
            client        => $cl,
            contract      => $contract,
            price         => 50.00,
            payout        => $contract->payout,
            amount_type   => 'payout',
        });

        my $error = do {
            my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
            $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

            my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_validation->mock(_validate_trade_pricing_adjustment =>
                    sub { note "mocked Transaction::Validation->_validate_trade_pricing_adjustment returning nothing"; () });
            $mock_validation->mock(_validate_offerings => sub { note "mocked Transaction::Validation->_validate_offerings returning nothing"; () });

            my $mock_transaction = Test::MockModule->new('BOM::Transaction');
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning '[]'"; [] });

            note('mocking custom_product_profiles');
            my $new = {
                xxx => {
                    "expiry_type"       => "tick",
                    "start_type"        => "spot",
                    "contract_category" => "callput",
                    "market"            => "forex",
                    "barrier_category"  => "euro_non_atm",
                    "risk_profile"      => "extreme_risk",
                    "name"              => "tick_expiry_nonatm_turnover_limit"
                }};
            BOM::Config::Runtime->instance->app_config->quants->custom_product_profiles($json->encode($new));

            is $txn->buy, undef, 'bought 1st contract';
            is $txn->buy, undef, 'bought 2nd contract';

            my $atm_contract = produce_contract({
                underlying   => $underlying,
                bet_type     => 'CALL',
                currency     => 'USD',
                payout       => 100,
                duration     => '5t',
                tick_expiry  => 1,
                tick_count   => 5,
                current_tick => $tick,
                barrier      => 'S0P',
            });
            $txn = BOM::Transaction->new({
                client        => $cl,
                contract      => $atm_contract,
                price         => 50.00,
                payout        => $atm_contract->payout,
                amount_type   => 'payout',
                purchase_date => $atm_contract->date_start,
            });
            is $txn->buy, undef, 'bought atm tick expiry';
            # create a new transaction object to get pristine (undef) contract_id and the like
            $txn = BOM::Transaction->new({
                client        => $cl,
                contract      => $contract,
                price         => 50.00,
                payout        => $contract->payout,
                amount_type   => 'payout',
                purchase_date => $contract->date_start,
            });

            $txn->buy;
        };

        SKIP: {
            skip 'no error', 6
                if (not defined $error or ref $error ne 'Error::Base');

            is $error->get_type, 'ProductSpecificTurnoverLimitExceeded', 'error is ProductSpecificTurnoverLimitExceeded';

            is $error->{-message_to_client}, 'You have exceeded the daily limit for contracts of this type.', 'message_to_client';
            is $error->{-mesg},              'Exceeds turnover limit on tick_expiry_nonatm_turnover_limit',   'mesg';

            is $txn->contract_id,    undef, 'txn->contract_id';
            is $txn->transaction_id, undef, 'txn->transaction_id';
            is $txn->balance_after,  undef, 'txn->balance_after';
        }

        # now matching exactly the limit -- should succeed
        $error = do {
            my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
            $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

            my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_validation->mock(_validate_trade_pricing_adjustment =>
                    sub { note "mocked Transaction::Validation->_validate_trade_pricing_adjustment returning nothing"; () });
            $mock_validation->mock(_validate_offerings => sub { note "mocked Transaction::Validation->_validate_offerings returning nothing"; () });
            $mock_validation->mock(_validate_stake_limit => sub { note "mocked Transaction::Validation->_validate_stake_limit returning nothing"; () }
            );

            my $mock_transaction = Test::MockModule->new('BOM::Transaction');
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning '[]'"; [] });

            note("mocked extreme_tisk USD limit to 150.00");
            BOM::Config::quants()->{risk_profile}{extreme_risk}{turnover}{USD} = 150.00;

            $contract = make_similar_contract($contract);
            # create a new transaction object to get pristine (undef) contract_id and the like
            $txn = BOM::Transaction->new({
                client        => $cl,
                contract      => $contract,
                price         => 50.00,
                payout        => $contract->payout,
                amount_type   => 'payout',
                purchase_date => $contract->date_start,
            });
            $txn->buy;
        };
        is $error, undef, 'exactly matching the limit ==> successful buy';

    }
    'survived';
};

# see further transaction.t:  many more tests
#             transaction2.t: special turnover limits
my $empty_hashref = {};
BOM::Config::Runtime->instance->app_config->quants->custom_product_profiles($json->encode($empty_hashref));
BOM::Config::Runtime->instance->app_config->quants->custom_client_profiles($json->encode($empty_hashref));

done_testing;
