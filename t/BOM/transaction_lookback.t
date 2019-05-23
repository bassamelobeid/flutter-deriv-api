#!/etc/rmg/bin/perl

use strict;
use warnings;
use Test::MockTime qw/:all/;
use Test::MockModule;
use Test::More tests => 10;
use Test::Exception;
use Guard;
use Crypt::NamedKeys;
use BOM::User::Client;
use BOM::User::Password;
use BOM::User::Utility;

use Date::Utility;
use BOM::Transaction;
use BOM::Transaction::Validation;
use Math::Util::CalculatedValue::Validatable;
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Helper::Client qw(top_up);
use BOM::Platform::Client::IDAuthentication;

use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;

use BOM::User;
use BOM::User::Password;

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

my $old_tick1 = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch - 99,
    underlying => 'R_50',
    quote      => 76.5996,
    bid        => 76.6010,
    ask        => 76.2030,
});

my $old_tick2 = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch - 52,
    underlying => 'R_50',
    quote      => 76.6996,
    bid        => 76.7010,
    ask        => 76.3030,
});

my $old_tick3 = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch - 51,
    underlying => 'R_50',
    quote      => 76.6996,
});

my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch,
    underlying => 'R_50',
});

BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch + 60,
    underlying => 'R_50',
});

BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch + 120,
    underlying => 'R_50',
});

my $underlying        = create_underlying('frxUSDJPY');
my $underlying_GDAXI  = create_underlying('GDAXI');
my $underlying_WLDUSD = create_underlying('WLDUSD');
my $underlying_R50    = create_underlying('R_50');

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
        secret_question  => 'What the f***?',
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
my $acc_aud;

####################################################################
# real tests begin here
####################################################################

lives_ok {
    $cl = create_client;

    #make sure client can trade
    ok(!BOM::Transaction::Validation->new({clients => [$cl]})->check_trade_status($cl),      "client can trade: check_trade_status");
    ok(!BOM::Transaction::Validation->new({clients => [$cl]})->_validate_client_status($cl), "client can trade: _validate_client_status");

    top_up $cl, 'USD', 5000;

    isnt + ($acc_usd = $cl->account), 'USD', 'got USD account';

    my $bal;
    is + ($bal = $acc_usd->balance + 0), 5000, 'USD balance is 5000 got: ' . $bal;
}
'client created and funded';

my ($trx, $fmb, $chld, $qv1, $qv2);

my $new_client = create_client;
top_up $new_client, 'USD', 5000;
my $new_acc_usd = $new_client->account;

subtest 'buy a bet with zero price', sub {
    plan tests => 2;
    lives_ok {
        my $contract = produce_contract({
            underlying   => $underlying_R50,
            bet_type     => 'LBFLOATCALL',
            currency     => 'USD',
            amount       => 5.0,
            duration     => '30m',
            current_tick => $tick,
            amount_type  => 'multiplier',
        });

        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 0,
            amount        => $contract->multiplier,
            amount_type   => 'multiplier',
            source        => 19,
            purchase_date => $contract->date_start,
        });

        my $error = $txn->buy;
        is $error->{-message_to_client},
            'The underlying market has moved too much since you priced the contract. The contract price has changed from USD0.00 to USD2.50.',
            'slippage error';
    }
    'survived';
};

