#!/etc/rmg/bin/perl

use strict;
use warnings;
use BOM::Test;

use Test::MockTime qw/:all/;
use Test::Warnings;
use Test::More;
use Test::MockModule;
use Test::Exception;
use Guard;
use Crypt::NamedKeys;
use BOM::User::Client;
use BOM::User::Password;
use BOM::User::Utility;
use BOM::User;

use Date::Utility;
use BOM::Transaction;
use BOM::Transaction::Validation;
use Math::Util::CalculatedValue::Validatable;
use BOM::Product::ContractFactory                qw( produce_contract );
use BOM::Test::Data::Utility::UnitTestDatabase   qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase   qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis      qw(initialize_realtime_ticks_db);
use BOM::Test::Helper::Client                    qw(top_up);
use Format::Util::Numbers                        qw/formatnumber financialrounding/;

use BOM::MarketData qw(create_underlying);

my $password = 'jskjd8292922';
my $email    = 'test' . rand(999) . '@binary.com';
my $hash_pwd = BOM::User::Password::hashpw($password);

my $user = BOM::User->create(
    email    => $email,
    password => $hash_pwd
);

Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';

my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');

$mock_validation->mock(validate_tnc => sub { note "mocked Transaction::Validation->validate_tnc returning nothing"; undef });

my $now = Date::Utility->new;
BOM::Test::Data::Utility::UnitTestMarketData::create_doc('currency', {symbol => 'USD'});
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'index',
    {
        symbol => 'R_100',
        date   => Date::Utility->new,
    });

initialize_realtime_ticks_db();

my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch,
    underlying => 'R_100',
    quote      => 100,
});

BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch + 2,
    underlying => 'R_100',
    quote      => 100,
});

my $underlying = create_underlying('R_100');

sub db {
    return BOM::Database::ClientDB->new({
            broker_code => 'VRTC',
        })->db;
}

sub create_client {
    return $user->create_client(
        broker_code      => 'VRTC',
        client_password  => BOM::User::Password::hashpw('12345678'),
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
        secret_question  => 'What the',
        secret_answer    => BOM::User::Utility::encrypt_secret_answer('is that'),
        date_of_birth    => '1945-08-06',
    );
}

sub get_transaction_from_db {
    my $bet_class = shift;
    my $txnid     = shift;

    my $stmt = <<"SQL";
SELECT t.*, b.*, c.*, v1.*, v2.*, t2.*
  FROM transaction.transaction t
  LEFT JOIN bet.financial_market_bet b ON t.financial_market_bet_id=b.id
  LEFT JOIN bet.${bet_class} c ON b.id=c.financial_market_bet_id
  LEFT JOIN data_collection.quants_bet_variables v1 ON t.id=v1.transaction_id
  LEFT JOIN data_collection.quants_bet_variables v2 ON b.id=v2.financial_market_bet_id AND v2.transaction_id<>t.id
  LEFT JOIN transaction.transaction t2 ON t2.financial_market_bet_id=t.financial_market_bet_id AND t2.id<>t.id
 WHERE t.id=\$1
SQL

    my $db = db;
    $stmt = $db->dbh->prepare($stmt);
    $stmt->execute($txnid);

    my $res = $stmt->fetchrow_arrayref;
    $stmt->finish;

    my @txn_col  = BOM::Database::AutoGenerated::Rose::Transaction->meta->columns;
    my @fmb_col  = BOM::Database::AutoGenerated::Rose::FinancialMarketBet->meta->columns;
    my @chld_col = BOM::Database::AutoGenerated::Rose::FinancialMarketBet->meta->{relationships}->{$bet_class}->class->meta->columns;
    my @qv_col   = BOM::Database::AutoGenerated::Rose::QuantsBetVariable->meta->columns;

    BAIL_OUT "DB structure does not match Rose classes"
        unless 2 * @txn_col + @fmb_col + @chld_col + 2 * @qv_col == @$res;

    my %txn;
    @txn{@txn_col} = splice @$res, 0, 0 + @txn_col;

    my %fmb;
    @fmb{@fmb_col} = splice @$res, 0, 0 + @fmb_col;

    my %chld;
    @chld{@chld_col} = splice @$res, 0, 0 + @chld_col;

    my %qv1;
    @qv1{@qv_col} = splice @$res, 0, 0 + @qv_col;

    my %qv2;
    @qv2{@qv_col} = splice @$res, 0, 0 + @qv_col;

    my %t2;
    @t2{@txn_col} = splice @$res, 0, 0 + @txn_col;

    return \%txn, \%fmb, \%chld, \%qv1, \%qv2, \%t2;
}

