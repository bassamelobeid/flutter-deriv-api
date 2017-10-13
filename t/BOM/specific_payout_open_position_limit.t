#!/usr/bin/perl

use strict;
use warnings;

use JSON qw(to_json);
use Test::MockTime qw/:all/;
use Test::MockModule;
use Test::More;    # tests => 4;
use Test::Exception;
use Guard;
use Client::Account;
use BOM::Platform::Password;
use BOM::Platform::Client::Utility;

use BOM::Platform::Client::IDAuthentication;

use BOM::Transaction;
use BOM::Transaction::Validation;
use BOM::Product::ContractFactory qw( produce_contract make_similar_contract);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;

use Crypt::NamedKeys;
use LandingCompany::Offerings qw(reinitialise_offerings);

initialize_realtime_ticks_db();
my $mocked = Test::MockModule->new('BOM::Product::Contract');
$mocked->mock('pricing_vol', 0.1);

my $now = Date::Utility->new;
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $now
    }) for (qw(USD JPY JPY-USD));
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $now,
    });
my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch,
    underlying => 'frxUSDJPY',
});

Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';

my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');

$mock_validation->mock(validate_tnc => sub { note "mocked Transaction::Validation->validate_tnc returning nothing"; undef });

reinitialise_offerings(BOM::Platform::Runtime->instance->get_offerings_config);

