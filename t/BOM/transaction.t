#!/etc/rmg/bin/perl

use strict;
use warnings;
use Test::MockTime qw/:all/;
use Test::MockModule;
use Test::More tests => 22;
use Test::Exception;
use Guard;
use Crypt::NamedKeys;
use Client::Account;
use BOM::Platform::Password;
use BOM::Platform::Client::Utility;

use Date::Utility;
use BOM::Transaction;
use BOM::Transaction::Validation;
use Math::Util::CalculatedValue::Validatable;
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Platform::Client::IDAuthentication;

use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use LandingCompany::Offerings qw(reinitialise_offerings);

reinitialise_offerings(BOM::Platform::Runtime->instance->get_offerings_config);

Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';

my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');

$mock_validation->mock(validate_tnc => sub { note "mocked Transaction::Validation->validate_tnc returning nothing"; undef });

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

my $now = Date::Utility->new;
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => Date::Utility->new,
    }) for qw(JPY USD JPY-USD);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'randomindex',
    {
        symbol => 'R_50',
        date   => Date::Utility->new
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $now,
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'randomindex',
    {
        symbol => 'R_100',
        date   => Date::Utility->new
    });

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

my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch,
    underlying => 'R_50',
});

my $usdjpy_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch,
    underlying => 'frxUSDJPY',
});

my $tick_r100 = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch,
    underlying => 'R_100',
    quote      => 100,
});

# Spread is calculated base on spot of the underlying.
# In this case, we mocked the spot to 100.
my $mocked_underlying = Test::MockModule->new('Quant::Framework::Underlying');
$mocked_underlying->mock('spot', sub { 100 });

my $underlying      = create_underlying('R_50');
my $underlying_r100 = create_underlying('R_100');

sub db {
    return BOM::Database::ClientDB->new({
            broker_code => 'CR',
        })->db;
}

sub create_client {
    my $broker = shift;
    $broker ||= 'CR';

    return Client::Account->register_and_return_new_client({
        broker_code      => $broker,
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

sub free_gift {
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
        payment_gateway_code => "free_gift",
        payment_type_code    => "free_gift",
        status               => "OK",
        staff_loginid        => "test",
        remark               => __FILE__ . ':' . __LINE__,
    });
    $pm->free_gift({reason => "test"});
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
    ok(!BOM::Transaction::Validation->new({clients => [$cl]})->not_allow_trade($cl), "client can trade");

    top_up $cl, 'USD', 5000;

    isnt + ($acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';

    my $bal;
    is + ($bal = $acc_usd->balance + 0), 5000, 'USD balance is 5000 got: ' . $bal;
}
'client created and funded';

my ($trx, $fmb, $chld, $qv1, $qv2);

my $new_client = create_client;
top_up $new_client, 'USD', 5000;
my $new_acc_usd = $new_client->find_account(query => [currency_code => 'USD'])->[0];

subtest 'buy a bet', sub {
    plan tests => 11;
    lives_ok {
        my $contract = produce_contract({
                underlying => $underlying,
                bet_type   => 'CALL',
                currency   => 'USD',
                payout     => 1000,
                duration   => '15m',
#        date_start   => $now->epoch + 1,
#        date_expiry  => $now->epoch + 300,
                current_tick => $tick,
                barrier      => 'S0P',
        });

        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 514.00,
            payout        => $contract->payout,
            amount_type   => 'payout',
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

        ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db higher_lower_bet => $txn->transaction_id;

        # note explain $trx;

        subtest 'transaction row', sub {
            plan tests => 13;
            cmp_ok $trx->{id}, '>', 0, 'id';
            is $trx->{account_id}, $acc_usd->id, 'account_id';
            is $trx->{action_type}, 'buy', 'action_type';
            is $trx->{amount} + 0, -514, 'amount';
            is $trx->{balance_after} + 0, 5000 - 514, 'balance_after';
            is $trx->{financial_market_bet_id}, $fmb->{id}, 'financial_market_bet_id';
            is $trx->{payment_id},    undef,                  'payment_id';
            is $trx->{quantity},      1,                      'quantity';
            is $trx->{referrer_type}, 'financial_market_bet', 'referrer_type';
            is $trx->{remark},        undef,                  'remark';
            is $trx->{staff_loginid}, $cl->loginid, 'staff_loginid';
            is $trx->{source}, 19, 'source';
            cmp_ok +Date::Utility->new($trx->{transaction_time})->epoch, '<=', time, 'transaction_time';
        };

        # note explain $fmb;

        subtest 'fmb row', sub {
            plan tests => 20;
            cmp_ok $fmb->{id}, '>', 0, 'id';
            is $fmb->{account_id}, $acc_usd->id, 'account_id';
            is $fmb->{bet_class}, 'higher_lower_bet', 'bet_class';
            is $fmb->{bet_type},  'CALL',             'bet_type';
            is $fmb->{buy_price} + 0, 514, 'buy_price';
            is !$fmb->{expiry_daily}, !$contract->expiry_daily, 'expiry_daily';
            cmp_ok +Date::Utility->new($fmb->{expiry_time})->epoch, '>', time, 'expiry_time';
            is $fmb->{fixed_expiry}, undef, 'fixed_expiry';
            is !$fmb->{is_expired}, !0, 'is_expired';
            is !$fmb->{is_sold},    !0, 'is_sold';
            is $fmb->{payout_price} + 0, 1000, 'payout_price';
            cmp_ok +Date::Utility->new($fmb->{purchase_time})->epoch, '<=', time, 'purchase_time';
            like $fmb->{remark},   qr/\btrade\[514\.00000\]/, 'remark';
            is $fmb->{sell_price}, undef,                     'sell_price';
            is $fmb->{sell_time},  undef,                     'sell_time';
            cmp_ok +Date::Utility->new($fmb->{settlement_time})->epoch, '>', time, 'settlement_time';
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
            is $chld->{relative_barrier}, 'S0P', 'relative_barrier';
        };

        # note explain $qv1;

        subtest 'qv row', sub {
            plan tests => 3;
            is $qv1->{financial_market_bet_id}, $fmb->{id}, 'financial_market_bet_id';
            is $qv1->{transaction_id},          $trx->{id}, 'transaction_id';
            is $qv1->{trade} + 0, 514, 'trade';
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
                underlying => $underlying,
                bet_type   => 'CALL',
                currency   => 'USD',
                payout     => 1000,
                duration   => '15m',
#        date_start   => $now->epoch + 1,
#        date_expiry  => $now->epoch + 300,
                current_tick => $tick,
                entry_tick   => $tick,
                exit_tick    => $tick,
                barrier      => 'S0P',
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

        ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db higher_lower_bet => $txn->transaction_id;

        # note explain $trx;

        subtest 'transaction row', sub {
            plan tests => 13;
            cmp_ok $trx->{id}, '>', 0, 'id';
            is $trx->{account_id}, $acc_usd->id, 'account_id';
            is $trx->{action_type}, 'sell', 'action_type';
            is $trx->{amount} + 0, $contract->bid_price, 'amount';
            is $trx->{balance_after} + 0, 5000 - 514 + $contract->bid_price, 'balance_after';
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
            plan tests => 20;
            cmp_ok $fmb->{id}, '>', 0, 'id';
            is $fmb->{account_id}, $acc_usd->id, 'account_id';
            is $fmb->{bet_class}, 'higher_lower_bet', 'bet_class';
            is $fmb->{bet_type},  'CALL',             'bet_type';
            is $fmb->{buy_price} + 0, 514, 'buy_price';
            is !$fmb->{expiry_daily}, !$contract->expiry_daily, 'expiry_daily';
            cmp_ok +Date::Utility->new($fmb->{expiry_time})->epoch, '>', time, 'expiry_time';
            is $fmb->{fixed_expiry}, undef, 'fixed_expiry';
            is !$fmb->{is_expired}, !1, 'is_expired';
            is !$fmb->{is_sold},    !1, 'is_sold';
            is $fmb->{payout_price} + 0, 1000, 'payout_price';
            cmp_ok +Date::Utility->new($fmb->{purchase_time})->epoch, '<=', time, 'purchase_time';
            like $fmb->{remark}, qr/\btrade\[514\.00000\]/, 'remark';
            is $fmb->{sell_price} + 0, $contract->bid_price, 'sell_price';
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
            is $chld->{relative_barrier}, 'S0P', 'relative_barrier';
        };

        # note explain $qv1;

        subtest 'qv row', sub {
            plan tests => 3;
            is $qv1->{financial_market_bet_id}, $fmb->{id}, 'financial_market_bet_id';
            is $qv1->{transaction_id},          $trx->{id}, 'transaction_id';
            is $qv1->{trade} + 0, $contract->bid_price, 'trade';
        };

        # note explain $qv2;

        subtest 'qv row (buy transaction)', sub {
            plan tests => 3;
            is $qv2->{financial_market_bet_id}, $fmb->{id}, 'financial_market_bet_id';
            isnt $qv2->{transaction_id},        $trx->{id}, 'transaction_id';
            is $qv2->{trade} + 0, 514, 'trade';
        };

        is $txn->contract_id,    $fmb->{id},            'txn->contract_id';
        is $txn->transaction_id, $trx->{id},            'txn->transaction_id';
        is $txn->balance_after,  $trx->{balance_after}, 'txn->balance_after';
    }
    'survived';
};

subtest 'insufficient balance: buy bet for 100.01 with a balance of 100', sub {
    plan tests => 7;
    lives_ok {
        top_up $cl, 'USD', 100 - $trx->{balance_after};
        $acc_usd->load;
        is $acc_usd->balance + 0, 100, 'USD balance is now 100';

        my $now      = Date::Utility->new;
        my $contract = produce_contract({
            underlying   => $underlying,
            bet_type     => 'CALL',
            currency     => 'USD',
            stake        => 100.01,
            duration     => '15m',
            current_tick => $tick,
            barrier      => 'S0P',
        });

        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 100.01,
            payout        => $contract->payout,
            amount_type   => 'stake',
            purchase_date => $now,
        });
        my $error = $txn->buy;

        SKIP: {
            skip 'no error', 5
                if not defined $error || ref $error ne 'Error::Base';

            is $error->get_type, 'InsufficientBalance', 'error is InsufficientBalance';

            is $txn->contract_id,    undef, 'txn->contract_id';
            is $txn->transaction_id, undef, 'txn->transaction_id';
            is $txn->balance_after,  undef, 'txn->balance_after';

            subtest 'try again with an expired bet worth 100', sub {
                top_up $cl, 'USD', 100;
                $acc_usd->load;
                is $acc_usd->balance + 0, 200, 'USD balance is now 200';

                my $contract_expired = produce_contract({
                    underlying   => $underlying,
                    bet_type     => 'CALL',
                    currency     => 'USD',
                    stake        => 100,
                    date_start   => $now->epoch - 100,
                    date_expiry  => $now->epoch - 50,
                    current_tick => $tick,
                    entry_tick   => $old_tick1,
                    exit_tick    => $old_tick2,
                    barrier      => 'S0P',
                });

                my $txn = BOM::Transaction->new({
                    client        => $cl,
                    contract      => $contract_expired,
                    price         => 100,
                    payout        => $contract_expired->payout,
                    amount_type   => 'stake',
                    purchase_date => $now->epoch - 101,
                });
                my $error = $txn->buy(skip_validation => 1);

                is $error, undef, 'no error';
                $acc_usd->load;
                is $acc_usd->balance + 0, 100, 'USD balance is now 100 again';

                # here our balance wouldn't allow us to buy a bet for 100.01.
                # but we have an expired but unsold contract that's worth 100.
                # Hence, the buy should succeed.

                my $txn_id_buy_expired_contract = $txn->transaction_id;
                ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db higher_lower_bet => $txn_id_buy_expired_contract;
                is $fmb->{is_sold}, 0, 'have expired but unsold contract in DB';

                $txn = BOM::Transaction->new({
                    client        => $cl,
                    contract      => $contract,
                    price         => 100.01,
                    payout        => $contract->payout,
                    amount_type   => 'stake',
                    source        => 31,
                    purchase_date => $now,
                });
                $error = $txn->buy;

                is $error->get_type, 'InsufficientBalance', 'error is InsufficientBalance';

                # check if the expired contract still has not been sold
                ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db higher_lower_bet => $txn_id_buy_expired_contract;
                is $fmb->{is_sold}, 0, 'have expired but unsold contract in DB';
            };
        }
    }
    'survived';
};

subtest 'exactly sufficient balance: buy bet for 100 with balance of 100', sub {
    plan tests => 9;
    lives_ok {
        $acc_usd->load;
        unless ($acc_usd->balance + 0 == 100) {
            top_up $cl, 'USD', 100 - $acc_usd->balance;
            $acc_usd->load;
        }
        is $acc_usd->balance + 0, 100, 'USD balance is now 100';

        my $contract = produce_contract({
            underlying   => $underlying,
            bet_type     => 'CALL',
            currency     => 'USD',
            stake        => 100.00,
            duration     => '15m',
            current_tick => $tick,
            barrier      => 'S0P',
        });

        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 100.00,
            payout        => $contract->payout,
            amount_type   => 'stake',
            purchase_date => $contract->date_start,
        });
        my $error = $txn->buy;
        is $error, undef, 'no error';

        ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db higher_lower_bet => $txn->transaction_id;

        is $txn->contract_id, $fmb->{id}, 'txn->contract_id';
        cmp_ok $txn->contract_id, '>', 0, 'txn->contract_id > 0';
        is $txn->transaction_id, $trx->{id}, 'txn->transaction_id';
        cmp_ok $txn->transaction_id, '>', 0, 'txn->transaction_id > 0';
        is $txn->balance_after, $trx->{balance_after}, 'txn->balance_after';
        is $txn->balance_after + 0, 0, 'txn->balance_after == 0';
    }
    'survived';
};

