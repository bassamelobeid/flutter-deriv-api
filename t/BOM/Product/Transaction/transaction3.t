#!/usr/bin/perl

use strict;
use warnings;

use Test::MockTime qw/:all/;
use Test::MockModule;
use Test::More tests => 4;
use Test::NoWarnings ();    # no END block test
use Test::Exception;
use Guard;
use BOM::Platform::Client;
use BOM::System::Password;
use BOM::Platform::Client::Utility;
use Crypt::NamedKeys;
Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';

use BOM::Product::Transaction;
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

my $requestmod = Test::MockModule->new('BOM::Platform::Context::Request');
$requestmod->mock('session_cookie', sub { return bless({token => 1}, 'BOM::Platform::SessionCookie'); });

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'currency',
    {
        symbol => $_,
        date   => Date::Utility->new,
    }) for (qw/USD JPY GBP/);

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_delta',
    {
        symbol        => $_,
        recorded_date => Date::Utility->new,
    }) for qw/frxUSDJPY frxGBPUSD/;

initialize_realtime_ticks_db();

my $now            = Date::Utility->new;
my $tick_frxUSDJPY = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch,
    underlying => 'frxUSDJPY',
});

my $tick_frxGBPUSD = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch,
    underlying => 'frxGBPUSD',
});

my $underlying_frxUSDJPY = BOM::Market::Underlying->new('frxUSDJPY');
my $underlying_frxGBPUSD = BOM::Market::Underlying->new('frxGBPUSD');

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