my $cl;
my $acc_usd;

####################################################################
# real tests begin here
####################################################################

lives_ok {
    $cl = create_client;

    #make sure client can trade
    ok(!BOM::Transaction::Validation->new({clients => [$cl]})->check_trade_status($cl),      "client can trade: check_trade_status");
    ok(!BOM::Transaction::Validation->new({clients => [$cl]})->_validate_client_status($cl), "client can trade: _validate_client_status");

    top_up $cl, 'USD', 5000;

    $acc_usd = $cl->account;
    is $acc_usd->currency_code, 'USD', 'got USD account';

    my $bal;
    is + ($bal = $acc_usd->balance + 0), 5000, 'USD balance is 5000 got: ' . $bal;
}
'client created and funded';

my ($trx, $fmb, $chld, $qv1, $qv2);

subtest 'test lookbacks slippage', sub {
    lives_ok {
        my $contract = produce_contract({
            underlying   => $underlying,
            bet_type     => 'LBFLOATCALL',
            currency     => 'USD',
            multiplier   => 100,
            duration     => '30m',
            current_tick => $tick,
        });

        note("contract's ask price " . $contract->ask_price);
        # to properly illustrate the parameters passed in from websocket,
        # payout is always zero without amount_type
        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => $contract->ask_price,
            payout        => 0,
            source        => 19,
            purchase_date => $contract->date_start,
        });
        my $error = $txn->buy;
        is $error, undef, 'case 1 no error';

        is $txn->price_slippage + 0, 0, 'price_slippage = 0';
        ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db lookback_option => $txn->transaction_id;

        subtest 'case 2 fmb row', sub {
            plan tests => 1;
            is $fmb->{buy_price} + 0, 60, 'buy_price';
        };

        subtest 'case 2 qv row', sub {
            plan tests => 1;
            is $qv1->{trade} + 0, 60, 'trade';
        };

        note("allowed slippage for this contract is " . $contract->allowed_slippage);
        my $price = financialrounding('price', $contract->currency, $contract->ask_price - $contract->allowed_slippage + 0.01);
        $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => $price,
            multiplier    => $contract->multiplier,
            payout        => 0,
            source        => 19,
            purchase_date => $contract->date_start,
        });

        $error = $txn->buy;
        is $txn->price_slippage, financialrounding('price', $contract->currency, $txn->price - $contract->ask_price), 'price slippage recorded';
        is $error,               undef,                                                                               'case 2 no error';

        ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db lookback_option => $txn->transaction_id;

        subtest 'case 2 fmb row', sub {
            plan tests => 1;
            is $fmb->{buy_price} + 0, $price, 'buy_price';
        };

        subtest 'case 2 qv row', sub {
            plan tests => 1;
            is $qv1->{trade} + 0, $price, 'trade';
        };

        $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => $price - 0.02,
            multiplier    => $contract->multiplier,
            payout        => 0,
            source        => 19,
            purchase_date => $contract->date_start,
        });

        $error = $txn->buy;
        is $error->{-type}, 'PriceMoved';
        is $error->{-message_to_client},
            'The underlying market has moved too much since you priced the contract. The contract price has changed from 59.40 USD to 60.00 USD.';

        $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => $contract->ask_price + $contract->allowed_slippage + 0.01,
            multiplier    => $contract->multiplier,
            payout        => 0,
            source        => 19,
            purchase_date => $contract->date_start,
        });

        $error = $txn->buy;
        is $error, undef, 'case 2 no error';
        ok $txn->execute_at_better_price, 'executed at better price';
        is $txn->price_slippage, financialrounding('price', $contract->currency, $contract->allowed_slippage + 0.01);

        ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db lookback_option => $txn->transaction_id;

        subtest 'case 2 fmb row', sub {
            plan tests => 1;
            is $fmb->{buy_price} + 0, $contract->ask_price, 'buy_price';
        };

        subtest 'case 2 qv row', sub {
            plan tests => 1;
            is $qv1->{trade} + 0, $contract->ask_price, 'trade';
        };
    }
    'survived';
};