subtest 'buy a bet', sub {
    plan tests => 11;
    lives_ok {
        my $contract = produce_contract({
            underlying   => $underlying_R50,
            bet_type     => 'LBFLOATCALL',
            currency     => 'USD',
            amount       => 5.0,
            duration     => '30m',
            current_tick => $tick,
            amount_type  => 'multiplier',
        });

        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => $contract->ask_price,
            amount        => $contract->multiplier,
            amount_type   => 'multiplier',
            source        => 19,
            purchase_date => $contract->date_start,
        });

        my $error = $txn->buy;
        is $error, undef, 'no error';

        subtest 'transaction report', sub {
            plan tests => 11;
            note $txn->report;
            my $report = $txn->report;
            like $report, qr/\ATransaction Report:$/m,                                                    'header';
            like $report, qr/^\s*Client: \Q${\$cl}\E$/m,                                                  'client';
            like $report, qr/^\s*Contract: \Q${\$contract->code}\E$/m,                                    'contract';
            like $report, qr/^\s*Price: \Q${\$txn->price}\E$/m,                                           'price';
            like $report, qr/^\s*Payout: \Q${\$txn->payout}\E$/m,                                         'payout';
            like $report, qr/^\s*Amount Type: \Q${\$txn->amount_type}\E$/m,                               'amount_type';
            like $report, qr/^\s*Comment: \Q${\$txn->comment->[0]}\E$/m,                                  'comment';
            like $report, qr/^\s*Staff: \Q${\$txn->staff}\E$/m,                                           'staff';
            like $report, qr/^\s*Transaction Parameters: \$VAR1 = \{$/m,                                  'transaction parameters';
            like $report, qr/^\s*Transaction ID: \Q${\$txn->transaction_id}\E$/m,                         'transaction id';
            like $report, qr/^\s*Purchase Date: \Q${\$txn->purchase_date->datetime_yyyymmdd_hhmmss}\E$/m, 'purchase date';
        };

        ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db lookback_option => $txn->transaction_id;

        # note explain $trx;

        subtest 'transaction row', sub {
            plan tests => 12;
            cmp_ok $trx->{id}, '>', 0, 'id';
            is $trx->{account_id}, $acc_usd->id, 'account_id';
            is $trx->{action_type}, 'buy', 'action_type';
            is $trx->{amount} + 0, -2.5, 'amount';
            is $trx->{balance_after} + 0, 5000 - 2.5, 'balance_after';
            is $trx->{financial_market_bet_id}, $fmb->{id}, 'financial_market_bet_id';
            is $trx->{payment_id},    undef,                  'payment_id';
            is $trx->{referrer_type}, 'financial_market_bet', 'referrer_type';
            is $trx->{remark},        undef,                  'remark';
            is $trx->{staff_loginid}, $cl->loginid, 'staff_loginid';
            is $trx->{source}, 19, 'source';
            cmp_ok +Date::Utility->new($trx->{transaction_time})->epoch, '<=', time, 'transaction_time';
        };

        # note explain $fmb;

        subtest 'fmb row', sub {
            plan tests => 19;
            cmp_ok $fmb->{id}, '>', 0, 'id';
            is $fmb->{account_id}, $acc_usd->id, 'account_id';
            is $fmb->{bet_class}, 'lookback_option', 'bet_class';
            is $fmb->{bet_type},  'LBFLOATCALL',     'bet_type';
            is $fmb->{buy_price} + 0, 2.5, 'buy_price';
            is !$fmb->{expiry_daily}, !$contract->expiry_daily, 'expiry_daily';
            cmp_ok +Date::Utility->new($fmb->{expiry_time})->epoch, '>', time, 'expiry_time';
            is $fmb->{fixed_expiry}, undef, 'fixed_expiry';
            is !$fmb->{is_expired}, !0, 'is_expired';
            is !$fmb->{is_sold},    !0, 'is_sold';
            cmp_ok +Date::Utility->new($fmb->{purchase_time})->epoch, '<=', time, 'purchase_time';
            like $fmb->{remark},   qr/\btrade\[2\.50000\]/, 'remark';
            is $fmb->{sell_price}, undef,                   'sell_price';
            is $fmb->{sell_time},  undef,                   'sell_time';
            cmp_ok +Date::Utility->new($fmb->{settlement_time})->epoch, '>', time, 'settlement_time';
            like $fmb->{short_code}, qr/CALL/, 'short_code';
            cmp_ok +Date::Utility->new($fmb->{start_time})->epoch, '<=', time, 'start_time';
            is $fmb->{tick_count},        undef,  'tick_count';
            is $fmb->{underlying_symbol}, 'R_50', 'underlying_symbol';
        };

        # note explain $chld;

        subtest 'chld row', sub {
            plan tests => 3;
            is $chld->{absolute_barrier}, undef, 'absolute_barrier';
            is $chld->{financial_market_bet_id}, $fmb->{id}, 'financial_market_bet_id';
            is $chld->{prediction}, undef, 'prediction';
        };

        # note explain $qv1;

        subtest 'qv row', sub {
            plan tests => 3;
            is $qv1->{financial_market_bet_id}, $fmb->{id}, 'financial_market_bet_id';
            is $qv1->{transaction_id},          $trx->{id}, 'transaction_id';
            is $qv1->{trade} + 0, 2.5, 'trade';
        };

        is $txn->contract_id,    $fmb->{id},            'txn->contract_id';
        is $txn->transaction_id, $trx->{id},            'txn->transaction_id';
        is $txn->balance_after,  $trx->{balance_after}, 'txn->balance_after';
        is $txn->execute_at_better_price, 0, 'txn->execute_at_better_price';
    }
    'survived';
};