subtest 'max_balance validation: try to buy a bet with a balance of 100 and max_balance 99.99', sub {
    plan tests => 8;
    lives_ok {
        $acc_usd->load;
        unless ($acc_usd->balance + 0 == 100) {
            top_up $cl, 'USD', 100 - $acc_usd->balance;
            $acc_usd->load;
        }
        is $acc_usd->balance + 0, 100, 'USD balance is now 100';

        my $contract = produce_contract({
            underlying   => $underlying,
            bet_type     => 'CALL',
            currency     => 'USD',
            stake        => 100.00,
            duration     => '15m',
            current_tick => $tick,
            barrier      => 'S0P',
        });

        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 100.00,
            payout        => $contract->payout,
            amount_type   => 'stake',
            purchase_date => Date::Utility->new(),
        });

        my $error = do {
            my $mock_client = Test::MockModule->new('Client::Account');
            $mock_client->mock(get_limit_for_account_balance => sub { note "mocked Client->get_limit_for_account_balance returning 99.99"; 99.99 });

            $txn->buy;
        };

        SKIP: {
            skip 'no error', 6
                if not defined $error
                or ref $error ne 'Error::Base';

            is $error->get_type, 'AccountBalanceExceedsLimit', 'error is AccountBalanceExceedsLimit';

            like $error->{-message_to_client}, qr/balance is too high \(USD100\.00\)/,   'message_to_client contains balance';
            like $error->{-message_to_client}, qr/maximum account balance is USD99\.99/, 'message_to_client contains limit';

            is $txn->contract_id,    undef, 'txn->contract_id';
            is $txn->transaction_id, undef, 'txn->transaction_id';
            is $txn->balance_after,  undef, 'txn->balance_after';
        }
    }
    'survived';
};