subtest 'test callputspread slippage' => sub {
    lives_ok {
        my $contract = produce_contract({
            underlying    => 'R_100',
            bet_type      => 'CALLSPREAD',
            currency      => 'USD',
            payout        => 100,
            duration      => '2m',
            current_tick  => $tick,
            barrier_range => 'middle',
        });

        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => $contract->ask_price,
            payout        => $contract->payout,
            amount_type   => 'payout',
            purchase_date => $contract->date_start,
        });

        my $error = $txn->buy;
        is $txn->price_slippage + 0, 0, 'no price slippage';
        ok !$error, 'no error';

        my $price = financialrounding('prcie', $contract->currency, $contract->ask_price - $contract->allowed_slippage + 0.01);
        $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => $price,
            payout        => $contract->payout,
            amount_type   => 'payout',
            purchase_date => $contract->date_start,
        });

        $error = $txn->buy;
        ok !$error, 'no error';

        ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db lookback_option => $txn->transaction_id;

        subtest 'case 2 fmb row', sub {
            plan tests => 1;
            is $fmb->{buy_price} + 0, $price, 'buy_price';
        };

        subtest 'case 2 qv row', sub {
            plan tests => 1;
            is $qv1->{trade} + 0, $price, 'trade';
        };

        $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => $price - 0.02,
            payout        => $contract->payout,
            amount_type   => 'payout',
            purchase_date => $contract->date_start,
        });
        $error = $txn->buy;
        is $error->{-type}, 'PriceMoved';
        is $error->{-message_to_client},
            'The underlying market has moved too much since you priced the contract. The contract price has changed from 50.29 USD to 50.60 USD.';

        $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => $contract->ask_price + $contract->allowed_slippage + 0.01,
            payout        => $contract->payout,
            amount_type   => 'payout',
            source        => 19,
            purchase_date => $contract->date_start,
        });

        $error = $txn->buy;
        is $error, undef, 'case 2 no error';
        ok $txn->execute_at_better_price, 'executed at better price';
        is $txn->price_slippage, financialrounding('price', $contract->currency, $contract->allowed_slippage + 0.01);

        ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db lookback_option => $txn->transaction_id;

        subtest 'case 2 fmb row', sub {
            plan tests => 1;
            is $fmb->{buy_price}, $contract->ask_price, 'buy_price';
        };

        subtest 'case 2 qv row', sub {
            plan tests => 1;
            is $qv1->{trade}, $contract->ask_price, 'trade';
        };
    }
    'survived';
};

