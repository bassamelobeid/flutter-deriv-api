#!/usr/bin/perl

use strict;
use warnings;

use Test::MockTime qw/:all/;
use Test::MockModule;
use Test::More;    # tests => 4;
use Test::NoWarnings ();    # no END block test
use Test::Exception;
use Guard;
use BOM::Platform::Client;
use BOM::System::Password;
use BOM::Platform::Client::Utility;
use BOM::Platform::Static::Config;

use BOM::Product::Transaction;
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
my $requestmod = Test::MockModule->new('BOM::Platform::Context::Request');
$requestmod->mock('session_cookie', sub { return bless({token => 1}, 'BOM::Platform::SessionCookie'); });

use Crypt::NamedKeys;
Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';

my $now = Date::Utility->new;
BOM::Test::Data::Utility::UnitTestMarketData::create_doc('currency', {symbol => $_}) for ('EUR', 'USD', 'JPY', 'JPY-EUR', 'EUR-JPY', 'EUR-USD');
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
    'currency',
    {
        symbol => $_,
        date   => Date::Utility->new,
    }) for (qw/USD EUR JPY JPY-USD/);

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

my $underlying        = BOM::Market::Underlying->new('frxUSDJPY');
my $underlying_GDAXI  = BOM::Market::Underlying->new('GDAXI');
my $underlying_WLDUSD = BOM::Market::Underlying->new('WLDUSD');
my $underlying_R50    = BOM::Market::Underlying->new('R_50');

sub db {
    return BOM::Database::ClientDB->new({
            broker_code => 'CR',
        })->db;
}

sub create_client {
    return BOM::Platform::Client->register_and_return_new_client({
        broker_code      => 'CR',
        client_password  => BOM::System::Password::hashpw('12345678'),
        salutation       => 'Ms',
        last_name        => 'Doe',
        first_name       => 'Jane' . time . '.' . int(rand 1000000000),
        email            => 'jane.doe' . time . '.' . int(rand 1000000000) . '@test.domain.nowhere',
        residence        => 'in',
        address_line_1   => '298b md rd',
        address_line_2   => '',
        address_city     => 'Place',
        address_postcode => '65432',
        address_state    => 'st',
        phone            => '+9145257468',
        secret_question  => 'What the f***?',
        secret_answer    => BOM::Platform::Client::Utility::encrypt_secret_answer('is that'),
        date_of_birth    => '1945-08-06',
    });
}

sub top_up {
    my ($c, $cur, $amount) = @_;

    my $fdp = $c->is_first_deposit_pending;
    my @acc = $c->account;
    if (@acc) {
        @acc = grep { $_->currency_code eq $cur } @acc;
        @acc = $c->add_account({
                currency_code => $cur,
                is_default    => 0
            }) unless @acc;
    } else {
        @acc = $c->add_account({
            currency_code => $cur,
            is_default    => 1
        });
    }

    my $acc = $acc[0];
    unless (defined $acc->id) {
        $acc->save;
        note 'Created account ' . $acc->id . ' for ' . $c->loginid . ' segment ' . $cur;
    }

    my ($pm) = $acc->add_payment({
        amount               => $amount,
        payment_gateway_code => "legacy_payment",
        payment_type_code    => "ewallet",
        status               => "OK",
        staff_loginid        => "test",
        remark               => __FILE__ . ':' . __LINE__,
    });
    $pm->legacy_payment({legacy_type => "ewallet"});
    my ($trx) = $pm->add_transaction({
        account_id    => $acc->id,
        amount        => $amount,
        staff_loginid => "test",
        remark        => __FILE__ . ':' . __LINE__,
        referrer_type => "payment",
        action_type   => ($amount > 0 ? "deposit" : "withdrawal"),
        quantity      => 1,
    });
    $acc->save(cascade => 1);
    $trx->load;    # to re-read (get balance_after)

    BOM::Platform::Client::IDAuthentication->new(client => $c)->run_authentication
        if $fdp;

    note $c->loginid . "'s balance is now $cur " . $trx->balance_after . "\n";
}

####################################################################
# real tests begin here
####################################################################

