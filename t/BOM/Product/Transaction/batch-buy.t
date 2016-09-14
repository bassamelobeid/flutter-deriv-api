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

use ExpiryQueue ();

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

use JSON qw/to_json/;
my $datadog_mock = Test::MockModule->new('DataDog::DogStatsd');
my @datadog_actions;
$datadog_mock->mock(increment => sub { shift; push @datadog_actions, to_json + {increment => [@_]}; return; });
$datadog_mock->mock(decrement => sub { shift; push @datadog_actions, to_json + {decrement => [@_]}; return; });
$datadog_mock->mock(timing    => sub { shift; push @datadog_actions, to_json + {timing    => [@_]}; return; });
$datadog_mock->mock(gauge     => sub { shift; push @datadog_actions, to_json + {gauge     => [@_]}; return; });
$datadog_mock->mock(count     => sub { shift; push @datadog_actions, to_json + {count     => [@_]}; return; });

{
    no warnings 'redefine';
    *BOM::System::Config::env = sub { return 'production' };    # for testing datadog
}

sub reset_datadog {
    @datadog_actions = ();
}

sub check_datadog {
    my $item = to_json + {@_};
    if ($_[0] eq 'timing') {
        my ($p1, $p2) = split /,/, $item, 2;
        my $re = qr/\Q$p1\E,[\d.]+,\Q$p2\E/;
        ok + (!!grep { /$re/ } @datadog_actions), "found datadog action: $item";
    } else {
        ok + (!!grep { $_ eq $item } @datadog_actions), "found datadog action: $item";
    }
}

{
    my %exch = (
        USD => 2,
        EUR => 3,
    );
    no warnings 'redefine';
    *BOM::Product::Transaction::in_USD = sub {    # for testing datadog
        my ($amount, $currency) = @_;
        return $amount * $exch{$currency};
    };
}

