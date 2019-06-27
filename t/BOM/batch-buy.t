#!/usr/bin/perl

use strict;
use warnings;
use utf8;
use open ':std', ':encoding(utf8)';
use Test::Deep;
use Test::MockTime qw/:all/;
use Test::MockModule;
use Test::More;
use Test::Exception;

use BOM::User::Client;
use Date::Utility;
use ExpiryQueue ();
use Guard;

use BOM::MarketData qw(create_underlying);
use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData::Types;
use BOM::User::Password;
use BOM::Product::ContractFactory qw( produce_contract );
use Finance::Contract::Longcode qw( shortcode_to_parameters );
use BOM::Transaction::Validation;
use BOM::Transaction;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Helper::Client qw( create_client top_up );

my $requestmod = Test::MockModule->new('BOM::Platform::Context::Request');
$requestmod->mock('session_cookie', sub { return bless({token => 1}, 'BOM::Platform::SessionCookie'); });

use Crypt::NamedKeys;
Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';

my $datadog_mock = Test::MockModule->new('DataDog::DogStatsd');
my @datadog_actions;
for my $mock (qw(increment decrement timing gauge count)) {
    $datadog_mock->mock($mock => sub { shift; push @datadog_actions => {action_name => $mock, data => \@_} });
}

{
    no warnings 'redefine';
    *BOM::Config::env = sub { return 'production' };    # for testing datadog
}

sub reset_datadog {
    @datadog_actions = ();
}