subtest 'max_balance validation: try to buy a bet with a balance of 100 and max_balance 100', sub {
    plan tests => 9;
    lives_ok {
        $acc_usd->load;
        unless ($acc_usd->balance + 0 == 100) {
            top_up $cl, 'USD', 100 - $acc_usd->balance;
            $acc_usd->load;
        }
        is $acc_usd->balance + 0, 100, 'USD balance is now 100';

        my $contract = produce_contract({
            underlying   => $underlying,
            bet_type     => 'CALL',
            currency     => 'USD',
            stake        => 100.00,
            duration     => '15m',
            current_tick => $tick,
            barrier      => 'S0P',
        });

        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 100.00,
            payout        => $contract->payout,
            amount_type   => 'stake',
            purchase_date => $contract->date_start,
        });

        my $error = do {
            my $mock_client = Test::MockModule->new('Client::Account');
            $mock_client->mock(get_limit_for_account_balance => sub { note "mocked Client->get_limit_for_account_balance returning 100"; 100 });

            $txn->buy;
        };
        is $error, undef, 'no error';

        ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db higher_lower_bet => $txn->transaction_id;

        is $txn->contract_id, $fmb->{id}, 'txn->contract_id';
        cmp_ok $txn->contract_id, '>', 0, 'txn->contract_id > 0';
        is $txn->transaction_id, $trx->{id}, 'txn->transaction_id';
        cmp_ok $txn->transaction_id, '>', 0, 'txn->transaction_id > 0';
        is $txn->balance_after, $trx->{balance_after}, 'txn->balance_after';
        is $txn->balance_after + 0, 0, 'txn->balance_after == 0';
    }
    'survived';
};

subtest 'max_open_bets validation', sub {
    plan tests => 10;
    lives_ok {
        my $cl = create_client;

        top_up $cl, 'USD', 100;

        isnt + (my $acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';

        my $bal;
        is + ($bal = $acc_usd->balance + 0), 100, 'USD balance is 100 got: ' . $bal;

        my $now      = Date::Utility->new;
        my $contract = produce_contract({
            underlying   => $underlying,
            bet_type     => 'CALL',
            currency     => 'USD',
            stake        => 1.00,
            duration     => '15m',
            current_tick => $tick,
            barrier      => 'S0P',
        });

        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 1.00,
            payout        => $contract->payout,
            amount_type   => 'stake',
            purchase_date => $contract->date_start,
        });

        my $error = do {
            my $mock_client = Test::MockModule->new('Client::Account');
            $mock_client->mock(get_limit_for_open_positions => sub { note "mocked Client->get_limit_for_open_positions returning 2"; 2 });

            is +BOM::Transaction->new({
                    client        => $cl,
                    contract      => $contract,
                    price         => 1.00,
                    payout        => $contract->payout,
                    amount_type   => 'stake',
                    purchase_date => $contract->date_start,
                })->buy, undef, '1st bet bought';

            is +BOM::Transaction->new({
                    client        => $cl,
                    contract      => $contract,
                    price         => 1.00,
                    payout        => $contract->payout,
                    amount_type   => 'stake',
                    purchase_date => $contract->date_start,
                })->buy, undef, '2nd bet bought';

            $txn->buy;
        };
        SKIP: {
            skip 'no error', 5
                if not defined $error
                or ref $error ne 'Error::Base';

            is $error->get_type, 'OpenPositionLimit', 'error is OpenPositionLimit';

            like $error->{-message_to_client}, qr/you cannot hold more than 2 contract/, 'message_to_client contains limit';

            is $txn->contract_id,    undef, 'txn->contract_id';
            is $txn->transaction_id, undef, 'txn->transaction_id';
            is $txn->balance_after,  undef, 'txn->balance_after';
        }
    }
    'survived';
};

subtest 'max_open_bets validation: selling bets on the way', sub {
    lives_ok {
        my $cl = create_client;

        top_up $cl, 'USD', 100;

        isnt + (my $acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';

        my $bal;
        is + ($bal = $acc_usd->balance + 0), 100, 'USD balance is 100 got: ' . $bal;

        my $contract = produce_contract({
            underlying   => $underlying,
            bet_type     => 'CALL',
            currency     => 'USD',
            stake        => 1.00,
            duration     => '15m',
            current_tick => $tick,
            barrier      => 'S0P',
        });

        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 1.00,
            payout        => $contract->payout,
            amount_type   => 'stake',
            purchase_date => $contract->date_start,
        });

        my $txn_id_buy_expired_contract;
        my $error = do {
            my $mock_client = Test::MockModule->new('Client::Account');
            $mock_client->mock(get_limit_for_open_positions => sub { note "mocked Client->get_limit_for_open_positions returning 2"; 2 });

            is +BOM::Transaction->new({
                    client        => $cl,
                    contract      => $contract,
                    price         => 1.00,
                    payout        => $contract->payout,
                    amount_type   => 'stake',
                    purchase_date => $contract->date_start,
                })->buy, undef, '1st bet bought';

            my $contract_expired = produce_contract({
                underlying   => $underlying,
                bet_type     => 'CALL',
                currency     => 'USD',
                stake        => 1,
                date_start   => $now->epoch - 100,
                date_expiry  => $now->epoch - 50,
                current_tick => $tick,
                entry_tick   => $old_tick1,
                exit_tick    => $old_tick2,
                barrier      => 'S0P',
            });

            my $exp_txn = BOM::Transaction->new({
                client        => $cl,
                contract      => $contract_expired,
                price         => 1,
                payout        => $contract->payout,
                amount_type   => 'stake',
                purchase_date => $now->epoch - 101,
            });

            is $exp_txn->buy(skip_validation => 1), undef, '2nd, expired bet bought';

            $acc_usd->load;
            is $acc_usd->balance + 0, 98, 'USD balance is now 98';

            # here we have 2 open bets. One of them is expired.

            $txn_id_buy_expired_contract = $exp_txn->transaction_id;
            ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db higher_lower_bet => $txn_id_buy_expired_contract;
            is $fmb->{is_sold}, 0, 'have expired but unsold contract in DB';

            return $txn->buy;
        };

        ok $error, 'got error';
        is $error->get_type, 'OpenPositionLimit', 'error is OpenPositionLimit';

        ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db higher_lower_bet => $txn_id_buy_expired_contract;
        is $fmb->{is_sold}, 0, 'have expired but unsold contract in DB';
    }
    'survived';
};