subtest 'IntradayLimitExceeded: turnover', sub {
    plan tests => 13;
    lives_ok {
        my $cl = create_client;

        top_up $cl, 'USD', 5000;

        isnt + (my $acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';

        my $bal;
        is + ($bal = $acc_usd->balance + 0), 5000, 'USD balance is 5000 got: ' . $bal;

        local $ENV{REQUEST_STARTTIME} = time;    # fix race condition
        my $contract = produce_contract({
            underlying   => $underlying_frxUSDJPY,
            bet_type     => 'FLASHU',
            currency     => 'USD',
            payout       => 100,
            duration     => '15m',
            current_tick => $tick_frxUSDJPY,
            barrier      => 'S19P',
            # is_atm_bet   => 0,      # fake it
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

            my $class = ref BOM::Platform::Runtime->instance->app_config->quants->client_limits->intraday_forex_iv_turnover;
            (my $fname = $class) =~ s!::!/!g;
            $INC{$fname . '.pm'} = 1;
            my $mock_limits = Test::MockModule->new($class);
            $mock_limits->mock(
                USD => sub { note "mocked app_config->quants->client_limits->intraday_forex_iv_turnover->USD returning 149.99"; 149.99 });

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

            is $error->get_type, 'IntradayLimitExceeded', 'error is IntradayLimitExceeded';

            is $error->{-message_to_client}, 'You have exceeded the daily limit for contracts of this type.', 'message_to_client';
            is $error->{-mesg}, 'Exceeds intraday limit on turnover', 'mesg';

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

            my $class = ref BOM::Platform::Runtime->instance->app_config->quants->client_limits->intraday_forex_iv_turnover;
            (my $fname = $class) =~ s!::!/!g;
            $INC{$fname . '.pm'} = 1;
            my $mock_limits = Test::MockModule->new($class);
            $mock_limits->mock(
                USD => sub { note "mocked app_config->quants->client_limits->intraday_forex_iv_turnover->USD returning 150"; 150 });

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

subtest 'IntradayLimitExceeded: potential profit', sub {
    plan tests => 13;
    lives_ok {
        my $cl = create_client;

        top_up $cl, 'USD', 5000;

        isnt + (my $acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';

        my $bal;
        is + ($bal = $acc_usd->balance + 0), 5000, 'USD balance is 5000 got: ' . $bal;

        local $ENV{REQUEST_STARTTIME} = time;    # fix race condition
        my $contract = produce_contract({
            underlying   => $underlying_frxUSDJPY,
            bet_type     => 'FLASHU',
            currency     => 'USD',
            payout       => 100,
            duration     => '15m',
            current_tick => $tick_frxUSDJPY,
            barrier      => 'S19P',
            # is_atm_bet   => 0,      # fake it
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

            my $class = ref BOM::Platform::Runtime->instance->app_config->quants->client_limits->intraday_forex_iv_potential_profit;
            (my $fname = $class) =~ s!::!/!g;
            $INC{$fname . '.pm'} = 1;
            my $mock_limits = Test::MockModule->new($class);
            $mock_limits->mock(
                USD => sub { note "mocked app_config->quants->client_limits->intraday_forex_iv_potential_profit->USD returning 149.99"; 149.99 });

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

            is $error->get_type, 'IntradayLimitExceeded', 'error is IntradayLimitExceeded';

            is $error->{-message_to_client}, 'You have exceeded the daily limit for contracts of this type.', 'message_to_client';
            is $error->{-mesg}, 'Exceeds intraday limit on potential_profit', 'mesg';

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

            my $class = ref BOM::Platform::Runtime->instance->app_config->quants->client_limits->intraday_forex_iv_potential_profit;
            (my $fname = $class) =~ s!::!/!g;
            $INC{$fname . '.pm'} = 1;
            my $mock_limits = Test::MockModule->new($class);
            $mock_limits->mock(
                USD => sub { note "mocked app_config->quants->client_limits->intraday_forex_iv_potential_profit->USD returning 150"; 150 });

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

subtest 'IntradayLimitExceeded: realized profit', sub {
    plan tests => 15;
    lives_ok {
        my $cl = create_client;

        top_up $cl, 'USD', 5000;

        isnt + (my $acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';

        my $bal;
        is + ($bal = $acc_usd->balance + 0), 5000, 'USD balance is 5000 got: ' . $bal;

        local $ENV{REQUEST_STARTTIME} = time;    # fix race condition
        my $contract = produce_contract({
            underlying   => $underlying_frxUSDJPY,
            bet_type     => 'FLASHU',
            currency     => 'USD',
            payout       => 100,
            duration     => '15m',
            current_tick => $tick_frxUSDJPY,
            barrier      => 'S19P',
        });

        my $contract_for_sell = produce_contract({
            underlying   => $underlying_frxUSDJPY,
            bet_type     => 'FLASHU',
            currency     => 'USD',
            payout       => 100,
            duration     => '15m',
            current_tick => $tick_frxUSDJPY,
            barrier      => 'S19P',
            date_pricing => Date::Utility->new(time + 10),
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

            my $class = ref BOM::Platform::Runtime->instance->app_config->quants->client_limits->intraday_forex_iv_realized_profit;
            (my $fname = $class) =~ s!::!/!g;
            $INC{$fname . '.pm'} = 1;
            my $mock_limits = Test::MockModule->new($class);
            $mock_limits->mock(
                USD => sub { note "mocked app_config->quants->client_limits->intraday_forex_iv_realized_profit->USD returning 59.99"; 59.99 });

            is $txn->buy, undef, 'bought 1st contract';

            my $txn2 = BOM::Product::Transaction->new({
                client      => $cl,
                contract    => $contract_for_sell,
                contract_id => $txn->contract_id,
                price       => 80.00,
            });
            is $txn2->sell(skip_validation => 1), undef, 'sold it';

            is $txn->buy, undef, 'bought 2nd contract';

            $txn2 = BOM::Product::Transaction->new({
                client      => $cl,
                contract    => $contract_for_sell,
                contract_id => $txn->contract_id,
                price       => 80.00,
            });
            is $txn2->sell(skip_validation => 1), undef, 'sold it';

            # create a new transaction object to get pristine (undef) contract_id and the like
            $txn = BOM::Product::Transaction->new({
                client      => $cl,
                contract    => $contract_for_sell,
                price       => 50.00,
                payout      => $contract->payout,
                amount_type => 'payout',
            });

            $txn->buy;
        };
        SKIP: {
            skip 'no error', 6
                unless isa_ok $error, 'Error::Base';

            is $error->get_type, 'IntradayLimitExceeded', 'error is IntradayLimitExceeded';

            is $error->{-message_to_client}, 'You have exceeded the daily limit for contracts of this type.', 'message_to_client';
            is $error->{-mesg}, 'Exceeds intraday limit on realized_profit', 'mesg';

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

            my $class = ref BOM::Platform::Runtime->instance->app_config->quants->client_limits->intraday_forex_iv_realized_profit;
            (my $fname = $class) =~ s!::!/!g;
            $INC{$fname . '.pm'} = 1;
            my $mock_limits = Test::MockModule->new($class);
            $mock_limits->mock(
                USD => sub { note "mocked app_config->quants->client_limits->intraday_forex_iv_realized_profit->USD returning 60"; 60 });

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

# see further transaction.t:  many more tests
#             transaction2.t: special turnover limits

Test::NoWarnings::had_no_warnings;

done_testing;