subtest 'test CALL (binary) slippage' => sub {
    lives_ok {
        my $contract = produce_contract({
            underlying   => 'R_100',
            bet_type     => 'CALL',
            currency     => 'USD',
            payout       => 100,
            duration     => '2m',
            current_tick => $tick,
            barrier      => 'S0P',
        });

        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => $contract->ask_price,
            payout        => $contract->payout,
            amount_type   => 'payout',
            purchase_date => $contract->date_start,
        });

        my $error = $txn->buy;
        is $txn->price_slippage + 0, 0, 'no price slippage';
        ok !$error, 'no error';

        my $price = $contract->ask_price - ($contract->allowed_slippage * $contract->payout - 0.01);

        $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => $price,
            payout        => $contract->payout,
            amount_type   => 'payout',
            purchase_date => $contract->date_start,
        });

        $error = $txn->buy;
        ok !$error, 'no error';
        is $txn->price_slippage, '-0.59', 'correct price slippage';

        ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db higher_lower_bet => $txn->transaction_id;

        subtest 'case 2 fmb row', sub {
            plan tests => 1;
            is $fmb->{buy_price} + 0, $price, 'buy_price';
        };

        subtest 'case 2 qv row', sub {
            plan tests => 1;
            is $qv1->{trade} + 0, $price, 'trade';
        };

        $price = $contract->ask_price - ($contract->allowed_slippage * $contract->payout + 0.01);
        $txn   = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => $price,
            payout        => $contract->payout,
            amount_type   => 'payout',
            purchase_date => $contract->date_start,
        });

        $error = $txn->buy;
        is $error->{-type}, 'PriceMoved';
        like $error->{-message_to_client}, qr/The underlying market has moved too much since you priced the contract. The contract price has changed/;

        $price = $contract->ask_price + ($contract->allowed_slippage * $contract->payout + 0.01);
        $txn   = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => $price,
            payout        => $contract->payout,
            amount_type   => 'payout',
            source        => 19,
            purchase_date => $contract->date_start,
        });

        $error = $txn->buy;
        is $error, undef, 'case 2 no error';
        ok $txn->execute_at_better_price, 'executed at better price';
        is $txn->price_slippage, '0.61';

        ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db higher_lower_bet => $txn->transaction_id;

        subtest 'case 2 fmb row', sub {
            plan tests => 1;
            is $fmb->{buy_price} + 0, $contract->ask_price, 'buy_price';
        };

        subtest 'case 2 qv row', sub {
            plan tests => 1;
            is $qv1->{trade} + 0, $contract->ask_price, 'trade';
        };
    }
    'survived amount_type=payout';

    lives_ok {
        my $contract = produce_contract({
            underlying   => 'R_100',
            bet_type     => 'CALL',
            currency     => 'USD',
            amount       => 50,
            amount_type  => 'stake',
            duration     => '2m',
            current_tick => $tick,
            barrier      => 'S0P',
        });

        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => $contract->ask_price,
            payout        => $contract->payout,
            amount_type   => 'stake',
            purchase_date => $contract->date_start,
        });

        my $error = $txn->buy;
        is $txn->price_slippage + 0, 0, 'no price slippage';
        ok !$error, 'no error';

        note('slippage is calculated from requested payout if amount_type=stake');
        my $payout = $contract->payout - 0.3;
        $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => $contract->ask_price,
            payout        => $payout,
            amount_type   => 'stake',
            purchase_date => $contract->date_start,
        });

        $error = $txn->buy;
        ok !$error, 'no error';
        is $txn->price_slippage, '0.30', 'correct price slippage';

        ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db higher_lower_bet => $txn->transaction_id;

        subtest 'case 2 fmb row', sub {
            is $fmb->{buy_price} + 0,    $contract->ask_price, 'buy_price';
            is $fmb->{payout_price} + 0, $payout,              'payout_price';
            ok $fmb->{short_code} =~ /$payout/, 'properly saved payout in shortcode';
        };

        $payout = $contract->payout + 0.61;
        $txn    = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => $contract->ask_price,
            payout        => $payout,
            amount_type   => 'stake',
            purchase_date => $contract->date_start,
        });

        $error = $txn->buy;
        is $error->{-type}, 'PriceMoved';
        like $error->{-message_to_client},
            qr/The underlying market has moved too much since you priced the contract. The contract payout has changed from/;

        $payout = $contract->payout - 0.61;
        $txn    = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => $contract->ask_price,
            payout        => $payout,
            amount_type   => 'stake',
            source        => 19,
            purchase_date => $contract->date_start,
        });

        $error = $txn->buy;
        is $error, undef, 'case 2 no error';
        ok $txn->execute_at_better_price, 'executed at better price';
        is $txn->price_slippage, '0.61';

        ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db higher_lower_bet => $txn->transaction_id;

        subtest 'case 2 fmb row', sub {
            is $fmb->{buy_price} + 0,    $contract->ask_price, 'buy_price';
            is $fmb->{payout_price} + 0, $contract->payout,    'payout_price';
            ok $fmb->{short_code} =~ /97\.73/, 'properly saved payout in shortcode';
        };

    }
    'survived amount_type=stake';
};

SKIP: {
    skip "skip running time sensitive tests for code coverage tests", 1 if $ENV{DEVEL_COVER_OPTIONS};

    subtest "high input price" => sub {
        my $contract = produce_contract({
            underlying   => create_underlying('R_100'),
            bet_type     => 'CALL',
            currency     => 'USD',
            payout       => 100,
            duration     => '5m',
            current_tick => $tick,
            barrier      => 'S0P',
        });

        # amount_type = payout with high price
        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 10000,
            payout        => 100,
            amount_type   => 'payout',
            purchase_date => Date::Utility->new(),
        });

        ok !$txn->buy, 'buy successful without error';
        ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db lookback_option => $txn->transaction_id;
        is $fmb->{buy_price} + 0, $contract->ask_price, 'buy_price';

        # amount_type = stake with high price
        $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 10000,
            payout        => 100,
            amount_type   => 'stake',
            purchase_date => Date::Utility->new(),
        });

        ok !$txn->buy, 'buy successful without error';
        ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db lookback_option => $txn->transaction_id;
        is $fmb->{buy_price} + 0, $contract->ask_price, 'buy_price';
    };
}