subtest 'max_payout_open_bets validation', sub {
    plan tests => 22;
    lives_ok {
        my $cl = create_client;

        top_up $cl, 'USD', 100;

        isnt + (my $acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';

        my $bal;
        is + ($bal = $acc_usd->balance + 0), 100, 'USD balance is 100 got: ' . $bal;

        my $contract = produce_contract({
            underlying   => $underlying,
            bet_type     => 'CALL',
            currency     => 'USD',
            payout       => 10.00,
            duration     => '15m',
            current_tick => $tick,
            barrier      => 'S0P',
        });

        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 5.20,
            payout        => $contract->payout,
            amount_type   => 'payout',
            purchase_date => $contract->date_start,
        });

        my $error = do {
            my $mock_client = Test::MockModule->new('Client::Account');
            $mock_client->mock(get_limit_for_payout => sub { note "mocked Client->get_limit_for_payout returning 29.99"; 29.99 });

            is +BOM::Transaction->new({
                    client        => $cl,
                    contract      => $contract,
                    price         => 5.20,
                    payout        => $contract->payout,
                    amount_type   => 'payout',
                    purchase_date => $contract->date_start,
                })->buy, undef, '1st bet bought';

            is +BOM::Transaction->new({
                    client        => $cl,
                    contract      => $contract,
                    price         => 5.20,
                    payout        => $contract->payout,
                    amount_type   => 'payout',
                    purchase_date => $contract->date_start,
                })->buy, undef, '2nd bet bought';

            $txn->buy;
        };
        SKIP: {
            skip 'no error', 5
                if not defined $error
                or ref $error ne 'Error::Base';

            is $error->get_type, 'OpenPositionPayoutLimit', 'error is OpenPositionPayoutLimit';

            like $error->{-message_to_client}, qr/aggregate payouts of contracts on your account cannot exceed USD29\.99/,
                'message_to_client contains balance';

            is $txn->contract_id,    undef, 'txn->contract_id';
            is $txn->transaction_id, undef, 'txn->transaction_id';
            is $txn->balance_after,  undef, 'txn->balance_after';
        }

        # retry with a slightly higher limit should succeed
        $error = do {
            my $mock_client = Test::MockModule->new('Client::Account');
            $mock_client->mock(get_limit_for_payout => sub { note "mocked Client->get_limit_for_payout returning 30.00"; 30.00 });

            $txn->buy;
        };

        is $error, undef, 'no error';
    }
    'survived';
    lives_ok {
        my $cl = create_client('MF');
        top_up $cl, 'USD', 100;

        isnt + (my $acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';

        my $bal;
        is + ($bal = $acc_usd->balance + 0), 100, 'USD balance is 100 got: ' . $bal;
        my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
        # we are not testing for price accuracy here so it is fine.
        my $fake_ask_prob = Math::Util::CalculatedValue::Validatable->new({
            name        => 'ask_probability',
            description => 'fake ask probability',
            set_by      => 'test',
            base_amount => 0.537
        });
        $mock_contract->mock('ask_probability', sub { note 'mocking ask_probability to 0.537'; $fake_ask_prob });
        my $contract = produce_contract({
            underlying   => 'frxUSDJPY',
            bet_type     => 'CALL',
            currency     => 'USD',
            payout       => 10.00,
            duration     => '6h',
            current_tick => $usdjpy_tick,
            barrier      => 'S0P',
        });

        # Since we are buying two contracts first before we buy this,
        # I am passing in purchase_time as contract->date_start.
        # We are getting false positive failure of 'ContractAlreadyStarted' on this way too often.
        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 5.37,
            payout        => $contract->payout,
            purchase_date => $contract->date_start,
            amount_type   => 'payout',
        });

        my $error = do {
            my $mock_client = Test::MockModule->new('Client::Account');
            $mock_client->mock(get_limit_for_payout => sub { note "mocked Client->get_limit_for_payout returning 29.99"; 29.99 });
            my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');

            if ($now->is_a_weekend or ($now->day_of_week == 5 and $contract->date_expiry->is_after($now->truncate_to_day->plus_time_interval('21h'))))
            {
                $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

                $mock_validation->mock(
                    _validate_date_pricing => sub { note "mocked Transaction::Validation->_validate_date_pricing returning nothing"; () });
                $mock_validation->mock(_is_valid_to_buy => sub { note "mocked Transaction::Validation->_is_valid_to_buy returning nothing"; () });

            }
            is +BOM::Transaction->new({
                    client        => $cl,
                    contract      => $contract,
                    price         => 5.37,
                    payout        => $contract->payout,
                    amount_type   => 'payout',
                    purchase_date => $contract->date_start,
                })->buy, undef, '1st bet bought';

            is +BOM::Transaction->new({
                    client        => $cl,
                    contract      => $contract,
                    price         => 5.37,
                    payout        => $contract->payout,
                    amount_type   => 'payout',
                    purchase_date => $contract->date_start,
                })->buy, undef, '2nd bet bought';

            $txn->buy;
        };
        SKIP: {
            skip 'no error', 5
                if not defined $error
                or ref $error ne 'Error::Base';

            is $error->get_type, 'OpenPositionPayoutLimit', 'error is OpenPositionPayoutLimit';

            like $error->{-message_to_client}, qr/aggregate payouts of contracts on your account cannot exceed USD29\.99/,
                'message_to_client contains balance';

            is $txn->contract_id,    undef, 'txn->contract_id';
            is $txn->transaction_id, undef, 'txn->transaction_id';
            is $txn->balance_after,  undef, 'txn->balance_after';
        }

        # retry with a slightly higher limit should succeed
        $error = do {
            my $mock_client = Test::MockModule->new('Client::Account');
            $mock_client->mock(get_limit_for_payout => sub { note "mocked Client->get_limit_for_payout returning 30.00"; 30.00 });
            my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');

            if ($now->is_a_weekend) {
                $mock_validation->mock(_is_valid_to_buy => sub { note "mocked Transaction::Validation->_is_valid_to_buy returning nothing"; () });
            }

            $txn->buy;
        };

        is $error, undef, 'no error';
        $mock_contract->unmock_all;
    }
    'survived';
    restore_time();
};

subtest 'max_payout_per_symbol_and_bet_type validation', sub {
    plan tests => 11;
    lives_ok {
        my $cl = create_client;

        top_up $cl, 'USD', 100;

        isnt + (my $acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';

        my $bal;
        is + ($bal = $acc_usd->balance + 0), 100, 'USD balance is 100 got: ' . $bal;

        my $contract = produce_contract({
            underlying   => $underlying,
            bet_type     => 'CALL',
            currency     => 'USD',
            payout       => 10.00,
            duration     => '15m',
            current_tick => $tick,
            barrier      => 'S0P',
        });
        my $now = Date::Utility->new();
        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 5.20,
            payout        => $contract->payout,
            amount_type   => 'payout',
            purchase_date => $now,
        });

        my $error = do {
            # need to do this because these limits are not by landing company anymore
            my $mock_client = Test::MockModule->new('Client::Account');
            $mock_client->mock(get_limit_for_payout => sub { note "mocked Client->get_limit_for_payout returning 1000.00"; 1000.00 });
            note "change quants->{bet_limits}->{open_positions_payout_per_symbol_and_bet_type_limit->{USD}} to 29.99";
            local BOM::Platform::Config::quants->{bet_limits}->{open_positions_payout_per_symbol_and_bet_type_limit}->{USD} = 29.99;

            is +BOM::Transaction->new({
                    client        => $cl,
                    contract      => $contract,
                    price         => 5.20,
                    payout        => $contract->payout,
                    amount_type   => 'payout',
                    purchase_date => $now,
                })->buy, undef, '1st bet bought';

            is +BOM::Transaction->new({
                    client        => $cl,
                    contract      => $contract,
                    price         => 5.20,
                    payout        => $contract->payout,
                    amount_type   => 'payout',
                    purchase_date => $now,
                })->buy, undef, '2nd bet bought';

            $txn->buy;
        };
        SKIP: {
            skip 'no error', 4
                if not defined $error
                or ref $error ne 'Error::Base';

            is $error->get_type, 'PotentialPayoutLimitForSameContractExceeded', 'error is PotentialPayoutLimitForSameContractExceeded';

            is $txn->contract_id,    undef, 'txn->contract_id';
            is $txn->transaction_id, undef, 'txn->transaction_id';
            is $txn->balance_after,  undef, 'txn->balance_after';
        }

        # retry with a slightly higher limit should succeed
        $error = do {
            note "change quants->{bet_limits}->{open_positions_payout_per_symbol_and_bet_type_limit}->{USD} to 30";
            local BOM::Platform::Config::quants->{bet_limits}->{open_positions_payout_per_symbol_and_bet_type_limit}->{USD} = 30;

            my $contract_r100 = produce_contract({
                underlying   => $underlying_r100,
                bet_type     => 'CALL',
                currency     => 'USD',
                payout       => 10.00,
                duration     => '15m',
                current_tick => $tick_r100,
                barrier      => 'S0P',
            });

            is +BOM::Transaction->new({
                    client        => $cl,
                    contract      => $contract_r100,
                    price         => 5.20,
                    payout        => $contract_r100->payout,
                    amount_type   => 'payout',
                    purchase_date => Date::Utility->new(),
                })->buy, undef, 'R_100 contract bought -- should not interfere R_50 trading';

            $txn->buy;
        };

        is $error, undef, 'no error';
    }
    'survived';
};