subtest 'sell a bet', sub {
    plan tests => 10;
    lives_ok {
        set_relative_time 1;
        my $reset_time = guard { restore_time };

        my $contract = produce_contract({
            underlying   => $underlying_R50,
            bet_type     => 'LBFLOATCALL',
            currency     => 'USD',
            amount       => 5,
            amount_type  => 'multiplier',
            duration     => '30m',
            current_tick => $tick,
            entry_tick   => $tick,
            exit_tick    => $tick,
        });
        my $txn;
        #note 'bid price: ' . $contract->bid_price;
        my $error = do {
            my $mocked           = Test::MockModule->new('BOM::Transaction');
            my $mocked_validator = Test::MockModule->new('BOM::Transaction::Validation');
            $mocked_validator->mock('_validate_trade_pricing_adjustment', sub { });
            $mocked->mock('price', sub { $contract->bid_price });
            $txn = BOM::Transaction->new({
                purchase_date => $contract->date_start,
                client        => $cl,
                contract      => $contract,
                contract_id   => $fmb->{id},
                price         => $contract->bid_price,
                source        => 23,
            });
            $txn->sell;
        };
        is $error, undef, 'no error';

        ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db lookback_option => $txn->transaction_id;

        # note explain $trx;

        subtest 'transaction row', sub {
            plan tests => 13;
            cmp_ok $trx->{id}, '>', 0, 'id';
            is $trx->{account_id}, $acc_usd->id, 'account_id';
            is $trx->{action_type}, 'sell', 'action_type';
            is $trx->{amount} + 0, $contract->bid_price + 0, 'amount';
            is $trx->{balance_after} + 0, 5000 - 2.5 + $contract->bid_price, 'balance_after';
            is $trx->{financial_market_bet_id}, $fmb->{id}, 'financial_market_bet_id';
            is $trx->{payment_id},    undef,                  'payment_id';
            is $trx->{quantity},      1,                      'quantity';
            is $trx->{referrer_type}, 'financial_market_bet', 'referrer_type';
            is $trx->{remark},        undef,                  'remark';
            is $trx->{staff_loginid}, $cl->loginid, 'staff_loginid';
            is $trx->{source}, 23, 'source';
            cmp_ok +Date::Utility->new($trx->{transaction_time})->epoch, '<=', time, 'transaction_time';
        };

        # note explain $fmb;

        subtest 'fmb row', sub {
            plan tests => 19;
            cmp_ok $fmb->{id}, '>', 0, 'id';
            is $fmb->{account_id}, $acc_usd->id, 'account_id';
            is $fmb->{bet_class}, 'lookback_option', 'bet_class';
            is $fmb->{bet_type},  'LBFLOATCALL',     'bet_type';
            is $fmb->{buy_price} + 0, 2.5, 'buy_price';
            is !$fmb->{expiry_daily}, !$contract->expiry_daily, 'expiry_daily';
            cmp_ok +Date::Utility->new($fmb->{expiry_time})->epoch, '>', time, 'expiry_time';
            is $fmb->{fixed_expiry}, undef, 'fixed_expiry';
            is $fmb->{is_expired},   0,     'is_expired';
            is !$fmb->{is_sold}, !1, 'is_sold';
            cmp_ok +Date::Utility->new($fmb->{purchase_time})->epoch, '<=', time, 'purchase_time';
            like $fmb->{remark}, qr/\btrade\[2\.50000\]/, 'remark';
            is $fmb->{sell_price} + 0, $contract->bid_price + 0, 'sell_price';
            cmp_ok +Date::Utility->new($fmb->{sell_time})->epoch,       '<=', time, 'sell_time';
            cmp_ok +Date::Utility->new($fmb->{settlement_time})->epoch, '>',  time, 'settlement_time';
            like $fmb->{short_code}, qr/CALL/, 'short_code';
            cmp_ok +Date::Utility->new($fmb->{start_time})->epoch, '<=', time, 'start_time';
            is $fmb->{tick_count},        undef,  'tick_count';
            is $fmb->{underlying_symbol}, 'R_50', 'underlying_symbol';
        };

        # note explain $chld;

        subtest 'chld row', sub {
            plan tests => 4;
            is $chld->{absolute_barrier}, undef, 'absolute_barrier';
            is $chld->{financial_market_bet_id}, $fmb->{id}, 'financial_market_bet_id';
            is $chld->{prediction},       undef, 'prediction';
            is $chld->{relative_barrier}, undef, 'relative_barrier';
        };

        # note explain $qv1;

        subtest 'qv row', sub {
            plan tests => 3;
            is $qv1->{financial_market_bet_id}, $fmb->{id}, 'financial_market_bet_id';
            is $qv1->{transaction_id},          $trx->{id}, 'transaction_id';
            is $qv1->{trade} + 0, $contract->bid_price + 0, 'trade';
        };

        # note explain $qv2;

        subtest 'qv row (buy transaction)', sub {
            plan tests => 3;
            is $qv2->{financial_market_bet_id}, $fmb->{id}, 'financial_market_bet_id';
            isnt $qv2->{transaction_id},        $trx->{id}, 'transaction_id';
            is $qv2->{trade} + 0, 2.5, 'trade';
        };

        is $txn->contract_id,    $fmb->{id},            'txn->contract_id';
        is $txn->transaction_id, $trx->{id},            'txn->transaction_id';
        is $txn->balance_after,  $trx->{balance_after}, 'txn->balance_after';
    }
    'survived';
};