SKIP: {
    skip 'temporarily disabled contracts', 1 if time < Date::Utility->new('2016-01-01')->epoch;

    subtest 'tick_expiry_engine_turnover_limit', sub {
        #plan tests => 13;
        lives_ok {
            my $cl = create_client;

            top_up $cl, 'USD', 5000;

            isnt + (my $acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';

            my $bal;
            is + ($bal = $acc_usd->balance + 0), 5000, 'USD balance is 5000 got: ' . $bal;

            local $ENV{REQUEST_STARTTIME} = time;    # fix race condition
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

            my $txn = BOM::Product::Transaction->new({
                client      => $cl,
                contract    => $contract,
                price       => 50.00,
                payout      => $contract->payout,
                amount_type => 'payout',
            });

            my $error = do {
                my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
                $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

                my $mock_transaction = Test::MockModule->new('BOM::Product::Transaction');
                # _validate_trade_pricing_adjustment() is tested in trade_validation.t
                $mock_transaction->mock(
                    _validate_trade_pricing_adjustment => sub { note "mocked Transaction->_validate_trade_pricing_adjustment returning nothing"; () });
                $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning 'TEST'"; 'TEST' });

                my $class = ref BOM::Platform::Runtime->instance->app_config->quants->client_limits->tick_expiry_engine_daily_turnover;
                (my $fname = $class) =~ s!::!/!g;
                $INC{$fname . '.pm'} = 1;
                my $mock_limits = Test::MockModule->new($class);
                $mock_limits->mock(
                    USD => sub { note "mocked app_config->quants->client_limits->tick_expiry_engine_daily_turnover->USD returning 149.99"; 149.99 });

                is $txn->buy, undef, 'bought 1st contract';
                is $txn->buy, undef, 'bought 2nd contract';

                my $txn = BOM::Product::Transaction->new({
                    client      => $cl,
                    contract    => $contract,
                    price       => 50.00,
                    payout      => $contract->payout,
                    amount_type => 'payout',
                });

                $txn->buy;
            };
            SKIP: {
                skip 'no error', 6
                    unless (defined $error and (isa_ok $error, 'Error::Base'));

                is $error->get_type, 'tick_expiry_engine_turnover_limitExceeded', 'error is tick_expiry_engine_turnover_limit';

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

                my $mock_transaction = Test::MockModule->new('BOM::Product::Transaction');
                # _validate_trade_pricing_adjustment() is tested in trade_validation.t
                $mock_transaction->mock(
                    _validate_trade_pricing_adjustment => sub { note "mocked Transaction->_validate_trade_pricing_adjustment returning nothing"; () });
                $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning 'TEST'"; 'TEST' });

                my $class = ref BOM::Platform::Runtime->instance->app_config->quants->client_limits->tick_expiry_engine_daily_turnover;
                (my $fname = $class) =~ s!::!/!g;
                $INC{$fname . '.pm'} = 1;
                my $mock_limits = Test::MockModule->new($class);
                $mock_limits->mock(
                    USD => sub { note "mocked app_config->quants->client_limits->tick_expiry_engine_daily_turnover->USD returning 150"; 150 });

                # create a new transaction object to get pristine (undef) contract_id and the like
                $txn = BOM::Product::Transaction->new({
                    client      => $cl,
                    contract    => $contract,
                    price       => 50.00,
                    payout      => $contract->payout,
                    amount_type => 'payout',
                });

                $txn->buy;
            };
            is $error, undef, 'exactly matching the limit ==> successful buy';
        }
        'survived';
    };
};

subtest 'asian_daily_turnover_limit', sub {
    plan tests => 13;
    lives_ok {
        my $cl = create_client;

        top_up $cl, 'USD', 5000;

        isnt + (my $acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';

        my $bal;
        is + ($bal = $acc_usd->balance + 0), 5000, 'USD balance is 5000 got: ' . $bal;

        local $ENV{REQUEST_STARTTIME} = time;    # fix race condition
        my $contract = produce_contract({
            underlying   => $underlying,
            bet_type     => 'ASIANU',
            currency     => 'USD',
            payout       => 100,
            duration     => '5m',
            tick_expiry  => 1,
            tick_count   => 5,
            current_tick => $tick,
            barrier      => 'S0P',
        });

        my $txn = BOM::Product::Transaction->new({
            client      => $cl,
            contract    => $contract,
            price       => 50.00,
            payout      => $contract->payout,
            amount_type => 'payout',
        });

        my $error = do {
            my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
            $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

            my $mock_transaction = Test::MockModule->new('BOM::Product::Transaction');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_transaction->mock(
                _validate_trade_pricing_adjustment => sub { note "mocked Transaction->_validate_trade_pricing_adjustment returning nothing"; () });
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning 'TEST'"; 'TEST' });

            my $class = ref BOM::Platform::Runtime->instance->app_config->quants->client_limits->asian_daily_turnover;
            (my $fname = $class) =~ s!::!/!g;
            $INC{$fname . '.pm'} = 1;
            my $mock_limits = Test::MockModule->new($class);
            $mock_limits->mock(
                USD => sub { note "mocked app_config->quants->client_limits->asian_daily_turnover->USD returning 149.99"; 149.99 });

            is $txn->buy, undef, 'bought 1st contract';
            is $txn->buy, undef, 'bought 2nd contract';

            # create a new transaction object to get pristine (undef) contract_id and the like
            $txn = BOM::Product::Transaction->new({
                client      => $cl,
                contract    => $contract,
                price       => 50.00,
                payout      => $contract->payout,
                amount_type => 'payout',
            });

            $txn->buy;
        };
        SKIP: {
            skip 'no error', 6
                unless isa_ok $error, 'Error::Base';

            is $error->get_type, 'asian_turnover_limitExceeded', 'error is asian_turnover_limit';

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

            my $mock_transaction = Test::MockModule->new('BOM::Product::Transaction');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_transaction->mock(
                _validate_trade_pricing_adjustment => sub { note "mocked Transaction->_validate_trade_pricing_adjustment returning nothing"; () });
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning 'TEST'"; 'TEST' });

            my $class = ref BOM::Platform::Runtime->instance->app_config->quants->client_limits->asian_daily_turnover;
            (my $fname = $class) =~ s!::!/!g;
            $INC{$fname . '.pm'} = 1;
            my $mock_limits = Test::MockModule->new($class);
            $mock_limits->mock(
                USD => sub { note "mocked app_config->quants->client_limits->asian_daily_turnover->USD returning 150"; 150 });

            # create a new transaction object to get pristine (undef) contract_id and the like
            $txn = BOM::Product::Transaction->new({
                client      => $cl,
                contract    => $contract,
                price       => 50.00,
                payout      => $contract->payout,
                amount_type => 'payout',
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

        isnt + (my $acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';

        my $bal;
        is + ($bal = $acc_usd->balance + 0), 5000, 'USD balance is 5000 got: ' . $bal;

        local $ENV{REQUEST_STARTTIME} = time;    # fix race condition
        my $contract = produce_contract({
            underlying   => $underlying_GDAXI,
            bet_type     => 'CALL',
            currency     => 'USD',
            payout       => 100,
            date_start   => $now->epoch + 10,
            date_expiry  => $now->epoch + 15,
            current_tick => $tick,
            barrier      => 'S0P',
        });

        my $txn = BOM::Product::Transaction->new({
            client      => $cl,
            contract    => $contract,
            price       => 50.00,
            payout      => $contract->payout,
            amount_type => 'payout',
        });

        my $error = do {
            my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
            $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });
            $mock_contract->mock(
                pricing_engine_name => sub {
                    note "mocked Contract->pricing_engine_name returning 'BOM::Product::Pricing::Engine::Intraday::Index'";
                    'BOM::Product::Pricing::Engine::Intraday::Index';
                });

            my $mock_transaction = Test::MockModule->new('BOM::Product::Transaction');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_transaction->mock(
                _validate_trade_pricing_adjustment => sub { note "mocked Transaction->_validate_trade_pricing_adjustment returning nothing"; () });
            $mock_transaction->mock(_validate_stake_limit  => sub { note "mocked Transaction->_validate_stake_limit returning nothing";  () });
            $mock_transaction->mock(_validate_date_pricing => sub { note "mocked Transaction->_validate_date_pricing returning nothing"; () });
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning 'TEST'"; 'TEST' });

            note "mocked quants->{client_limits}->{intraday_spot_index_turnover_limit}->{USD} returning 149.99";
            BOM::Platform::Static::Config::quants->{client_limits}->{intraday_spot_index_turnover_limit}->{USD} = 149.99;

            is $txn->buy, undef, 'bought 1st contract';
            is $txn->buy, undef, 'bought 2nd contract';

            # create a new transaction object to get pristine (undef) contract_id and the like
            $txn = BOM::Product::Transaction->new({
                client      => $cl,
                contract    => $contract,
                price       => 50.00,
                payout      => $contract->payout,
                amount_type => 'payout',
            });

            $txn->buy;
        };
        SKIP: {
            skip 'no error', 6
                unless isa_ok $error, 'Error::Base';

            is $error->get_type, 'intraday_spot_index_turnover_limitExceeded', 'error is intraday_spot_index_turnover_limit';

            is $error->{-message_to_client}, 'You have exceeded the daily limit for contracts of this type.', 'message_to_client';
            is $error->{-mesg},              'Exceeds turnover limit on intraday_spot_index_turnover_limit',  'mesg';

            is $txn->contract_id,    undef, 'txn->contract_id';
            is $txn->transaction_id, undef, 'txn->transaction_id';
            is $txn->balance_after,  undef, 'txn->balance_after';
        }

        # now matching exactly the limit -- should succeed
        $error = do {
            my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
            $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });
            $mock_contract->mock(
                pricing_engine_name => sub {
                    note "mocked Contract->pricing_engine_name returning 'BOM::Product::Pricing::Engine::Intraday::Index'";
                    'BOM::Product::Pricing::Engine::Intraday::Index';
                });

            my $mock_transaction = Test::MockModule->new('BOM::Product::Transaction');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_transaction->mock(
                _validate_trade_pricing_adjustment => sub { note "mocked Transaction->_validate_trade_pricing_adjustment returning nothing"; () });
            $mock_transaction->mock(_validate_stake_limit  => sub { note "mocked Transaction->_validate_stake_limit returning nothing";  () });
            $mock_transaction->mock(_validate_date_pricing => sub { note "mocked Transaction->_validate_date_pricing returning nothing"; () });
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning 'TEST'"; 'TEST' });

            note "mocked quants->{client_limits}->{intraday_spot_index_turnover_limit}->{USD} returning 150";
            BOM::Platform::Static::Config::quants->{client_limits}->{intraday_spot_index_turnover_limit}->{USD} = 150;

            # create a new transaction object to get pristine (undef) contract_id and the like
            $txn = BOM::Product::Transaction->new({
                client      => $cl,
                contract    => $contract,
                price       => 50.00,
                payout      => $contract->payout,
                amount_type => 'payout',
            });

            $txn->buy;
        };
        is $error, undef, 'exactly matching the limit ==> successful buy';
    }
    'survived';
};

subtest 'smartfx_turnover_limit', sub {
    plan tests => 13;
    lives_ok {
        my $cl = create_client;

        top_up $cl, 'USD', 5000;

        isnt + (my $acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';

        my $bal;
        is + ($bal = $acc_usd->balance + 0), 5000, 'USD balance is 5000 got: ' . $bal;

        local $ENV{REQUEST_STARTTIME} = time;    # fix race condition
        my $contract = produce_contract({
            underlying   => $underlying_WLDUSD,
            bet_type     => 'CALL',
            currency     => 'USD',
            payout       => 100,
            duration     => '5m',
            tick_expiry  => 1,
            tick_count   => 5,
            current_tick => $tick,
            barrier      => 'S0P',
        });

        my $txn = BOM::Product::Transaction->new({
            client      => $cl,
            contract    => $contract,
            price       => 50.00,
            payout      => $contract->payout,
            amount_type => 'payout',
        });

        my $error = do {
            my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
            $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

            my $mock_transaction = Test::MockModule->new('BOM::Product::Transaction');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_transaction->mock(
                _validate_trade_pricing_adjustment => sub { note "mocked Transaction->_validate_trade_pricing_adjustment returning nothing"; () });
            $mock_transaction->mock(_validate_stake_limit => sub { note "mocked Transaction->_validate_stake_limit returning nothing"; () });
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning 'TEST'"; 'TEST' });

            note "mocked BOM::Platform::Static::Config::quants->{client_limits}->{smartfx_turnover_limit}->{USD} returning 149.99";
            my $class = ref BOM::Platform::Runtime->instance->app_config->quants->client_limits;
            (my $fname = $class) =~ s!::!/!g;
            $INC{$fname . '.pm'} = 1;
            # This mocked should be removed the turnover limit on Master Live Server.
            my $mock_limits = Test::MockModule->new($class);
            $mock_limits->mock(tick_expiry_engine_turnover_limit =>
                    sub { note "mocked app_config->quants->client_limits->tick_expiry_engine_turnover_limit returning 149.99"; {USD =>150.01} });
            note "mocked BOM::Platform::Static::Config::quants->{client_limits}->{tick_expiry_engine_turnover_limit}->{USD} returning 149.99";
            BOM::Platform::Static::Config::quants->{client_limits}->{smartfx_turnover_limit}->{USD} = 149.99;

            is $txn->buy, undef, 'bought 1st contract';
            is $txn->buy, undef, 'bought 2nd contract';

            # create a new transaction object to get pristine (undef) contract_id and the like
            $txn = BOM::Product::Transaction->new({
                client      => $cl,
                contract    => $contract,
                price       => 50.00,
                payout      => $contract->payout,
                amount_type => 'payout',
            });

            $txn->buy;
        };
        SKIP: {
            skip 'no error', 6
                unless isa_ok $error, 'Error::Base';

            is $error->get_type, 'smartfx_turnover_limitExceeded', 'error is smartfx_turnover_limit';

            is $error->{-message_to_client}, 'You have exceeded the daily limit for contracts of this type.', 'message_to_client';
            is $error->{-mesg}, 'Exceeds turnover limit on smartfx_turnover_limit', 'mesg';

            is $txn->contract_id,    undef, 'txn->contract_id';
            is $txn->transaction_id, undef, 'txn->transaction_id';
            is $txn->balance_after,  undef, 'txn->balance_after';
        }

        # now matching exactly the limit -- should succeed
        $error = do {
            my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
            $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

            my $mock_transaction = Test::MockModule->new('BOM::Product::Transaction');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_transaction->mock(
                _validate_trade_pricing_adjustment => sub { note "mocked Transaction->_validate_trade_pricing_adjustment returning nothing"; () });
            $mock_transaction->mock(_validate_stake_limit => sub { note "mocked Transaction->_validate_stake_limit returning nothing"; () });
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning 'TEST'"; 'TEST' });

            my $class = ref BOM::Platform::Runtime->instance->app_config->quants->client_limits;
            (my $fname = $class) =~ s!::!/!g;
            $INC{$fname . '.pm'} = 1;
            # This mocked should be removed the turnover limit on Master Live Server.
            my $mock_limits = Test::MockModule->new($class);
            $mock_limits->mock(tick_expiry_engine_turnover_limit =>
                    sub { note "mocked app_config->quants->client_limits->tick_expiry_engine_turnover_limit returning 149.99"; {USD => 150.01} });
            note "mocked BOM::Platform::Static::Config::quants->{client_limits}->{smartfx_turnover_limit}->{USD} returning 150";
            BOM::Platform::Static::Config::quants->{client_limits}->{smartfx_turnover_limit}->{USD} = 150;

            # create a new transaction object to get pristine (undef) contract_id and the like
            $txn = BOM::Product::Transaction->new({
                client      => $cl,
                contract    => $contract,
                price       => 50.00,
                payout      => $contract->payout,
                amount_type => 'payout',
            });

            $txn->buy;
        };
        is $error, undef, 'exactly matching the limit ==> successful buy';
    }
    'survived';
};

subtest 'spreads', sub {
    plan tests => 13;
    lives_ok {
        my $cl = create_client;

        top_up $cl, 'USD', 5000;

        isnt + (my $acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';

        my $bal;
        is + ($bal = $acc_usd->balance + 0), 5000, 'USD balance is 5000 got: ' . $bal;

        local $ENV{REQUEST_STARTTIME} = time;    # fix race condition
        my $contract = produce_contract({
            underlying       => 'R_100',
            bet_type         => 'SPREADU',
            currency         => 'USD',
            amount_per_point => 2,
            stop_loss        => 10,
            stop_profit      => 10,
            stop_type        => 'point',
            spread           => 2,
        });

        my $txn = BOM::Product::Transaction->new({
            client   => $cl,
            contract => $contract,
            price    => 20.00,
        });

        my $error = do {
            my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
            $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

            my $mock_transaction = Test::MockModule->new('BOM::Product::Transaction');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_transaction->mock(
                _validate_trade_pricing_adjustment => sub { note "mocked Transaction->_validate_trade_pricing_adjustment returning nothing"; () });
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning 'TEST'"; 'TEST' });

            my $class = ref BOM::Platform::Runtime->instance->app_config->quants->client_limits->spreads_daily_profit;
            (my $fname = $class) =~ s!::!/!g;
            $INC{$fname . '.pm'} = 1;
            my $mock_limits = Test::MockModule->new($class);
            $mock_limits->mock(
                USD => sub { note "mocked app_config->quants->client_limits->spreads_daily_profit->USD returning 59.00"; 59.00 });

            is $txn->buy, undef, 'bought 1st contract';
            is $txn->buy, undef, 'bought 2nd contract';

            # create a new transaction object to get pristine (undef) contract_id and the like
            $contract = produce_contract({
                underlying       => 'R_100',
                bet_type         => 'SPREADU',
                currency         => 'USD',
                amount_per_point => 2,
                stop_loss        => 10,
                stop_profit      => 10,
                stop_type        => 'point',
                spread           => 2,
            });
            $txn = BOM::Product::Transaction->new({
                client   => $cl,
                contract => $contract,
            });

            $txn->buy;
        };

        SKIP: {
            skip 'no error', 6
                unless isa_ok $error, 'Error::Base';

            is $error->get_type, 'SpreadDailyProfitLimitExceeded', 'error is SpreadDailyProfitLimitExceeded';

            is $error->{-message_to_client}, 'You have exceeded the daily limit for contracts of this type.', 'message_to_client';
            is $error->{-mesg}, 'Exceeds profit limit on spread', 'mesg';

            is $txn->contract_id,    undef, 'txn->contract_id';
            is $txn->transaction_id, undef, 'txn->transaction_id';
            is $txn->balance_after,  undef, 'txn->balance_after';
        }
        # now matching exactly the limit -- should succeed
        $error = do {
            my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
            $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

            my $mock_transaction = Test::MockModule->new('BOM::Product::Transaction');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_transaction->mock(
                _validate_trade_pricing_adjustment => sub { note "mocked Transaction->_validate_trade_pricing_adjustment returning nothing"; () });
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning 'TEST'"; 'TEST' });

            my $class = ref BOM::Platform::Runtime->instance->app_config->quants->client_limits->spreads_daily_profit;
            (my $fname = $class) =~ s!::!/!g;
            $INC{$fname . '.pm'} = 1;
            my $mock_limits = Test::MockModule->new($class);
            $mock_limits->mock(
                USD => sub { note "mocked app_config->quants->client_limits->spreads_daily_profit->USD returning 60.00"; 60.00 });

            # create a new transaction object to get pristine (undef) contract_id and the like
            $txn = BOM::Product::Transaction->new({
                client   => $cl,
                contract => $contract,
                price    => 20,
            });

            $txn->buy;
        };
        is $error, undef, 'exactly matching the limit ==> successful buy';
    }
    'survived';
};
# see further transaction.t:  many more tests
#             transaction2.t: special turnover limits

Test::NoWarnings::had_no_warnings;

done_testing;