subtest 'max_turnover validation', sub {
    plan tests => 19;
    lives_ok {
        my $cl = create_client;

        top_up $cl, 'USD', 100;

        isnt + (my $acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';

        my $bal;
        is + ($bal = $acc_usd->balance + 0), 100, 'USD balance is 100 got: ' . $bal;

        my $contract_up = produce_contract({
            underlying   => $underlying,
            bet_type     => 'CALL',
            currency     => 'USD',
            payout       => 10.00,
            duration     => '15m',
            current_tick => $tick,
            barrier      => 'S0P',
        });

        my $contract_down = produce_contract({
            underlying   => $underlying_r100,
            bet_type     => 'PUT',
            currency     => 'USD',
            payout       => 10.00,
            duration     => '15m',
            current_tick => $tick,
            barrier      => 'S0P',
        });

        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract_up,
            price         => 5.20,
            payout        => $contract_up->payout,
            amount_type   => 'payout',
            purchase_date => Date::Utility->new(),
        });

        my $error = do {
            my $mock_client = Test::MockModule->new('Client::Account');
            $mock_client->mock(get_limit_for_daily_turnover =>
                    sub { note "mocked Client->get_limit_for_daily_turnover returning " . (3 * 5.20 - .01); 3 * 5.20 - .01 });
            $mock_client->mock(client_fully_authenticated => sub { note "mocked Client->client_fully_authenticated returning false"; undef });

            is +BOM::Transaction->new({
                    client        => $cl,
                    contract      => $contract_up,
                    price         => 5.20,
                    payout        => $contract_up->payout,
                    amount_type   => 'payout',
                    purchase_date => Date::Utility->new(),
                })->buy, undef, 'CALL bet bought';

            is +BOM::Transaction->new({
                    client        => $cl,
                    contract      => $contract_down,
                    price         => 5.20,
                    payout        => $contract_down->payout,
                    amount_type   => 'payout',
                    purchase_date => Date::Utility->new(),
                })->buy, undef, 'PUT bet bought';

            $txn->buy;
        };
        SKIP: {
            skip 'no error', 6
                if not defined $error
                or ref $error ne 'Error::Base';

            is $error->get_type, 'DailyTurnoverLimitExceeded', 'error is DailyTurnoverLimitExceeded';

            like $error->{-message_to_client}, qr/daily turnover limit of USD15\.59/, 'message_to_client contains limit';
            like $error->{-message_to_client}, qr/Please contact our customer support team if you wish to increase your daily turnover limit/,
                'message_to_client contains authentication notice';

            is $txn->contract_id,    undef, 'txn->contract_id';
            is $txn->transaction_id, undef, 'txn->transaction_id';
            is $txn->balance_after,  undef, 'txn->balance_after';
        }

        $error = do {
            my $mock_client = Test::MockModule->new('Client::Account');
            $mock_client->mock(get_limit_for_daily_turnover =>
                    sub { note "mocked Client->get_limit_for_daily_turnover returning " . (3 * 5.20 - .01); 3 * 5.20 - .01 });
            $mock_client->mock(client_fully_authenticated => sub { note "mocked Client->client_fully_authenticated returning true"; 1 });

            $txn->buy;
        };
        SKIP: {
            skip 'no error', 6
                if not defined $error
                or ref $error ne 'Error::Base';

            is $error->get_type, 'DailyTurnoverLimitExceeded', 'error is DailyTurnoverLimitExceeded';

            like $error->{-message_to_client}, qr/daily turnover limit of USD15\.59/, 'message_to_client contains limit';
            unlike $error->{-message_to_client}, qr/Please contact our customer support team if you wish to increase your daily turnover limit/,
                'message_to_client does not contain authentication notice if the client is already authenticated';

            is $txn->contract_id,    undef, 'txn->contract_id';
            is $txn->transaction_id, undef, 'txn->transaction_id';
            is $txn->balance_after,  undef, 'txn->balance_after';
        }

        # retry with a slightly higher limit should succeed
        $error = do {
            # buy a bet yesterday. It should not interfere.
            lives_ok {
                BOM::Database::Helper::FinancialMarketBet->new({
                        bet_data => +{
                            underlying_symbol => 'R_50',
                            payout_price      => 100,
                            buy_price         => 20,
                            remark            => 'Test Remark',
                            purchase_time     => Date::Utility::today->minus_time_interval("1s")->db_timestamp,
                            start_time        => Date::Utility::today->minus_time_interval("0s")->db_timestamp,
                            expiry_time       => Date::Utility::today->plus_time_interval("15s")->db_timestamp,
                            settlement_time   => Date::Utility::today->plus_time_interval("15s")->db_timestamp,
                            is_expired        => 0,
                            is_sold           => 0,
                            bet_class         => 'higher_lower_bet',
                            bet_type          => 'CALL',
                            short_code        => 'test',
                            relative_barrier  => 'S0P',
                        },
                        account_data => {
                            client_loginid => $acc_usd->client_loginid,
                            currency_code  => $acc_usd->currency_code
                        },
                        db => db,
                    })->buy_bet;
            }
            'bought a bet yesterday 23:59:59';

            my $mock_client = Test::MockModule->new('Client::Account');
            $mock_client->mock(
                get_limit_for_daily_turnover => sub { note "mocked Client->get_limit_for_daily_turnover returning " . (3 * 5.20); 3 * 5.20 });

            $txn->buy;
        };

        is $error, undef, 'no error';
    }
    'survived';
};

subtest 'max_7day_turnover validation', sub {
    plan tests => 11;
    lives_ok {
        my $cl = create_client;

        top_up $cl, 'USD', 100;

        isnt + (my $acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';

        my $bal;
        is + ($bal = $acc_usd->balance + 0), 100, 'USD balance is 100 got: ' . $bal;

        my $contract_up = produce_contract({
            underlying   => $underlying,
            bet_type     => 'CALL',
            currency     => 'USD',
            payout       => 10.00,
            duration     => '15m',
            current_tick => $tick,
            barrier      => 'S0P',
        });

        my $contract_down = produce_contract({
            underlying   => $underlying_r100,
            bet_type     => 'PUT',
            currency     => 'USD',
            payout       => 10.00,
            duration     => '15m',
            current_tick => $tick,
            barrier      => 'S0P',
        });

        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract_up,
            price         => 5.20,
            payout        => $contract_up->payout,
            amount_type   => 'payout',
            purchase_date => Date::Utility->new(),
        });

        my $error = do {
            my $mock_client = Test::MockModule->new('Client::Account');
            $mock_client->mock(
                get_limit_for_7day_turnover => sub { note "mocked Client->get_limit_for_7day_turnover returning " . (3 * 5.20 - .01); 3 * 5.20 - .01 }
            );

            is +BOM::Transaction->new({
                    client        => $cl,
                    contract      => $contract_up,
                    price         => 5.20,
                    payout        => $contract_up->payout,
                    amount_type   => 'payout',
                    purchase_date => Date::Utility->new(),
                })->buy, undef, 'CALL bet bought';

            is +BOM::Transaction->new({
                    client        => $cl,
                    contract      => $contract_down,
                    price         => 5.20,
                    payout        => $contract_down->payout,
                    amount_type   => 'payout',
                    purchase_date => Date::Utility->new(),
                })->buy, undef, 'PUT bet bought';

            $txn->buy;
        };
        SKIP: {
            skip 'no error', 6
                if not defined $error
                or ref $error ne 'Error::Base';

            is $error->get_type, '7DayTurnoverLimitExceeded', 'error is 7DayTurnoverLimitExceeded';

            like $error->{-message_to_client}, qr/7-day turnover limit of USD15\.59/, 'message_to_client contains limit';

            is $txn->contract_id,    undef, 'txn->contract_id';
            is $txn->transaction_id, undef, 'txn->transaction_id';
            is $txn->balance_after,  undef, 'txn->balance_after';
        }

        # retry with a slightly higher limit should succeed
        $error = do {
            my $mock_client = Test::MockModule->new('Client::Account');
            $mock_client->mock(
                get_limit_for_7day_turnover => sub { note "mocked Client->get_limit_for_7day_turnover returning " . (3 * 5.20); 3 * 5.20 });

            $txn->buy;
        };

        is $error, undef, 'no error';
    }
    'survived';
};