subtest 'sell_expired_contracts', sub {
    plan tests => 7;
    lives_ok {
        my $cl = create_client;

        top_up $cl, 'USD', 1000;

        isnt + (my $acc_usd = $cl->account), 'USD', 'got USD account';

        my $bal;
        is + ($bal = $acc_usd->balance + 0), 1000, 'USD balance is 1000 got: ' . $bal;

        my $contract_expired = produce_contract({
            underlying   => $underlying_R50,
            bet_type     => 'LBFLOATCALL',
            currency     => 'USD',
            amount       => 5,
            amount_type  => 'multiplier',
            date_start   => ($now->epoch - 50) - (30 * 60),
            date_expiry  => $now->epoch - 50,
            date_pricing => $now,
            current_tick => $tick,
            entry_tick   => $old_tick1,
            exit_tick    => $old_tick3,
        });

        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract_expired,
            price         => $contract_expired->ask_price,
            amount_type   => 'multiplier',
            amount        => 10,
            purchase_date => $now->epoch - (30 * 60 + 51),
        });

        my (@expired_txnids, @expired_fmbids, @unexpired_fmbids);
        # buy 2 expired contracts
        for (1 .. 2) {
            my $error = $txn->buy(skip_validation => 1);
            is $error, undef, 'no error: bought 1 expired contract for 100';
            push @expired_txnids, $txn->transaction_id;
            push @expired_fmbids, $txn->contract_id;
        }

        is $acc_usd->balance + 0, 995, 'USD balance is down to 900 plus';

        # First sell some particular ones by id.
        my $res = BOM::Transaction::sell_expired_contracts + {
            client       => $cl,
            source       => 29,
            contract_ids => [@expired_fmbids[0 .. 1]],
        };

        is_deeply $res,
            +{
            number_of_sold_bets => 2,
            skip_contract       => 0,
            total_credited      => 1,
            failures            => [],
            },
            'sold the two requested contracts';

    }
    'survived';
};