my $now = Date::Utility->new;
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
    my $broker = shift || 'CR';
    return BOM::Platform::Client->register_and_return_new_client({
        broker_code      => $broker,
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

    note $c->loginid . "'s balance is now $cur " . $trx->balance_after . "\n";
}

sub check_one_result {
    my ($title, $cl, $acc, $m, $balance_after) = @_;

    subtest $title, sub {
        my $err = 0;
        $err++ unless is $m->{loginid}, $cl->loginid, 'loginid';
        $err++ unless is $m->{txn}->{account_id}, $acc->id, 'txn account_id';
        $err++ unless is $m->{fmb}->{account_id}, $acc->id, 'fmb account_id';
        $err++ unless is $m->{txn}->{financial_market_bet_id}, $m->{fmb}->{id}, 'txn financial_market_bet_id';
        $err++ unless is $m->{txn}->{balance_after}, $balance_after, 'balance_after';
        note explain $m if $err;
    };
}

####################################################################
# real tests begin here
####################################################################

subtest 'batch-buy success', sub {
    plan tests => 10;
    lives_ok {
        my $clm = create_client;    # manager
        my $cl1 = create_client;
        my $cl2 = create_client;

        top_up $clm, 'USD', 0;      # the manager has no money
        top_up $cl1, 'USD', 5000;
        top_up $cl2, 'USD', 5000;

        isnt + (my $acc1 = $cl1->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account #1';
        isnt + (my $acc2 = $cl2->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account #2';

        my $bal;
        is + ($bal = $acc1->balance + 0), 5000, 'USD balance #1 is 5000 got: ' . $bal;
        is + ($bal = $acc2->balance + 0), 5000, 'USD balance #2 is 5000 got: ' . $bal;

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
            client      => $clm,
            contract    => $contract,
            price       => 50.00,
            payout      => $contract->payout,
            amount_type => 'payout',
            multiple    => [{loginid => $cl2->loginid}, {code => 'ignore'}, {loginid => $cl1->loginid}, {loginid => $cl2->loginid},],
        });

        my $error = do {
            my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
            $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

            my $mock_transaction = Test::MockModule->new('BOM::Product::Transaction');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_transaction->mock(
                _validate_trade_pricing_adjustment => sub { note "mocked Transaction->_validate_trade_pricing_adjustment returning nothing"; () });
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning '[]'"; [] });

            ExpiryQueue::queue_flush;
            note explain +ExpiryQueue::queue_status;
            $txn->batch_buy;
        };

        is $error, undef, 'successful batch_buy';
        my $m = $txn->multiple;
        check_one_result 'result for client #1', $cl1, $acc1, $m->[2], '4950.0000';
        check_one_result 'result for client #2', $cl2, $acc2, $m->[0], '4950.0000';
        check_one_result 'result for client #3', $cl2, $acc2, $m->[3], '4900.0000';

        my $expected_status = {
            active_queues  => 2,    # TICK_COUNT and SETTLEMENT_EPOCH
            open_contracts => 3,    # the ones just bought
            ready_to_sell  => 0,    # obviously
        };
        is_deeply ExpiryQueue::queue_status, $expected_status, 'ExpiryQueue';
    }
    'survived';
};

subtest 'batch-buy success 2', sub {
    plan tests => 3;
    lives_ok {
        my $clm = create_client;    # manager

        top_up $clm, 'USD', 0;      # the manager has no money

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
            client      => $clm,
            contract    => $contract,
            price       => 50.00,
            payout      => $contract->payout,
            amount_type => 'payout',
            multiple    => [{code => 'ignore'}, {}, {code => 'ignore'},],
        });

        my $error = do {
            my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
            $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

            my $mock_transaction = Test::MockModule->new('BOM::Product::Transaction');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_transaction->mock(
                _validate_trade_pricing_adjustment => sub { note "mocked Transaction->_validate_trade_pricing_adjustment returning nothing"; () });
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning '[]'"; [] });

            $txn->batch_buy;
        };

        is $error, undef, 'successful batch_buy';
        my $expected = [
            {code => 'ignore'},
            {
                code  => 'InvalidLoginid',
                error => 'Invalid loginid',
            },
            {code => 'ignore'},
        ];
        is_deeply $txn->multiple, $expected, 'nothing bought';
    }
    'survived';
};

subtest 'contract already started', sub {
    plan tests => 3;
    lives_ok {
        my $clm = create_client;    # manager

        top_up $clm, 'USD', 0;      # the manager has no money

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
            client        => $clm,
            purchase_date => Date::Utility::today->plus_time_interval('3d'),
            contract      => $contract,
            price         => 50.00,
            payout        => $contract->payout,
            amount_type   => 'payout',
            multiple      => [{code => 'ignore'}],
        });

        my $error = do {
            my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
            $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

            my $mock_transaction = Test::MockModule->new('BOM::Product::Transaction');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_transaction->mock(
                _validate_trade_pricing_adjustment => sub { note "mocked Transaction->_validate_trade_pricing_adjustment returning nothing"; () });
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning '[]'"; [] });

            $txn->batch_buy;
        };

        isa_ok $error, 'Error::Base';
        is $error->{-type}, 'ContractAlreadyStarted', 'ContractAlreadyStarted';
    }
    'survived';
};