subtest 'max_30day_turnover validation', sub {
    plan tests => 11;
    lives_ok {
        my $cl = create_client;

        top_up $cl, 'USD', 100;

        isnt + (my $acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';

        my $bal;
        is + ($bal = $acc_usd->balance + 0), 100, 'USD balance is 100 got: ' . $bal;

        my $contract_up = produce_contract({
            underlying   => $underlying,
            bet_type     => 'CALL',
            currency     => 'USD',
            payout       => 10.00,
            duration     => '15m',
            current_tick => $tick,
            barrier      => 'S0P',
        });

        my $contract_down = produce_contract({
            underlying   => $underlying_r100,
            bet_type     => 'PUT',
            currency     => 'USD',
            payout       => 10.00,
            duration     => '15m',
            current_tick => $tick,
            barrier      => 'S0P',
        });

        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract_up,
            price         => 5.20,
            payout        => $contract_up->payout,
            amount_type   => 'payout',
            purchase_date => Date::Utility->new(),
        });

        my $error = do {
            my $mock_client = Test::MockModule->new('Client::Account');
            $mock_client->mock(get_limit_for_30day_turnover =>
                    sub { note "mocked Client->get_limit_for_30day_turnover returning " . (3 * 5.20 - .01); 3 * 5.20 - .01 });

            is +BOM::Transaction->new({
                    client        => $cl,
                    contract      => $contract_up,
                    price         => 5.20,
                    payout        => $contract_up->payout,
                    amount_type   => 'payout',
                    purchase_date => Date::Utility->new(),
                })->buy, undef, 'CALL bet bought';

            is +BOM::Transaction->new({
                    client        => $cl,
                    contract      => $contract_down,
                    price         => 5.20,
                    payout        => $contract_down->payout,
                    amount_type   => 'payout',
                    purchase_date => Date::Utility->new(),
                })->buy, undef, 'PUT bet bought';

            $txn->buy;
        };
        SKIP: {
            skip 'no error', 5
                if not defined $error
                or ref $error ne 'Error::Base';

            is $error->get_type, '30DayTurnoverLimitExceeded', 'error is 30DayTurnoverLimitExceeded';

            like $error->{-message_to_client}, qr/30-day turnover limit of USD15\.59/, 'message_to_client contains limit';

            is $txn->contract_id,    undef, 'txn->contract_id';
            is $txn->transaction_id, undef, 'txn->transaction_id';
            is $txn->balance_after,  undef, 'txn->balance_after';
        }

        # retry with a slightly higher limit should succeed
        $error = do {
            my $mock_client = Test::MockModule->new('Client::Account');
            $mock_client->mock(
                get_limit_for_30day_turnover => sub { note "mocked Client->get_limit_for_30day_turnover returning " . (3 * 5.20); 3 * 5.20 });

            $txn->buy;
        };

        is $error, undef, 'no error';
    }
    'survived';
};

subtest 'max_losses validation', sub {
    plan tests => 13;
    lives_ok {
        my $cl = create_client;

        top_up $cl, 'USD', 100;

        isnt + (my $acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';

        my $bal;
        is + ($bal = $acc_usd->balance + 0), 100, 'USD balance is 100 got: ' . $bal;

        my $contract_up = produce_contract({
            underlying   => $underlying,
            bet_type     => 'CALL',
            currency     => 'USD',
            payout       => 10.00,
            duration     => '15m',
            current_tick => $tick,
            barrier      => 'S0P',
            date_pricing => Date::Utility->new(time + 10),
        });

        my $contract_down = produce_contract({
            underlying   => $underlying_r100,
            bet_type     => 'PUT',
            currency     => 'USD',
            payout       => 10.00,
            duration     => '15m',
            current_tick => $tick,
            barrier      => 'S0P',
            date_pricing => Date::Utility->new(time + 10),
        });

        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract_up,
            price         => 5.20,
            payout        => $contract_up->payout,
            amount_type   => 'payout',
            purchase_date => $contract_up->date_start,
        });

        my $error = do {
            my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
            $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

            my $mock_transaction = Test::MockModule->new('BOM::Transaction');
            my $mock_validation  = Test::MockModule->new('BOM::Transaction::Validation');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_validation->mock(_validate_trade_pricing_adjustment =>
                    sub { note "mocked Transaction::Validation->_validate_trade_pricing_adjustment returning nothing"; () });
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning '[]'"; [] });
            my $mock_client = Test::MockModule->new('Client::Account');
            $mock_client->mock(
                get_limit_for_daily_losses => sub { note "mocked Client->get_limit_for_daily_losses returning " . (3 * 5.20 - .01); 3 * 5.20 - .01 });

            my $t = BOM::Transaction->new({
                client        => $cl,
                contract      => $contract_up,
                price         => 5.20,
                payout        => $contract_up->payout,
                amount_type   => 'payout',
                purchase_date => $contract_up->date_start,
            });
            is $t->buy, undef, 'CALL bet bought';
            $t = BOM::Transaction->new({
                purchase_date => $contract_up->date_start,
                client        => $cl,
                contract      => $contract_up,
                contract_id   => $t->contract_id,
                price         => 0,
            });
            is $t->sell(skip_validation => 1), undef, 'CALL bet sold';

            $t = BOM::Transaction->new({
                client        => $cl,
                contract      => $contract_down,
                price         => 5.20,
                payout        => $contract_down->payout,
                amount_type   => 'payout',
                purchase_date => $contract_down->date_start,
            });
            is $t->buy, undef, 'PUT bet bought';
            $t = BOM::Transaction->new({
                purchase_date => $contract_down->date_start,
                client        => $cl,
                contract      => $contract_down,
                contract_id   => $t->contract_id,
                price         => 0,
            });
            is $t->sell(skip_validation => 1), undef, 'CALL bet sold';

            $txn->buy;
        };
        SKIP: {
            skip 'no error', 5
                if not defined $error
                or ref $error ne 'Error::Base';

            is $error->get_type, 'DailyLossLimitExceeded', 'error is DailyLossLimitExceeded';

            like $error->{-message_to_client}, qr/daily limit on losses of USD15\.59/, 'message_to_client contains limit';

            is $txn->contract_id,    undef, 'txn->contract_id';
            is $txn->transaction_id, undef, 'txn->transaction_id';
            is $txn->balance_after,  undef, 'txn->balance_after';
        }

        # retry with a slightly higher limit should succeed
        $error = do {
            my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
            $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

            my $mock_transaction = Test::MockModule->new('BOM::Transaction');
            my $mock_validation  = Test::MockModule->new('BOM::Transaction::Validation');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_validation->mock(_validate_trade_pricing_adjustment =>
                    sub { note "mocked Transaction::Validation->_validate_trade_pricing_adjustment returning nothing"; () });
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning '[]'"; [] });
            my $mock_client = Test::MockModule->new('Client::Account');
            $mock_client->mock(
                get_limit_for_daily_losses => sub { note "mocked Client->get_limit_for_daily_losses returning " . (3 * 5.20); 3 * 5.20 });

            $txn->buy;
        };

        is $error, undef, 'no error';
    }
    'survived';
};