sub check_datadog {
    my $item = +{@_};
    if ($item->{action_name} eq "timing") {
        for my $action (grep { $_->{action_name} eq "timing" } @datadog_actions) {
            # skip exact timing, compare only event name and tags
            next if $action->{data}[0] ne $item->{data}[0];
            cmp_deeply($item->{data}[1], $action->{data}[2], "found datadog action: timing");
        }
        return;
    }
    cmp_deeply($item, any(@datadog_actions), "found datadog action: @{[$item->{action_name}]}");
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

my $underlying        = create_underlying('frxUSDJPY');
my $market = $underlying->market->name;
my $underlying_GDAXI  = create_underlying('GDAXI');
my $underlying_WLDUSD = create_underlying('WLDUSD');
my $underlying_R50    = create_underlying('R_50');

sub db {
    return BOM::Database::ClientDB->new({
            broker_code => 'CR',
        })->db;
}

sub check_one_result {
    my ($title, $cl, $acc, $m, $balance_after) = @_;

    subtest $title, sub {
        my $err = 0;
        if (not $cl->status->professional and $cl->landing_company->short eq 'maltainvest') {
            $err++
                unless is $m->{error}, "Sorry, your account is not authorised for any further contract purchases.",
                "correct error for non professional MF client";
            return $err;
        }
        $err++ unless is $m->{error}, undef, "no error should be provided";
        $err++ unless is $m->{txn}->{account_id}, $acc->id, 'txn account_id';
        $err++ unless is $m->{fmb}->{account_id}, $acc->id, 'fmb account_id';
        $err++ unless is $m->{txn}->{financial_market_bet_id}, $m->{fmb}->{id}, 'txn financial_market_bet_id';
        $err++ unless is $m->{txn}->{balance_after}, sprintf('%.2f', $balance_after), 'balance_after';
        $err++ unless is $m->{loginid}, $cl->loginid, 'loginid';
    };
}

####################################################################
# real tests begin here
####################################################################

subtest 'batch-buy success + multisell', sub {
    plan tests => 12;
    lives_ok {
        my $clm = create_client;    # manager
        my $cl1 = create_client;
        my $cl2 = create_client;
        my $cl3 = create_client;

        $clm->account('USD');
        $cl1->account('USD');
        $cl2->account('USD');
        $cl3->account('USD');
        $clm->save;
        top_up $cl1, 'USD', 5000;
        top_up $cl2, 'USD', 5000;

        isnt + (my $acc1 = $cl1->account), 'USD', 'got USD account #1';
        isnt + (my $acc2 = $cl2->account), 'USD', 'got USD account #2';

        my $bal;
        is + ($bal = $acc1->balance + 0), 5000, 'USD balance #1 is 5000 got: ' . $bal;
        is + ($bal = $acc2->balance + 0), 5000, 'USD balance #2 is 5000 got: ' . $bal;

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
            client        => $clm,
            contract      => $contract,
            price         => 50.00,
            payout        => $contract->payout,
            amount_type   => 'payout',
            multiple      => [{loginid => $cl2->loginid}, {code => 'ignore'}, {loginid => $cl1->loginid}, {loginid => $cl2->loginid},],
            purchase_date => $contract->date_start,
        });

        subtest 'check limits' => sub {
            my $mock_client  = Test::MockModule->new('BOM::User::Client');
            my $mocked_limit = 100;
            $mock_client->mock(
                get_limit_for_account_balance => sub {
                    my $c = shift;
                    return ($c->loginid);
                });

            $txn->prepare_buy(1);
            foreach my $m (@{$txn->multiple}) {
                next if $m->{code} && $m->{code} eq 'ignore';
                ok(!$m->{code}, 'no error');
                ok($m->{client} && ref $m->{client} eq 'BOM::User::Client', 'check client');
                is($m->{limits}{max_balance}, $m->{client}->loginid, 'check_limit');
            }
        };

        my $error = do {
            my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
            $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

            my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_validation->mock(_validate_trade_pricing_adjustment =>
                    sub { note "mocked Transaction::Validation->_validate_trade_pricing_adjustment returning nothing"; undef });
            $mock_validation->mock(validate_tnc => sub { note "mocked Transaction::Validation->validate_tnc returning nothing"; undef });

            my $mock_transaction = Test::MockModule->new('BOM::Transaction');
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning '[]'"; [] });

            ExpiryQueue::queue_flush;
            note explain +ExpiryQueue::queue_status;
            $txn->batch_buy;
        };

        is $error, undef, 'successful batch_buy';
        my $m = $txn->multiple;
        check_one_result 'result for client #1', $cl1, $acc1, $m->[2], 4950;
        check_one_result 'result for client #2', $cl2, $acc2, $m->[0], 4950;
        check_one_result 'result for client #3', $cl2, $acc2, $m->[3], 4900;

        my $expected_status = {
            active_queues  => 2,    # TICK_COUNT and SETTLEMENT_EPOCH
            open_contracts => 3,    # the ones just bought
            ready_to_sell  => 0,    # obviously
        };
        is_deeply ExpiryQueue::queue_status, $expected_status, 'ExpiryQueue';
        sleep 1;
        subtest "sell_by_shortcode", sub {
            plan tests => 8;
            my $contract_parameters = shortcode_to_parameters($contract->shortcode, $clm->currency);
            $contract_parameters->{landing_company} = $clm->landing_company->short;
            $contract = produce_contract($contract_parameters);
            ok($contract, 'contract have produced');
            my $trx = BOM::Transaction->new({
                    purchase_date => $contract->date_start,
                    client        => $clm,
                    multiple      => [{
                            loginid  => $cl2->loginid,
                            currency => $clm->currency
                        },
                        {loginid => $cl3->loginid},
                        {loginid => $cl1->loginid},
                        {loginid => $cl2->loginid},
                    ],
                    contract => $contract,
                    price    => 10,
                    source   => 1,
                });
            my $err = do {
                my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
                $mock_contract->mock(is_valid_to_sell => sub { note "mocked Contract->is_valid_to_sell returning true"; 1 });
                my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');
                $mock_validation->mock(_validate_sell_pricing_adjustment =>
                        sub { note "mocked Transaction::Validation->_validate_sell_pricing_adjustment returning nothing"; () });
                $mock_validation->mock(_validate_offerings => sub { note "mocked Transaction::Validation->_validate_offerings returning nothing"; () }
                );
                $trx->sell_by_shortcode;
            };

            is $err, undef, 'successful multisell';
            $m = $trx->multiple;

            $_->{txn} = $_->{tnx} for @$m;

            ok(!$m->[1]->{fmb} && !$m->[1]->{tnx} && !$m->[1]->{buy_tr_id}, 'check undef fields for invalid sell');
            is($m->[1]->{code}, 'NoOpenPosition', 'check error code');
            is($m->[1]->{error}, 'This contract was not found among your open positions.', 'check error message');
            check_one_result 'result for client #1', $cl1, $acc1, $m->[2], 4960;
            check_one_result 'result for client #2', $cl2, $acc2, $m->[0], 4910;
            check_one_result 'result for client #3', $cl2, $acc2, $m->[3], 4920;
        };
    }
    'survived';
};

subtest 'batch-buy success 2', sub {
    plan tests => 3;
    lives_ok {
        my $clm = create_client;    # manager

        $clm->set_default_account('USD');
        $clm->save;

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
            client        => $clm,
            contract      => $contract,
            price         => 50.00,
            payout        => $contract->payout,
            amount_type   => 'payout',
            multiple      => [{code => 'ignore'}, {}, {code => 'ignore'},],
            purchase_date => $contract->date_start,
        });

        my $error = do {
            my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
            $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

            my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_validation->mock(_validate_trade_pricing_adjustment =>
                    sub { note "mocked Transaction::Validation->_validate_trade_pricing_adjustment returning nothing"; undef });
            $mock_validation->mock(validate_tnc => sub { note "mocked Transaction::Validation->validate_tnc returning nothing"; undef });
            my $mock_transaction = Test::MockModule->new('BOM::Transaction');
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning '[]'"; [] });

            $txn->batch_buy;
        };

        is $error, undef, 'successful batch_buy';
        my $expected = [
            {code => 'ignore'},
            {
                code              => 'InvalidLoginid',
                error             => 'Invalid loginid',
                message_to_client => 'Invalid loginid',
            },
            {code => 'ignore'},
        ];

        delete $txn->multiple->[0]->{limits};
        delete $txn->multiple->[1]->{limits};
        is_deeply $txn->multiple, $expected, 'nothing bought';
    }
    'survived';
};