subtest 'single contract fails in database', sub {
    plan tests => 10;
    lives_ok {
        my $clm = create_client;    # manager
        my $cl1 = create_client;
        my $cl2 = create_client;

        top_up $clm, 'USD', 0;      # the manager has no money
        top_up $cl1, 'USD', 5000;
        top_up $cl2, 'USD', 90;

        isnt + (my $acc1 = $cl1->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account #1';
        isnt + (my $acc2 = $cl2->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account #2';

        my $bal;
        is + ($bal = $acc1->balance + 0), 5000, 'USD balance #1 is 5000 got: ' . $bal;
        is + ($bal = $acc2->balance + 0), 90,   'USD balance #2 is 90 got: ' . $bal;

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
            client      => $clm,
            contract    => $contract,
            price       => 50.00,
            payout      => $contract->payout,
            amount_type => 'payout',
            multiple    => [{loginid => $cl2->loginid}, {code => 'ignore'}, {loginid => $cl1->loginid}, {loginid => $cl2->loginid},],
        });

        my $error = do {
            my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
            $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

            my $mock_transaction = Test::MockModule->new('BOM::Product::Transaction');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_transaction->mock(
                _validate_trade_pricing_adjustment => sub { note "mocked Transaction->_validate_trade_pricing_adjustment returning nothing"; () });
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning '[]'"; [] });

            ExpiryQueue::queue_flush;
            note explain +ExpiryQueue::queue_status;
            $txn->batch_buy;
        };

        is $error, undef, 'successful batch_buy';
        my $m = $txn->multiple;
        check_one_result 'result for client #1', $cl1, $acc1, $m->[2], '4950.0000';
        check_one_result 'result for client #2', $cl2, $acc2, $m->[0], '40.0000';
        subtest 'result for client #3', sub {
            ok !exists($m->[3]->{fmb}), 'fmb does not exist';
            ok !exists($m->[3]->{txn}), 'txn does not exist';
            is $m->[3]->{code}, 'InsufficientBalance', 'code = InsufficientBalance';
            is $m->[3]->{error}, 'Your account balance (USD40.00) is insufficient to buy this contract (USD50.00).', 'correct description';
        };

        my $expected_status = {
            active_queues  => 2,    # TICK_COUNT and SETTLEMENT_EPOCH
            open_contracts => 2,    # the ones just bought
            ready_to_sell  => 0,    # obviously
        };
        is_deeply ExpiryQueue::queue_status, $expected_status, 'ExpiryQueue';
    }
    'survived';
};