subtest 'test (binary) sell slippage' => sub {
    my $mocked_contract = Test::MockModule->new('BOM::Product::Contract::Call');
    note('mocking $contract->is_valid_to_sell to return 1.');
    $mocked_contract->mock('is_valid_to_sell', sub { return 1 });
    my $contract = produce_contract({
        underlying   => 'R_100',
        bet_type     => 'CALL',
        currency     => 'USD',
        payout       => 100,
        duration     => '2m',
        current_tick => $tick,
        barrier      => 'S0P',
    });

    my $txn = BOM::Transaction->new({
        client        => $cl,
        contract      => $contract,
        price         => $contract->ask_price,
        payout        => $contract->payout,
        amount_type   => 'payout',
        purchase_date => $contract->date_start,
    });

    ok !$txn->buy, 'no error in buy';
    ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db higher_lower_bet => $txn->transaction_id;

    my $contract_sell = produce_contract({
        date_start   => $contract->date_start,
        date_pricing => $contract->date_start->plus_time_interval('1s'),
        underlying   => 'R_100',
        bet_type     => 'CALL',
        currency     => 'USD',
        payout       => 100,
        duration     => '2m',
        current_tick => $tick,
        barrier      => 'S0P',
    });

    $txn = BOM::Transaction->new({
        client        => $cl,
        contract_id   => $fmb->{id},
        contract      => $contract_sell,
        price         => $contract->bid_price,
        purchase_date => $contract->date_start,
    });

    ok !$txn->sell, 'sell with no error';
    ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db higher_lower_bet => $txn->transaction_id;

    is $fmb->{sell_price}, $contract_sell->bid_price, 'sell price saved correctly';

    $txn = BOM::Transaction->new({
        client        => $cl,
        contract      => $contract,
        price         => $contract->ask_price,
        payout        => $contract->payout,
        amount_type   => 'payout',
        purchase_date => $contract->date_start,
    });

    ok !$txn->buy, 'no error in buy';
    ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db higher_lower_bet => $txn->transaction_id;

    note('slippage on sell for binary is based on payout.');
    my $price = $contract_sell->bid_price - ($contract_sell->allowed_slippage * $contract_sell->payout - 0.01);

    $txn = BOM::Transaction->new({
        client        => $cl,
        contract_id   => $fmb->{id},
        contract      => $contract_sell,
        price         => $price,
        purchase_date => $contract->date_start,
    });

    ok !$txn->sell, 'sell with no error';
    ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db higher_lower_bet => $txn->transaction_id;

    is $fmb->{sell_price} + 0, $price, 'sell price is correct';
    is $txn->price_slippage,   '0.59', 'correct price slippage';

    $txn = BOM::Transaction->new({
        client        => $cl,
        contract      => $contract,
        price         => $contract->ask_price,
        payout        => $contract->payout,
        amount_type   => 'payout',
        purchase_date => $contract->date_start,
    });

    ok !$txn->buy, 'no error in buy';
    ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db higher_lower_bet => $txn->transaction_id;

    note('slippage on sell for binary is based on payout.');
    $price = $contract_sell->bid_price + ($contract_sell->allowed_slippage * $contract_sell->payout - 0.01);

    $txn = BOM::Transaction->new({
        client        => $cl,
        contract_id   => $fmb->{id},
        contract      => $contract_sell,
        price         => $price,
        purchase_date => $contract->date_start,
    });

    ok !$txn->sell, 'sell with no error';
    ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db higher_lower_bet => $txn->transaction_id;

    is $fmb->{sell_price} + 0, $price,  'sell price is correct';
    is $txn->price_slippage,   '-0.59', 'correct price slippage';

    $txn = BOM::Transaction->new({
        client        => $cl,
        contract      => $contract,
        price         => $contract->ask_price,
        payout        => $contract->payout,
        amount_type   => 'payout',
        purchase_date => $contract->date_start,
    });

    ok !$txn->buy, 'no error in buy';
    ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db higher_lower_bet => $txn->transaction_id;

    note('slippage on sell for binary is based on payout.');
    $price = $contract_sell->bid_price + ($contract_sell->allowed_slippage * $contract_sell->payout + 0.01);

    $txn = BOM::Transaction->new({
        client        => $cl,
        contract_id   => $fmb->{id},
        contract      => $contract_sell,
        price         => $price,
        purchase_date => $contract->date_start,
    });

    my $error = $txn->sell;
    is $error->{-type}, 'PriceMoved', 'error type - PriceMoved';
    SKIP: {
        skip "skip running time sensitive tests for code coverage tests", 1 if $ENV{DEVEL_COVER_OPTIONS};
        is $error->{-message_to_client},
            'The underlying market has moved too much since you priced the contract. The contract sell price has changed from 49.37 USD to 48.76 USD.',
            'error message_to_client - The underlying market has moved too much since you priced the contract. The contract sell price has changed from 49.37 USD to 48.76 USD.';
    }
};

done_testing();