subtest 'max_7day_losses validation', sub {
    plan tests => 13;
    lives_ok {
        my $cl = create_client;

        top_up $cl, 'USD', 100;

        isnt + (my $acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';

        my $bal;
        is + ($bal = $acc_usd->balance + 0), 100, 'USD balance is 100 got: ' . $bal;

        my $contract_up = produce_contract({
            underlying   => $underlying,
            bet_type     => 'CALL',
            currency     => 'USD',
            payout       => 10.00,
            duration     => '15m',
            current_tick => $tick,
            barrier      => 'S0P',
            date_pricing => Date::Utility->new(time + 10),
        });

        my $contract_down = produce_contract({
            underlying   => $underlying_r100,
            bet_type     => 'PUT',
            currency     => 'USD',
            payout       => 10.00,
            duration     => '15m',
            current_tick => $tick,
            barrier      => 'S0P',
            date_pricing => Date::Utility->new(time + 10),
        });

        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract_up,
            price         => 5.20,
            payout        => $contract_up->payout,
            amount_type   => 'payout',
            purchase_date => $contract_up->date_start,
        });

        my $error = do {
            my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
            $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

            my $mock_transaction = Test::MockModule->new('BOM::Transaction');
            my $mock_validation  = Test::MockModule->new('BOM::Transaction::Validation');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_validation->mock(_validate_trade_pricing_adjustment =>
                    sub { note "mocked Transaction::Validation->_validate_trade_pricing_adjustment returning nothing"; () });
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning '[]'"; [] });
            my $mock_client = Test::MockModule->new('Client::Account');
            $mock_client->mock(
                get_limit_for_7day_losses => sub { note "mocked Client->get_limit_for_7day_losses returning " . (3 * 5.20 - .01); 3 * 5.20 - .01 });

            my $t = BOM::Transaction->new({
                client        => $cl,
                contract      => $contract_up,
                price         => 5.20,
                payout        => $contract_up->payout,
                amount_type   => 'payout',
                purchase_date => $contract_up->date_start,
            });
            is $t->buy, undef, 'CALL bet bought';
            $t = BOM::Transaction->new({
                purchase_date => $contract_up->date_start,
                client        => $cl,
                contract      => $contract_up,
                contract_id   => $t->contract_id,
                price         => 0,
            });
            is $t->sell(skip_validation => 1), undef, 'CALL bet sold';

            $t = BOM::Transaction->new({
                client        => $cl,
                contract      => $contract_down,
                price         => 5.20,
                payout        => $contract_down->payout,
                amount_type   => 'payout',
                purchase_date => $contract_down->date_start,
            });
            is $t->buy, undef, 'PUT bet bought';
            $t = BOM::Transaction->new({
                purchase_date => $contract_down->date_start,
                client        => $cl,
                contract      => $contract_down,
                contract_id   => $t->contract_id,
                price         => 0,
            });
            is $t->sell(skip_validation => 1), undef, 'CALL bet sold';

            $txn->buy;
        };
        SKIP: {
            skip 'no error', 5
                if not defined $error
                or ref $error ne 'Error::Base';

            is $error->get_type, '7DayLossLimitExceeded', 'error is 7DayLossLimitExceeded';

            like $error->{-message_to_client}, qr/7-day limit on losses of USD15\.59/, 'message_to_client contains limit';

            is $txn->contract_id,    undef, 'txn->contract_id';
            is $txn->transaction_id, undef, 'txn->transaction_id';
            is $txn->balance_after,  undef, 'txn->balance_after';
        }

        # retry with a slightly higher limit should succeed
        $error = do {
            my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
            $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

            my $mock_transaction = Test::MockModule->new('BOM::Transaction');
            my $mock_validation  = Test::MockModule->new('BOM::Transaction::Validation');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_validation->mock(_validate_trade_pricing_adjustment =>
                    sub { note "mocked Transaction::Validation->_validate_trade_pricing_adjustment returning nothing"; () });
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning '[]'"; [] });
            my $mock_client = Test::MockModule->new('Client::Account');
            $mock_client->mock(get_limit_for_7day_losses => sub { note "mocked Client->get_limit_for_7day_losses returning " . (3 * 5.20); 3 * 5.20 }
            );

            $txn->buy;
        };

        is $error, undef, 'no error';
    }
    'survived';
};

subtest 'max_30day_losses validation', sub {
    plan tests => 13;
    lives_ok {
        my $cl = create_client;

        top_up $cl, 'USD', 100;

        isnt + (my $acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';

        my $bal;
        is + ($bal = $acc_usd->balance + 0), 100, 'USD balance is 100 got: ' . $bal;

        my $now         = Date::Utility->new();
        my $contract_up = produce_contract({
            underlying   => $underlying,
            bet_type     => 'CALL',
            currency     => 'USD',
            payout       => 10.00,
            duration     => '15m',
            current_tick => $tick,
            barrier      => 'S0P',
            date_pricing => Date::Utility->new(time + 10),
        });

        my $contract_down = produce_contract({
            underlying   => $underlying_r100,
            bet_type     => 'PUT',
            currency     => 'USD',
            payout       => 10.00,
            duration     => '15m',
            current_tick => $tick,
            barrier      => 'S0P',
            date_pricing => Date::Utility->new(time + 10),
        });

        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract_up,
            price         => 5.20,
            payout        => $contract_up->payout,
            amount_type   => 'payout',
            purchase_date => $contract_up->date_start,
        });

        my $error = do {
            my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
            $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

            my $mock_transaction = Test::MockModule->new('BOM::Transaction');
            my $mock_validation  = Test::MockModule->new('BOM::Transaction::Validation');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_validation->mock(_validate_trade_pricing_adjustment =>
                    sub { note "mocked Transaction::Validation->_validate_trade_pricing_adjustment returning nothing"; () });
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning '[]'"; [] });
            my $mock_client = Test::MockModule->new('Client::Account');
            $mock_client->mock(
                get_limit_for_30day_losses => sub { note "mocked Client->get_limit_for_30day_losses returning " . (3 * 5.20 - .01); 3 * 5.20 - .01 });

            my $t = BOM::Transaction->new({
                client        => $cl,
                contract      => $contract_up,
                price         => 5.20,
                payout        => $contract_up->payout,
                amount_type   => 'payout',
                purchase_date => $contract_up->date_start,
            });
            is $t->buy, undef, 'CALL bet bought';
            $t = BOM::Transaction->new({
                purchase_date => $contract_up->date_start,
                client        => $cl,
                contract      => $contract_up,
                contract_id   => $t->contract_id,
                price         => 0,
            });
            is $t->sell(skip_validation => 1), undef, 'CALL bet sold';

            $t = BOM::Transaction->new({
                client        => $cl,
                contract      => $contract_down,
                price         => 5.20,
                payout        => $contract_down->payout,
                amount_type   => 'payout',
                purchase_date => $contract_down->date_start,
            });
            is $t->buy, undef, 'PUT bet bought';
            $t = BOM::Transaction->new({
                purchase_date => $contract_down->date_start,
                client        => $cl,
                contract      => $contract_down,
                contract_id   => $t->contract_id,
                price         => 0,
            });
            is $t->sell(skip_validation => 1), undef, 'CALL bet sold';

            $txn->buy;
        };
        SKIP: {
            skip 'no error', 5
                if not defined $error
                or ref $error ne 'Error::Base';

            is $error->get_type, '30DayLossLimitExceeded', 'error is 30DayLossLimitExceeded';

            like $error->{-message_to_client}, qr/30-day limit on losses of USD15\.59/, 'message_to_client contains limit';

            is $txn->contract_id,    undef, 'txn->contract_id';
            is $txn->transaction_id, undef, 'txn->transaction_id';
            is $txn->balance_after,  undef, 'txn->balance_after';
        }

        # retry with a slightly higher limit should succeed
        $error = do {
            my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
            $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

            my $mock_transaction = Test::MockModule->new('BOM::Transaction');
            my $mock_validation  = Test::MockModule->new('BOM::Transaction::Validation');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_validation->mock(_validate_trade_pricing_adjustment =>
                    sub { note "mocked Transaction::Validation->_validate_trade_pricing_adjustment returning nothing"; () });
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning '[]'"; [] });
            my $mock_client = Test::MockModule->new('Client::Account');
            $mock_client->mock(
                get_limit_for_30day_losses => sub { note "mocked Client->get_limit_for_30day_losses returning " . (3 * 5.20); 3 * 5.20 });

            $txn->buy;
        };

        is $error, undef, 'no error';
    }
    'survived';
};