subtest 'batch-buy multiple databases and datadog', sub {
    plan tests => 27;
    lives_ok {
        my $clm = create_client 'VRTC';    # manager
        my @cl;
        push @cl, create_client;
        push @cl, create_client;
        push @cl, create_client 'MF';
        push @cl, create_client 'MF';
        push @cl, create_client 'VRTC';

        top_up $clm, 'USD', 0;              # the manager has no money
        top_up $_, 'USD', 5000 for (@cl);

        my @acc;
        isnt + (push @acc, $_->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account #' . @acc for (@cl);

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
            client      => $clm,
            contract    => $contract,
            price       => 50.00,
            payout      => $contract->payout,
            amount_type => 'payout',
            multiple    => [(map { +{loginid => $_->loginid} } @cl), {code => 'ignore'}, {loginid => 'NONE000'},],
        });

        my $error = do {
            my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
            $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

            my $mock_transaction = Test::MockModule->new('BOM::Product::Transaction');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_transaction->mock(
                _validate_trade_pricing_adjustment => sub { note "mocked Transaction->_validate_trade_pricing_adjustment returning nothing"; () });
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning '[]'"; [] });

            ExpiryQueue::queue_flush;
            # note explain +ExpiryQueue::queue_status;
            reset_datadog;
            $txn->batch_buy;
        };

        is $error, undef, 'successful batch_buy';
        my $m = $txn->multiple;
        for (my $i = 0; $i < @cl; $i++) {
            check_one_result 'result for client ' . $m->[$i]->{loginid}, $cl[$i], $acc[$i], $m->[$i], '4950.0000';
        }

        my $expected_status = {
            active_queues  => 2,    # TICK_COUNT and SETTLEMENT_EPOCH
            open_contracts => 5,    # the ones just bought
            ready_to_sell  => 0,    # obviously
        };
        is_deeply ExpiryQueue::queue_status, $expected_status, 'ExpiryQueue';

        check_datadog increment => [
            "transaction.batch_buy.attempt" => {
                tags => [
                    qw/ broker:vrtc
                        virtual:yes
                        rmgenv:production
                        contract_class:higher_lower_bet
                        amount_type:payout
                        expiry_type:duration /
                ]}];
        check_datadog increment => [
            "transaction.batch_buy.success" => {
                tags => [
                    qw/ broker:vrtc
                        virtual:yes
                        rmgenv:production
                        contract_class:higher_lower_bet
                        amount_type:payout
                        expiry_type:duration /
                ]}];
        check_datadog count => [
            "transaction.buy.attempt" => 1,
            {
                tags => [
                    qw/ broker:vrtc
                        virtual:yes
                        rmgenv:production
                        contract_class:higher_lower_bet
                        amount_type:payout
                        expiry_type:duration /
                ]}];
        check_datadog count => [
            "transaction.buy.success" => 1,
            {
                tags => [
                    qw/ broker:vrtc
                        virtual:yes
                        rmgenv:production
                        contract_class:higher_lower_bet
                        amount_type:payout
                        expiry_type:duration /
                ]}];
        check_datadog count => [
            "transaction.buy.attempt" => 2,
            {
                tags => [
                    qw/ broker:cr
                        virtual:no
                        rmgenv:production
                        contract_class:higher_lower_bet
                        amount_type:payout
                        expiry_type:duration /
                ]}];
        check_datadog count => [
            "transaction.buy.success" => 2,
            {
                tags => [
                    qw/ broker:cr
                        virtual:no
                        rmgenv:production
                        contract_class:higher_lower_bet
                        amount_type:payout
                        expiry_type:duration /
                ]}];
        check_datadog count => [
            "transaction.buy.attempt" => 2,
            {
                tags => [
                    qw/ broker:mf
                        virtual:no
                        rmgenv:production
                        contract_class:higher_lower_bet
                        amount_type:payout
                        expiry_type:duration /
                ]}];
        check_datadog count => [
            "transaction.buy.success" => 2,
            {
                tags => [
                    qw/ broker:mf
                        virtual:no
                        rmgenv:production
                        contract_class:higher_lower_bet
                        amount_type:payout
                        expiry_type:duration /
                ]}];
        check_datadog count => [
            "business.turnover_usd" => 100 * BOM::Product::Transaction::in_USD(100, 'USD'),
            {
                tags => [
                    qw/ broker:cr
                        virtual:no
                        rmgenv:production
                        contract_class:higher_lower_bet
                        amount_type:payout
                        expiry_type:duration /
                ]}];
        check_datadog count => [
            "business.turnover_usd" => 100 * BOM::Product::Transaction::in_USD(100, 'USD'),
            {
                tags => [
                    qw/ broker:mf
                        virtual:no
                        rmgenv:production
                        contract_class:higher_lower_bet
                        amount_type:payout
                        expiry_type:duration /
                ]}];
        check_datadog count => [
            "business.buy_minus_sell_usd" => 100 * BOM::Product::Transaction::in_USD(100, 'USD'),
            {
                tags => [
                    qw/ broker:cr
                        virtual:no
                        rmgenv:production
                        contract_class:higher_lower_bet
                        amount_type:payout
                        expiry_type:duration /
                ]}];
        check_datadog count => [
            "business.buy_minus_sell_usd" => 100 * BOM::Product::Transaction::in_USD(100, 'USD'),
            {
                tags => [
                    qw/ broker:mf
                        virtual:no
                        rmgenv:production
                        contract_class:higher_lower_bet
                        amount_type:payout
                        expiry_type:duration /
                ]}];
        check_datadog timing => [
            "transaction.batch_buy.elapsed_time" => {
                tags => [
                    qw/ broker:vrtc
                        virtual:yes
                        rmgenv:production
                        contract_class:higher_lower_bet
                        amount_type:payout
                        expiry_type:duration /
                ]}];
        check_datadog timing => [
            "transaction.batch_buy.db_time" => {
                tags => [
                    qw/ broker:vrtc
                        virtual:yes
                        rmgenv:production
                        contract_class:higher_lower_bet
                        amount_type:payout
                        expiry_type:duration /
                ]}];
    }
    'survived';
};

Test::NoWarnings::had_no_warnings;

done_testing;