subtest 'contract already started', sub {
    plan tests => 3;
    lives_ok {
        my $clm = create_client;    # manager

        $clm->set_default_account('USD');
        $clm->save;

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
            client        => $clm,
            purchase_date => Date::Utility::today()->plus_time_interval('3d'),
            contract      => $contract,
            price         => 50.00,
            payout        => $contract->payout,
            amount_type   => 'payout',
            multiple      => [{code => 'ignore'}],
        });

        my $error = do {
            my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
            $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

            my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_validation->mock(_validate_trade_pricing_adjustment =>
                    sub { note "mocked Transaction::Validation->_validate_trade_pricing_adjustment returning nothing"; undef });
            $mock_validation->mock(validate_tnc => sub { note "mocked Transaction::Validation->validate_tnc returning nothing"; undef });

            my $mock_transaction = Test::MockModule->new('BOM::Transaction');
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

        $clm->set_default_account('USD');
        $clm->save;

        top_up $cl1, 'USD', 5000;
        top_up $cl2, 'USD', 90;

        isnt + (my $acc1 = $cl1->account), 'USD', 'got USD account #1';
        isnt + (my $acc2 = $cl2->account), 'USD', 'got USD account #2';

        my $bal;
        is + ($bal = $acc1->balance + 0), 5000, 'USD balance #1 is 5000 got: ' . $bal;
        is + ($bal = $acc2->balance + 0), 90,   'USD balance #2 is 90 got: ' . $bal;

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
            client        => $clm,
            contract      => $contract,
            price         => 50.00,
            payout        => $contract->payout,
            amount_type   => 'payout',
            multiple      => [{loginid => $cl2->loginid}, {code => 'ignore'}, {loginid => $cl1->loginid}, {loginid => $cl2->loginid},],
            purchase_date => $contract->date_start,
        });

        my $error = do {
            my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
            $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

            my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_validation->mock(_validate_trade_pricing_adjustment =>
                    sub { note "mocked Transaction::Validation->_validate_trade_pricing_adjustment returning nothing"; undef });
            $mock_validation->mock(validate_tnc => sub { note "mocked Transaction::Validation->validate_tnc returning nothing"; undef });

            my $mock_transaction = Test::MockModule->new('BOM::Transaction');
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning '[]'"; [] });

            ExpiryQueue::queue_flush;
            note explain +ExpiryQueue::queue_status;
            $txn->batch_buy;
        };

        is $error, undef, 'successful batch_buy';
        my $m = $txn->multiple;
        check_one_result 'result for client #1', $cl1, $acc1, $m->[2], 4950;
        check_one_result 'result for client #2', $cl2, $acc2, $m->[0], 40;
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
        my $clm              = create_client 'VRTC';    # manager
        my $mf_professional1 = create_client 'MF';
        my $mf_professional2 = create_client 'MF';
        my @cl;
        push @cl, create_client;
        push @cl, create_client;
        push @cl, create_client 'MF';
        push @cl, create_client 'MF';
        push @cl, create_client 'VRTC';

        $clm->set_default_account('USD');
        $clm->save;

        $mf_professional1->status->set("professional");
        $mf_professional2->status->set("professional");

        $mf_professional1->save();
        $mf_professional2->save();

        push @cl, $mf_professional1;
        push @cl, $mf_professional2;

        top_up $_, 'USD', 5000 for (@cl);

        my @acc;
        isnt + (push @acc, $_->account), 'USD', 'got USD account #' . @acc for (@cl);

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
            client        => $clm,
            contract      => $contract,
            price         => 50.00,
            payout        => $contract->payout,
            amount_type   => 'payout',
            multiple      => [(map { +{loginid => $_->loginid} } @cl), {code => 'ignore'}, {loginid => 'NONE000'},],
            purchase_date => $contract->date_start,
        });

        my $error = do {
            my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
            $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

            my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_validation->mock(_validate_trade_pricing_adjustment =>
                    sub { note "mocked Transaction::Validation->_validate_trade_pricing_adjustment returning nothing"; undef });
            $mock_validation->mock(validate_tnc => sub { note "mocked Transaction::Validation->validate_tnc returning nothing"; undef });

            my $mock_transaction = Test::MockModule->new('BOM::Transaction');
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning '[]'"; [] });

            ExpiryQueue::queue_flush;
            # note explain +ExpiryQueue::queue_status;
            reset_datadog;

            $txn->batch_buy;
        };

        is $error, undef, 'successful batch_buy';
        my $m = $txn->multiple;
        for (my $i = 0; $i < @cl; $i++) {
            check_one_result 'result for client ' . $m->[$i]->{loginid}, $cl[$i], $acc[$i], $m->[$i], 4950;
        }

        my $expected_status = {
            active_queues  => 2,    # TICK_COUNT and SETTLEMENT_EPOCH
            open_contracts => 5,    # the ones just bought
            ready_to_sell  => 0,    # obviously
        };
        is_deeply ExpiryQueue::queue_status, $expected_status, 'ExpiryQueue';
        check_datadog
            action_name => 'increment',
            data        => [
            "transaction.batch_buy.attempt" => {
                tags => [
                    qw/ broker:vrtc
                        virtual:yes
                        rmgenv:production
                        contract_class:higher_lower_bet
                        landing_company:virtual
                        market:forex
                        amount_type:payout
                        expiry_type:duration
                        /
                ]}];
        check_datadog
            action_name => 'increment',
            data        => [
            "transaction.batch_buy.success" => {
                tags => [
                    qw/ broker:vrtc
                        virtual:yes
                        rmgenv:production
                        contract_class:higher_lower_bet
                        landing_company:virtual
                        market:forex
                        amount_type:payout
                        expiry_type:duration
                        /
                ]}];
        check_datadog
            action_name => 'count',
            data        => [
            "transaction.buy.attempt" => 1,
            {
                tags => [
                    qw/ broker:vrtc
                        virtual:yes
                        rmgenv:production
                        contract_class:higher_lower_bet
                        landing_company:virtual
                        market:forex
                        amount_type:payout
                        expiry_type:duration
                        /
                ]}];
        check_datadog
            action_name => 'count',
            data        => [
            "transaction.buy.success" => 1,
            {
                tags => [
                    qw/ broker:vrtc
                        virtual:yes
                        rmgenv:production
                        contract_class:higher_lower_bet
                        landing_company:virtual
                        market:forex
                        amount_type:payout
                        expiry_type:duration
                        /
                ]}];
        check_datadog
            action_name => 'count',
            data        => [
            "transaction.buy.attempt" => 2,
            {
                tags => [
                    qw/ broker:cr
                        virtual:no
                        rmgenv:production
                        contract_class:higher_lower_bet
                        landing_company:virtual
                        market:forex
                        amount_type:payout
                        expiry_type:duration
                        /
                ]}];
        check_datadog
            action_name => 'count',
            data        => [
            "transaction.buy.success" => 2,
            {
                tags => [
                    qw/ broker:cr
                        virtual:no
                        rmgenv:production
                        contract_class:higher_lower_bet
                        landing_company:virtual
                        market:forex
                        amount_type:payout
                        expiry_type:duration
                        /
                ]}];
        check_datadog
            action_name => 'count',
            data        => [
            "transaction.buy.attempt" => 2,
            {
                tags => [
                    qw/ broker:mf
                        virtual:no
                        rmgenv:production
                        contract_class:higher_lower_bet
                        landing_company:virtual
                        market:forex
                        amount_type:payout
                        expiry_type:duration
                        /
                ]}];
        check_datadog
            action_name => 'count',
            data        => [
            "transaction.buy.success" => 2,
            {
                tags => [
                    qw/ broker:mf
                        virtual:no
                        rmgenv:production
                        contract_class:higher_lower_bet
                        landing_company:virtual
                        market:forex
                        amount_type:payout
                        expiry_type:duration
                        /
                ]}];
        check_datadog
            action_name => 'timing',
            data        => [
            "transaction.batch_buy.elapsed_time" => {
                tags => [
                    qw/ broker:vrtc
                        virtual:yes
                        rmgenv:production
                        contract_class:higher_lower_bet
                        landing_company:virtual
                        market:forex
                        amount_type:payout
                        expiry_type:duration
                        /
                ]}];
        check_datadog
            action_name => 'timing',
            data        => [
            "transaction.batch_buy.db_time" => {
                tags => [
                    qw/ broker:vrtc
                        virtual:yes
                        rmgenv:production
                        contract_class:higher_lower_bet
                        landing_company:virtual
                        market:forex
                        amount_type:payout
                        expiry_type:duration
                        /
                ]}];
    }
    'survived';
};

done_testing;