subtest 'sell_expired_contracts', sub {
    plan tests => 37;
    lives_ok {
        my $cl = create_client;

        top_up $cl, 'USD', 1000;

        isnt + (my $acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';

        my $bal;
        is + ($bal = $acc_usd->balance + 0), 1000, 'USD balance is 1000 got: ' . $bal;

        my $contract_expired = produce_contract({
            underlying   => $underlying,
            bet_type     => 'CALL',
            currency     => 'USD',
            stake        => 100,
            date_start   => $now->epoch - 100,
            date_expiry  => $now->epoch - 50,
            current_tick => $tick,
            entry_tick   => $old_tick1,
            exit_tick    => $old_tick2,
            barrier      => 'S0P',
        });

        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract_expired,
            price         => 100,
            payout        => $contract_expired->payout,
            amount_type   => 'stake',
            purchase_date => $now->epoch - 101,
        });

        my (@expired_txnids, @expired_fmbids, @unexpired_fmbids);
        # buy 5 expired contracts
        for (1 .. 5) {
            my $error = $txn->buy(skip_validation => 1);
            is $error, undef, 'no error: bought 1 expired contract for 100';
            push @expired_txnids, $txn->transaction_id;
            push @expired_fmbids, $txn->contract_id;
        }

        # now buy a couple of not-yet-expired contracts
        my $contract = produce_contract({
            underlying   => $underlying,
            bet_type     => 'CALL',
            currency     => 'USD',
            stake        => 100,
            date_start   => $now->epoch - 100,
            date_expiry  => $now->epoch + 2,
            current_tick => $tick,
            entry_tick   => $old_tick1,
            barrier      => 'S0P',
        });

        $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 100,
            payout        => $contract->payout,
            amount_type   => 'stake',
            purchase_date => $now->epoch - 101,
        });

        my @txnids;
        # buy 5 unexpired contracts
        for (1 .. 5) {
            my $error = $txn->buy(skip_validation => 1);
            is $error, undef, 'no error: bought 1 contract for 100';
            push @txnids,           $txn->transaction_id;
            push @unexpired_fmbids, $txn->contract_id;
        }

        $acc_usd->load;
        is $acc_usd->balance + 0, 0, 'USD balance is down to 0';

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
            total_credited      => 200,
            failures            => [],
            },
            'sold the two requested contracts';

        $res = BOM::Transaction::sell_expired_contracts + {
            client => $cl,
            source => 29
        };

        @unexpired_fmbids = sort { $a <=> $b } @unexpired_fmbids;
        $res->{failures} = [sort { $a->{fmb_id} <=> $b->{fmb_id} } @{$res->{failures}}];
        is_deeply $res, +{
            number_of_sold_bets => 3,
            skip_contract       => 5,     # this means the contract was looked at but skipped due to invalid to sell
            total_credited      => 300,
            failures => [map { {reason => 'not expired', fmb_id => $_} } @unexpired_fmbids],
            },
            'sold 3 out of 8 remaining bets';

        $acc_usd->load;
        is $acc_usd->balance + 0, 500, 'USD balance 500';

        for (@expired_txnids) {
            my ($trx, $fmb, $chld, $qv1, $qv2, $trx2) = get_transaction_from_db higher_lower_bet => $_;
            is $fmb->{is_sold},        1,          'expired contract is sold';
            is $trx2->{source},        29,         'source';
            is $trx2->{staff_loginid}, 'AUTOSELL', 'staff_loginid';
        }

        for (@txnids) {
            my ($trx, $fmb) = get_transaction_from_db higher_lower_bet => $_;
            is !$fmb->{is_sold}, !0, 'not-yet-expired contract is not sold';
        }
    }
    'survived';
};

subtest 'transaction slippage' => sub {
    my $cl = create_client;
    top_up $cl, 'USD', 1000;
    isnt + (my $acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';
    my $bal;
    is + ($bal = $acc_usd->balance + 0), 1000, 'USD balance is 1000 got: ' . $bal;

    my $fmb_id;
    my $mock_pc       = Test::MockModule->new('Price::Calculator');
    my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
    $mock_contract->mock('ask_price', sub { 10 });
    $mock_contract->mock(
        'commission_markup',
        sub {
            return Math::Util::CalculatedValue::Validatable->new({
                name        => 'commission_markup',
                description => 'fake commission markup',
                set_by      => 'BOM::Product::Contract',
                base_amount => 0.01,
            });
        });
    $mock_contract->mock(
        'risk_markup',
        sub {
            return Math::Util::CalculatedValue::Validatable->new({
                name        => 'risk_markup',
                description => 'fake risk markup',
                set_by      => 'BOM::Product::Contract',
                base_amount => 0,
            });
        });
    subtest 'buy slippage' => sub {
        my $ask_cv = Math::Util::CalculatedValue::Validatable->new({
            name        => 'ask_probability',
            description => 'fake ask prov',
            set_by      => 'BOM::Product::Contract',
            base_amount => 0.1
        });
        $mock_pc->mock('ask_probability', sub { $ask_cv });

        # 50% of commission
        my $allowed_move = 0.01 * 0.50;

        my $contract = produce_contract({
            underlying   => 'R_100',
            bet_type     => 'CALL',
            currency     => 'USD',
            payout       => 100,
            date_start   => $now,
            date_pricing => $now,
            date_expiry  => $now->plus_time_interval('15m'),
            current_tick => $tick,
            barrier      => 'S0P',
        });

        # we just want to _validate_trade_pricing_adjustment
        my $mocked = Test::MockModule->new('BOM::Transaction::Validation');
        $mocked->unmock_all();
        $mocked->mock($_ => sub { '' })
            for (
            qw/
            _validate_buy_transaction_rate
            _validate_iom_withdrawal_limit
            _validate_available_currency
            _validate_currency
            _validate_jurisdictional_restrictions
            _validate_client_status
            _validate_client_self_exclusion
            _is_valid_to_buy
            _validate_date_pricing
            _validate_payout_limit
            validate_tnc
            _validate_stake_limit/
            );
        # no limits
        my $mocked_tr = Test::MockModule->new('BOM::Transaction');
        $mocked_tr->mock('limits', sub { {} });

        my $price = $contract->ask_price - ($allowed_move * $contract->payout / 2);
        my $transaction = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            action        => 'BUY',
            amount_type   => 'payout',
            price         => $price,
            purchase_date => $now,
        });

        ok !$transaction->buy, 'buy without error.';
        my ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db higher_lower_bet => $transaction->transaction_id;

        is $fmb->{buy_price}, $price, 'buy at requested price';
        is $qv1->{price_slippage}, -0.25, 'slippage stored';
        is $qv1->{requested_price}, $price, 'correct requested price stored';
        is $qv1->{recomputed_price}, $contract->ask_price, 'correct recomputed price stored';
        $fmb_id = $fmb->{id};
    };

    subtest 'sell slippage' => sub {
        my $bid_cv = Math::Util::CalculatedValue::Validatable->new({
            name        => 'bid_probability',
            description => 'fake ask prov',
            set_by      => 'BOM::Product::Contract',
            base_amount => 0.1
        });
        $mock_pc->mock('bid_probability', sub { $bid_cv });

        my $contract = produce_contract({
            underlying   => 'R_100',
            bet_type     => 'CALL',
            currency     => 'USD',
            payout       => 100,
            date_start   => $now->plus_time_interval('5m'),
            date_pricing => $now->plus_time_interval('5m'),
            date_expiry  => $now->plus_time_interval('15m'),
            current_tick => $tick,
            barrier      => 'S0P',
        });

        my $allowed_move = 0.01 * 0.50;

        my $price = $contract->bid_price + ($allowed_move * $contract->payout - 0.1);

        # we just want to _validate_trade_pricing_adjustment
        my $mocked = Test::MockModule->new('BOM::Transaction::Validation');
        $mocked->mock($_ => sub { '' })
            for (
            qw/
            _validate_sell_transaction_rate
            _validate_iom_withdrawal_limit
            _is_valid_to_sell
            _validate_available_currency
            _validate_currency
            _validate_date_pricing/
            );

        # no limits
        $mocked->mock('limits', sub { {} });

        my $transaction = BOM::Transaction->new({
            purchase_date => $contract->date_start,
            client        => $cl,
            contract      => $contract,
            contract_id   => $fmb_id,
            price         => $price,
            amount_type   => 'payout',
            source        => 23,
        });

        ok !$transaction->sell, 'no error when sell';
        my ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db higher_lower_bet => $transaction->transaction_id;
        is $fmb->{sell_price}, sprintf('%.2f', $price), 'sell at requested price';
        is $qv1->{price_slippage}, -0.4, 'slippage stored';
        is $qv1->{requested_price}, $price, 'correct requested price stored';
        is $qv1->{recomputed_price}, $contract->bid_price, 'correct recomputed price stored';
    };
};

# see further transaction2.t: special turnover limits
#             transaction3.t: intraday fx action
$mocked_underlying->unmock_all;

done_testing;