subtest 'does not affect volidx' => sub {
    lives_ok {
        my $cl = create_client();
        top_up($cl, 'USD', 5000);
        isnt + (my $acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';
        my $bal;
        is + ($bal = $acc_usd->balance + 0), 5000, 'USD balance is 5000 got: ' . $bal;

        note("setting  {open_positions_payout_per_symbol_limit}{atm} to 199.99");
        BOM::Platform::Config::quants->{bet_limits}{open_positions_payout_per_symbol_limit}{atm}{USD} = 199.99;
        my $contract = produce_contract({
            underlying   => 'R_100',
            bet_type     => 'CALL',
            currency     => 'USD',
            payout       => 100,
            duration     => '5m',
            current_tick => $tick,
            barrier      => 'S10P',
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

            my $mock_transaction = Test::MockModule->new('BOM::Transaction');
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning '[]'"; [] });

            $txn->buy;
        };

        # this is to make sure non ATM contract will not affect ATM
        is $error, undef, 'bought 1st non ATM contract without error';

        # ATM contract
        $contract = produce_contract({
            underlying   => 'R_100',
            bet_type     => 'CALL',
            currency     => 'USD',
            payout       => 100,
            duration     => '5m',
            current_tick => $tick,
            barrier      => 'S0P',
        });

        $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 50.00,
            payout        => $contract->payout,
            amount_type   => 'payout',
            purchase_date => $contract->date_start,
        });

        $error = do {
            my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
            $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

            my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_validation->mock(_validate_trade_pricing_adjustment =>
                    sub { note "mocked Transaction::Validation->_validate_trade_pricing_adjustment returning nothing"; () });

            my $mock_transaction = Test::MockModule->new('BOM::Transaction');
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning '[]'"; [] });

            is $txn->buy, undef, 'bought 1st contract';

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

subtest 'atm' => sub {
    lives_ok {
        my $cl = create_client();
        top_up($cl, 'USD', 5000);
        isnt + (my $acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';
        my $bal;
        is + ($bal = $acc_usd->balance + 0), 5000, 'USD balance is 5000 got: ' . $bal;

        note("setting  {open_positions_payout_per_symbol_limit}{atm} to 199.99");
        BOM::Platform::Config::quants->{bet_limits}{open_positions_payout_per_symbol_limit}{atm}{USD} = 199.99;
        my $contract = produce_contract({
            underlying   => 'frxUSDJPY',
            bet_type     => 'CALL',
            currency     => 'USD',
            payout       => 100,
            duration     => '5m',
            current_tick => $tick,
            barrier      => 'S10P',
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

            my $mock_transaction = Test::MockModule->new('BOM::Transaction');
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning '[]'"; [] });

            $txn->buy;
        };

        # this is to make sure non ATM contract will not affect ATM
        is $error, undef, 'bought 1st non ATM contract without error';

        # ATM contract
        $contract = produce_contract({
            underlying   => 'frxUSDJPY',
            bet_type     => 'CALL',
            currency     => 'USD',
            payout       => 100,
            duration     => '5m',
            current_tick => $tick,
            barrier      => 'S0P',
        });

        $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 50.00,
            payout        => $contract->payout,
            amount_type   => 'payout',
            purchase_date => $contract->date_start,
        });

        $error = do {
            my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
            $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

            my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_validation->mock(_validate_trade_pricing_adjustment =>
                    sub { note "mocked Transaction::Validation->_validate_trade_pricing_adjustment returning nothing"; () });

            my $mock_transaction = Test::MockModule->new('BOM::Transaction');
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning '[]'"; [] });

            is $txn->buy, undef, 'bought 1st contract';

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
            is $error->get_type, 'ATM open position payout limitExceeded', 'error is ATM open position payout limitExceeded';

            is $error->{-message_to_client}, 'You have exceeded the open position limit for contracts of this type.', 'message_to_client';
            is $error->{-mesg},              'Exceeds open position limit on ATM open position payout limit',         'mesg';

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

            my $mock_transaction = Test::MockModule->new('BOM::Transaction');
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning '[]'"; [] });

            note("setting  {open_positions_payout_per_symbol_limit}{atm} to 200.00");
            BOM::Platform::Config::quants->{bet_limits}{open_positions_payout_per_symbol_limit}{atm}{USD} = 200.00;

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

            # non ATM is not affected
            $contract = produce_contract({
                underlying   => 'frxUSDJPY',
                bet_type     => 'CALL',
                currency     => 'USD',
                payout       => 100,
                duration     => '5m',
                current_tick => $tick,
                barrier      => 'S10P',
            });

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

subtest 'non ATM - > 7 days open position payout limit' => sub {
    lives_ok {
        my $cl = create_client();
        top_up($cl, 'USD', 5000);
        isnt + (my $acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';
        my $bal;
        is + ($bal = $acc_usd->balance + 0), 5000, 'USD balance is 5000 got: ' . $bal;

        note("setting {open_positions_payout_per_symbol_limit}{non_atm}{more_than_seven_days} to 199.99");
        BOM::Platform::Config::quants->{bet_limits}{open_positions_payout_per_symbol_limit}{non_atm}{more_than_seven_days}{USD} = 199.99;
        my $contract = produce_contract({
            underlying   => 'frxUSDJPY',
            bet_type     => 'CALL',
            currency     => 'USD',
            payout       => 100,
            duration     => '8d',
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

            my $mock_transaction = Test::MockModule->new('BOM::Transaction');
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning '[]'"; [] });

            $txn->buy;
        };

        # this is to make sure ATM contract will not affect non ATM
        is $error, undef, 'successful buy one ATM contract';

        # non ATM
        $contract = produce_contract({
            underlying   => 'frxUSDJPY',
            bet_type     => 'CALL',
            currency     => 'USD',
            payout       => 100,
            duration     => '8d',
            current_tick => $tick,
            barrier      => 'S10P',
        });

        $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 50.00,
            payout        => $contract->payout,
            amount_type   => 'payout',
            purchase_date => $contract->date_start,
        });

        $error = do {
            my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
            $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

            my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_validation->mock(_validate_trade_pricing_adjustment =>
                    sub { note "mocked Transaction::Validation->_validate_trade_pricing_adjustment returning nothing"; () });

            my $mock_transaction = Test::MockModule->new('BOM::Transaction');
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning '[]'"; [] });

            is $txn->buy, undef, 'bought 1st non ATM contract';

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
            is $error->get_type, 'max_more_than_7day_specific_open_position_payoutExceeded',
                'error is max_more_than_7day_specific_open_position_payoutExceeded';

            is $error->{-message_to_client}, 'You have exceeded the open position limit for contracts of this type.',           'message_to_client';
            is $error->{-mesg},              'Exceeds open position limit on max_more_than_7day_specific_open_position_payout', 'mesg';

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

            my $mock_transaction = Test::MockModule->new('BOM::Transaction');
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning '[]'"; [] });

            note("setting {open_positions_payout_per_symbol_limit}{non_atm}{more_than_seven_days} to 200.00");
            BOM::Platform::Config::quants->{bet_limits}{open_positions_payout_per_symbol_limit}{non_atm}{more_than_seven_days}{USD} = 200.00;

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

            # less than 7 days are not affected
            $contract = produce_contract({
                underlying   => 'frxUSDJPY',
                bet_type     => 'CALL',
                currency     => 'USD',
                payout       => 100,
                duration     => '5m',
                current_tick => $tick,
                barrier      => 'S10P',
            });

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

subtest 'non ATM - < 7 days open position payout limit' => sub {
    lives_ok {
        my $cl = create_client();
        top_up($cl, 'USD', 5000);
        isnt + (my $acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';
        my $bal;
        is + ($bal = $acc_usd->balance + 0), 5000, 'USD balance is 5000 got: ' . $bal;

        note("setting {open_positions_payout_per_symbol_limit}{non_atm}{less_than_seven_days} to 199.99");
        BOM::Platform::Config::quants->{bet_limits}{open_positions_payout_per_symbol_limit}{non_atm}{less_than_seven_days}{USD} = 199.99;
        my $contract = produce_contract({
            underlying   => 'frxUSDJPY',
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

            my $mock_transaction = Test::MockModule->new('BOM::Transaction');
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning '[]'"; [] });

            $txn->buy;
        };

        # this is to make sure ATM contract will not affect non ATM
        is $error, undef, 'successful buy one ATM contract';

        # non ATM
        $contract = produce_contract({
            underlying   => 'frxUSDJPY',
            bet_type     => 'CALL',
            currency     => 'USD',
            payout       => 100,
            duration     => '5m',
            current_tick => $tick,
            barrier      => 'S10P',
        });

        $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 50.00,
            payout        => $contract->payout,
            amount_type   => 'payout',
            purchase_date => $contract->date_start,
        });

        $error = do {
            my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
            $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

            my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_validation->mock(_validate_trade_pricing_adjustment =>
                    sub { note "mocked Transaction::Validation->_validate_trade_pricing_adjustment returning nothing"; () });

            my $mock_transaction = Test::MockModule->new('BOM::Transaction');
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning '[]'"; [] });

            is $txn->buy, undef, 'bought 1st non ATM contract';

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
            is $error->get_type, 'max_7day_specific_open_position_payoutExceeded', 'error is max_7day_specific_open_position_payoutExceeded';

            is $error->{-message_to_client}, 'You have exceeded the open position limit for contracts of this type.', 'message_to_client';
            is $error->{-mesg},              'Exceeds open position limit on max_7day_specific_open_position_payout', 'mesg';

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

            my $mock_transaction = Test::MockModule->new('BOM::Transaction');
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning '[]'"; [] });

            note("setting {open_positions_payout_per_symbol_limit}{non_atm}{less_than_seven_days} to 200.00");
            BOM::Platform::Config::quants->{bet_limits}{open_positions_payout_per_symbol_limit}{non_atm}{less_than_seven_days}{USD} = 200.00;

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

            # more than 7 days are not affected
            $contract = produce_contract({
                underlying   => 'frxUSDJPY',
                bet_type     => 'CALL',
                currency     => 'USD',
                payout       => 100,
                duration     => '8d',
                current_tick => $tick,
                barrier      => 'S10P',
            });

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

sub db {
    return BOM::Database::ClientDB->new({
            broker_code => 'CR',
        })->db;
}

sub create_client {
    return Client::Account->register_and_return_new_client({
        broker_code      => 'CR',
        client_password  => BOM::Platform::Password::hashpw('12345678'),
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

done_testing();
