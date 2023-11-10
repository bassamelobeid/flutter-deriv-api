#!/etc/rmg/bin/perl

use strict;
use warnings;
use Test::MockTime qw/:all/;
use Test::MockModule;
use Test::More;
use Test::Exception;
use Test::Warnings;

use BOM::Test::Data::Utility::UnitTestDatabase   qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase   qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis      qw(initialize_realtime_ticks_db);
use BOM::Test::Helper::Client                    qw(top_up create_client);

use Guard;
use Crypt::NamedKeys;
use Date::Utility;
use List::Util qw(any);
use BOM::User::Client;
use BOM::User::Password;
use BOM::User::Utility;
use BOM::User;
use BOM::Config::Runtime;

use BOM::Transaction;
use BOM::Transaction::ContractUpdate;
use BOM::Transaction::Validation;
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Platform::Client::IDAuthentication;

use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;

my $password = 'jskjd8292922';
my $email    = 'test' . rand(999) . '@binary.com';
my $hash_pwd = BOM::User::Password::hashpw($password);

my $user = BOM::User->create(
    email    => $email,
    password => $hash_pwd
);

Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';

my $mocked_contract = Test::MockModule->new('BOM::Product::Contract::Accu');
$mocked_contract->mock('maximum_feed_delay_seconds', sub { return 300 });

my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');

$mock_validation->mock(validate_tnc => sub { note "mocked Transaction::Validation->validate_tnc returning nothing"; undef });

my $underlying = create_underlying('R_100');
my $now        = Date::Utility->new;

BOM::Test::Data::Utility::UnitTestMarketData::create_doc('currency', {symbol => 'USD'});
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'index',
    {
        symbol => 'R_100',
        date   => $now,
    });

my $current_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => $underlying->symbol,
    epoch      => $now->epoch,
    quote      => 100,
});

#creat some ticks to be able to sell accumulator contracts
BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(
    [100,  $now->epoch,     $underlying->symbol],
    [101,  $now->epoch + 1, $underlying->symbol],
    [101,  $now->epoch + 2, $underlying->symbol],
    [101,  $now->epoch + 3, $underlying->symbol],
    [1000, $now->epoch + 4, $underlying->symbol]);

my $mocked_u = Test::MockModule->new('Quant::Framework::Underlying');
$mocked_u->mock('spot_tick', sub { return $current_tick });

initialize_realtime_ticks_db();

sub db {
    return BOM::Database::ClientDB->new({
            broker_code => 'VRTC',
        })->db;
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
    my @res = @$res;
    @txn{@txn_col} = splice @res, 0, 0 + @txn_col;

    my %fmb;
    @fmb{@fmb_col} = splice @res, 0, 0 + @fmb_col;

    my %chld;
    @chld{@chld_col} = splice @res, 0, 0 + @chld_col;

    my %qv1;
    @qv1{@qv_col} = splice @res, 0, 0 + @qv_col;

    my %qv2;
    @qv2{@qv_col} = splice @res, 0, 0 + @qv_col;

    my %t2;
    @t2{@txn_col} = splice @res, 0, 0 + @txn_col;

    return \%txn, \%fmb, \%chld, \%qv1, \%qv2, \%t2;
}

my $cl;
my $acc_usd;

####################################################################
# real tests begin here
####################################################################
my $args = {
    bet_type          => 'ACCU',
    underlying        => $underlying->symbol,
    date_start        => $now,
    date_pricing      => $now,
    amount_type       => 'stake',
    amount            => 100,
    growth_rate       => 0.01,
    currency          => 'USD',
    growth_frequency  => 1,
    growth_start_step => 1,
    tick_size_barrier => 0.02,
};

lives_ok {
    $cl = create_client('VRTC');

    #make sure client can trade
    ok(!BOM::Transaction::Validation->new({clients => [{client => $cl}]})->check_trade_status($cl),      "client can trade: check_trade_status");
    ok(!BOM::Transaction::Validation->new({clients => [{client => $cl}]})->_validate_client_status($cl), "client can trade: _validate_client_status");

    top_up $cl, 'USD', 5000;

    $acc_usd = $cl->account;
    is $acc_usd->currency_code, 'USD', 'got USD account';

    my $bal;
    is + ($bal = $acc_usd->balance + 0), 5000, 'USD balance is 5000 got: ' . $bal;
}
'client created and funded';

my ($trx, $fmb, $chld, $qv1, $qv2);

subtest 'buy ACCU', sub {
    lives_ok {
        my $contract = produce_contract($args);

        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 100,
            amount        => 100,
            amount_type   => 'stake',
            source        => 19,
            purchase_date => $contract->date_start,
        });

        my $error = $txn->buy();
        ok !$error, 'buy without error';
        is $txn->price_slippage, '0', 'no slippage';

        subtest 'transaction report', sub {
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
        ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db accumulator => $txn->transaction_id;

        subtest 'transaction row', sub {
            plan tests => 11;
            cmp_ok $trx->{id}, '>', 0, 'id';
            is $trx->{account_id},              $acc_usd->id,           'account_id';
            is $trx->{action_type},             'buy',                  'action_type';
            is $trx->{amount} + 0,              -100,                   'amount';
            is $trx->{balance_after} + 0,       5000 - 100,             'balance_after';
            is $trx->{financial_market_bet_id}, $fmb->{id},             'financial_market_bet_id';
            is $trx->{payment_id},              undef,                  'payment_id';
            is $trx->{referrer_type},           'financial_market_bet', 'referrer_type';
            is $trx->{staff_loginid},           $cl->loginid,           'staff_loginid';
            is $trx->{source},                  19,                     'source';
            cmp_ok +Date::Utility->new($trx->{transaction_time})->epoch, '<=', time, 'transaction_time';
        };

        subtest 'fmb row', sub {
            plan tests => 18;
            cmp_ok $fmb->{id}, '>', 0, 'id';
            is $fmb->{account_id},    $acc_usd->id,            'account_id';
            is $fmb->{bet_class},     'accumulator',           'bet_class';
            is $fmb->{bet_type},      'ACCU',                  'bet_type';
            is $fmb->{buy_price} + 0, 100,                     'buy_price';
            is $fmb->{expiry_daily},  $contract->expiry_daily, 'expiry_daily';
            is $fmb->{expiry_time},   undef,                   'expiry_time';
            is $fmb->{fixed_expiry},  undef,                   'fixed_expiry';
            is $fmb->{is_expired},    0,                       'is_expired';
            is $fmb->{is_sold},       0,                       'is_sold';
            cmp_ok +Date::Utility->new($fmb->{purchase_time})->epoch, '<=', time, 'purchase_time';
            is $fmb->{sell_price},      undef, 'sell_price';
            is $fmb->{sell_time},       undef, 'sell_time';
            is $fmb->{settlement_time}, undef, 'settlement_time';
            like $fmb->{short_code}, qr/ACCU/, 'short_code';
            cmp_ok +Date::Utility->new($fmb->{start_time})->epoch, '<=', time, 'start_time';
            is $fmb->{tick_count},        undef,   'tick_count';
            is $fmb->{underlying_symbol}, 'R_100', 'underlying_symbol';
        };

        subtest 'chld row', sub {
            is $chld->{financial_market_bet_id},    $fmb->{id}, 'financial_market_bet_id';
            is $chld->{'take_profit_order_amount'}, undef,      'take_profit_order_amount is undef';
            is $chld->{'take_profit_order_date'},   undef,      'take_profit_order_date is undef';
            is $chld->{'ask_spread'},               undef,      'ask_spread is undef';
            is $chld->{'bid_spread'},               undef,      'bid_spread is undef';
            is $chld->{'tick_final_count'},         undef,      'tick_final_count is undef';
        };

    }
    'survived';
};

subtest 'sell a bet', sub {
    lives_ok {
        $args->{date_pricing} = $args->{date_start}->epoch + 2;
        my $contract = produce_contract($args);

        my $txn = BOM::Transaction->new({
            purchase_date => $contract->date_start->epoch,
            client        => $cl,
            contract      => $contract,
            contract_id   => $fmb->{id},
            price         => 100,
            source        => 23,
        });
        my $error = $txn->sell();
        is $error,               undef, 'no error';
        is $txn->price_slippage, '0',   'no slippage';

        ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db accumulator => $txn->transaction_id;

        subtest 'transaction row', sub {
            cmp_ok $trx->{id}, '>', 0, 'id';
            is $trx->{account_id},              $acc_usd->id,             'account_id';
            is $trx->{action_type},             'sell',                   'action_type';
            is $trx->{amount} + 0,              $contract->bid_price + 0, 'amount';
            is $trx->{balance_after} + 0,       5000,                     'balance_after';
            is $trx->{financial_market_bet_id}, $fmb->{id},               'financial_market_bet_id';
            is $trx->{payment_id},              undef,                    'payment_id';
            is $trx->{quantity},                1,                        'quantity';
            is $trx->{referrer_type},           'financial_market_bet',   'referrer_type';
            is $trx->{staff_loginid},           $cl->loginid,             'staff_loginid';
            is $trx->{source},                  23,                       'source';
            cmp_ok +Date::Utility->new($trx->{transaction_time})->epoch, '<=', time, 'transaction_time';
        };

        subtest 'fmb row', sub {
            plan tests => 18;
            cmp_ok $fmb->{id}, '>', 0, 'id';
            is $fmb->{account_id},    $acc_usd->id,            'account_id';
            is $fmb->{bet_class},     'accumulator',           'bet_class';
            is $fmb->{bet_type},      'ACCU',                  'bet_type';
            is $fmb->{buy_price} + 0, 100,                     'buy_price';
            is $fmb->{expiry_daily},  $contract->expiry_daily, 'expiry_daily';
            is $fmb->{expiry_time},   undef,                   'expiry_time';
            is $fmb->{fixed_expiry},  undef,                   'fixed_expiry';
            is $fmb->{is_expired},    0,                       'is_expired';
            ok $fmb->{is_sold}, 'is_sold';
            cmp_ok +Date::Utility->new($fmb->{purchase_time})->epoch, '<=', time, 'purchase_time';
            is $fmb->{sell_price} + 0, $contract->bid_price + 0, 'sell_price';
            cmp_ok +Date::Utility->new($fmb->{sell_time})->epoch, '<=', $contract->date_pricing->epoch, 'sell_time';
            is $fmb->{settlement_time}, undef, 'settlement_time';
            like $fmb->{short_code}, qr/ACCU/, 'short_code';
            cmp_ok +Date::Utility->new($fmb->{start_time})->epoch, '<=', time, 'start_time';
            is $fmb->{tick_count},        undef,   'tick_count';
            is $fmb->{underlying_symbol}, 'R_100', 'underlying_symbol';
        };

        subtest 'chld row', sub {
            is $chld->{financial_market_bet_id},    $fmb->{id},         'financial_market_bet_id';
            is $chld->{'take_profit_order_amount'}, undef,              'take_profit_order_amount is undef';
            is $chld->{'take_profit_order_date'},   undef,              'take_profit_order_date is undef';
            is $chld->{'ask_spread'},               undef,              'ask_spread is undef';
            is $chld->{'bid_spread'},               0.0099999999999989, 'bid_spread is charged for sell';
            is $chld->{tick_final_count},           1,                  'tick_final_count is as expected';
        };

        is $txn->contract_id,    $fmb->{id},            'txn->contract_id';
        is $txn->transaction_id, $trx->{id},            'txn->transaction_id';
        is $txn->balance_after,  $trx->{balance_after}, 'txn->balance_after';
    }
    'survived';
};

subtest 'buy ACCU with take profit', sub {
    lives_ok {
        $args->{date_pricing} = $now;
        $args->{limit_order}  = {
            take_profit => '5',
        };
        my $contract = produce_contract($args);

        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 100,
            amount        => 100,
            amount_type   => 'stake',
            source        => 19,
            purchase_date => $contract->date_start,
        });

        my $error = $txn->buy();
        ok !$error, 'buy without error';
        is $txn->price_slippage, '0', 'no slippage';

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
        ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db accumulator => $txn->transaction_id;

        subtest 'transaction row', sub {
            plan tests => 11;
            cmp_ok $trx->{id}, '>', 0, 'id';
            is $trx->{account_id},              $acc_usd->id,           'account_id';
            is $trx->{action_type},             'buy',                  'action_type';
            is $trx->{amount} + 0,              -100,                   'amount';
            is $trx->{balance_after} + 0,       5000 - 100,             'balance_after';
            is $trx->{financial_market_bet_id}, $fmb->{id},             'financial_market_bet_id';
            is $trx->{payment_id},              undef,                  'payment_id';
            is $trx->{referrer_type},           'financial_market_bet', 'referrer_type';
            is $trx->{staff_loginid},           $cl->loginid,           'staff_loginid';
            is $trx->{source},                  19,                     'source';
            cmp_ok +Date::Utility->new($trx->{transaction_time})->epoch, '<=', time, 'transaction_time';
        };

        subtest 'fmb row', sub {
            plan tests => 18;
            cmp_ok $fmb->{id}, '>', 0, 'id';
            is $fmb->{account_id},    $acc_usd->id,            'account_id';
            is $fmb->{bet_class},     'accumulator',           'bet_class';
            is $fmb->{bet_type},      'ACCU',                  'bet_type';
            is $fmb->{buy_price} + 0, 100,                     'buy_price';
            is $fmb->{expiry_daily},  $contract->expiry_daily, 'expiry_daily';
            is $fmb->{expiry_time},   undef,                   'expiry_time';
            is $fmb->{fixed_expiry},  undef,                   'fixed_expiry';
            is $fmb->{is_expired},    0,                       'is_expired';
            is $fmb->{is_sold},       0,                       'is_sold';
            cmp_ok +Date::Utility->new($fmb->{purchase_time})->epoch, '<=', time, 'purchase_time';
            is $fmb->{sell_price},      undef, 'sell_price';
            is $fmb->{sell_time},       undef, 'sell_time';
            is $fmb->{settlement_time}, undef, 'settlement_time';
            like $fmb->{short_code}, qr/ACCU/, 'short_code';
            cmp_ok +Date::Utility->new($fmb->{start_time})->epoch, '<=', time, 'start_time';
            is $fmb->{tick_count},        undef,   'tick_count';
            is $fmb->{underlying_symbol}, 'R_100', 'underlying_symbol';
        };

        subtest 'chld row', sub {
            is $chld->{financial_market_bet_id},  $fmb->{id}, 'financial_market_bet_id';
            is $chld->{take_profit_order_amount}, 5,          'take_profit_order_amount is 5';
            cmp_ok $chld->{take_profit_order_date}, "eq", $fmb->{start_time}, 'take_profit_order_date is correctly set';
            is $chld->{'ask_spread'}, undef, 'ask_spread is undef';
            is $chld->{'bid_spread'}, undef, 'bid_spread is undef';
        };
    }
    'survived';
};

subtest 'sell a bet with take profit', sub {
    lives_ok {
        $args->{date_pricing} = $args->{date_start}->epoch + 2;
        $args->{limit_order}  = {
            take_profit => {
                order_amount => 5,
                order_date   => $now,
            }};
        my $contract = produce_contract($args);

        my $txn = BOM::Transaction->new({
            purchase_date => $contract->date_start->epoch,
            client        => $cl,
            contract      => $contract,
            contract_id   => $fmb->{id},
            price         => 100,
            source        => 23,
        });

        my $error = $txn->sell();
        is $error, undef, 'no error';

        ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db accumulator => $txn->transaction_id;

        subtest 'transaction row', sub {
            cmp_ok $trx->{id}, '>', 0, 'id';
            is $trx->{account_id},              $acc_usd->id,             'account_id';
            is $trx->{action_type},             'sell',                   'action_type';
            is $trx->{amount} + 0,              $contract->bid_price + 0, 'amount';
            is $trx->{balance_after} + 0,       5000,                     'balance_after';
            is $trx->{financial_market_bet_id}, $fmb->{id},               'financial_market_bet_id';
            is $trx->{payment_id},              undef,                    'payment_id';
            is $trx->{quantity},                1,                        'quantity';
            is $trx->{referrer_type},           'financial_market_bet',   'referrer_type';
            is $trx->{staff_loginid},           $cl->loginid,             'staff_loginid';
            is $trx->{source},                  23,                       'source';
            cmp_ok +Date::Utility->new($trx->{transaction_time})->epoch, '<=', time, 'transaction_time';
        };

        subtest 'fmb row', sub {
            plan tests => 19;
            cmp_ok $fmb->{id}, '>', 0, 'id';
            is $fmb->{account_id},    $acc_usd->id,            'account_id';
            is $fmb->{bet_class},     'accumulator',           'bet_class';
            is $fmb->{bet_type},      'ACCU',                  'bet_type';
            is $fmb->{buy_price} + 0, 100,                     'buy_price';
            is $fmb->{expiry_daily},  $contract->expiry_daily, 'expiry_daily';
            is $fmb->{expiry_time},   undef,                   'expiry_time';
            is $fmb->{fixed_expiry},  undef,                   'fixed_expiry';
            is $fmb->{is_expired},    0,                       'is_expired';
            ok $fmb->{is_sold}, 'is_sold';
            cmp_ok +Date::Utility->new($fmb->{purchase_time})->epoch, '<=', time, 'purchase_time';
            is $fmb->{sell_price} + 0, $contract->bid_price + 0, 'sell_price';
            cmp_ok +Date::Utility->new($fmb->{sell_time})->epoch, '<=', $contract->date_pricing->epoch, 'sell_time';
            is $fmb->{settlement_time}, undef, 'settlement_time';
            like $fmb->{short_code}, qr/ACCU/, 'short_code';
            cmp_ok +Date::Utility->new($fmb->{start_time})->epoch, '<=', time, 'start_time';
            is $fmb->{tick_count},        undef,   'tick_count';
            is $fmb->{underlying_symbol}, 'R_100', 'underlying_symbol';
        };

        is $txn->contract_id,    $fmb->{id},            'txn->contract_id';
        is $txn->transaction_id, $trx->{id},            'txn->transaction_id';
        is $txn->balance_after,  $trx->{balance_after}, 'txn->balance_after';
    }
    'survived';
};

$args->{date_pricing} = $now;
delete $args->{limit_order};
my $mock_calendar = Test::MockModule->new('Finance::Calendar');
$mock_calendar->mock(
    is_open_at => sub { 1 },
    is_open    => sub { 1 },
    trades_on  => sub { 1 });

my $mock_date = Test::MockModule->new('Date::Utility');

$mock_date->mock('hour' => sub { return 20 });

subtest 'sell failure due to update' => sub {
    my $mocked_limits = Test::MockModule->new('BOM::Transaction');
    $mocked_limits->mock(
        'get_contract_per_symbol_limits',
        sub {
            return {
                max_open_positions       => 100,
                max_daily_volume         => 100000,
                max_aggregate_open_stake => {'growth_rate_0.01' => 3000}};
        });

    my $contract = produce_contract($args);

    my $txn = BOM::Transaction->new({
        client        => $cl,
        contract      => $contract,
        price         => 100,
        source        => 23,
        purchase_date => $contract->date_start,
        amount        => 100,
        amount_type   => 'stake',
    });

    my $error = $txn->buy();
    ok !$error, 'buy without error';

    ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db accumulator => $txn->transaction_id;
    # create sell transaction object

    my $contract_sell = produce_contract({
        underlying   => $underlying->symbol,
        bet_type     => 'ACCU',
        date_start   => $contract->date_start,
        date_pricing => $contract->date_start->plus_time_interval(3),
        currency     => 'USD',
        growth_rate  => 0.01,
        amount       => 100,
        amount_type  => 'stake',
        current_tick => $current_tick,
    });

    my $sell_txn = BOM::Transaction->new({
        purchase_date => $contract->date_start,
        client        => $cl,
        contract      => $contract_sell,
        contract_id   => $fmb->{id},
        price         => $contract_sell->bid_price,
        source        => 23,
    });

    # update contract before sell
    my $updater = BOM::Transaction::ContractUpdate->new(
        client        => $cl,
        contract_id   => $fmb->{id},
        update_params => {take_profit => 2},
    );

    ok $updater->is_valid_to_update, 'valid to update';
    $updater->update;
    $error = $sell_txn->sell();
    ok $error, 'sell failed after contract is updated';
    is $error->{-mesg}, 'Contract is updated while attempting to sell', 'error mesg Contract is updated while attempting to sell';
    is $error->{-type}, 'SellFailureDueToUpdate',                       'error type SellFailureDueToUpdate';

    SKIP: {
        skip "skip running time sensitive tests for code coverage tests", 2 if $ENV{DEVEL_COVER_OPTIONS};

        subtest 'sell_expired_contract with contract id' => sub {
            $mocked_contract->mock('is_expired', sub { return 1 });

            sleep 1;
            my $out = BOM::Transaction::sell_expired_contracts({
                    client       => $cl,
                    source       => 23,
                    contract_ids => [$fmb->{id}]});
            ok $out->{number_of_sold_bets} == 1, 'sold one contract';
        };
        $mocked_contract->unmock('is_expired');
        subtest 'sell_expired_contract without contract id' => sub {
            for (1 .. 3) {
                $contract = produce_contract($args);

                $txn = BOM::Transaction->new({
                    client        => $cl,
                    contract      => $contract,
                    price         => 100,
                    source        => 19,
                    purchase_date => $contract->date_start,
                    amount        => 100,
                    amount_type   => 'stake',
                });

                my $error = $txn->buy();
                ok !$error, 'buy without error';
            }

            $mocked_contract->mock('is_expired', sub { return 1 });

            sleep 1;
            my $out = BOM::Transaction::sell_expired_contracts({
                client => $cl,
                source => 23,
            });

            ok $out->{number_of_sold_bets} == 3, 'sold three contracts';
            $mocked_contract->unmock('is_expired');
        };
    }
};

subtest 'slippage' => sub {
    subtest 'executed at better price' => sub {
        my $contract = produce_contract($args);

        if ($ENV{DEVEL_COVER_OPTIONS}) {
            $mocked_contract->mock('is_expired', sub { return 1 });

            sleep 1;
            my $out = BOM::Transaction::sell_expired_contracts({
                client => $cl,
                source => 23,
            });

            $mocked_contract->unmock('is_expired');
        }

        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 100,
            amount        => 100,
            amount_type   => 'stake',
            source        => 19,
            purchase_date => $contract->date_start,
        });
        my $error = $txn->buy();
        ok !$error, 'buy without error';
        ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db accumulator => $txn->transaction_id;

        my $price = $contract->calculate_payout(1);
        $args->{date_pricing} = $args->{date_start}->epoch + 3;
        my $sell_contract = produce_contract($args);

        $txn = BOM::Transaction->new({
            client        => $cl,
            contract_id   => $fmb->{id},
            contract      => $sell_contract,
            price         => $price,
            purchase_date => $contract->date_start,
        });

        $error = $txn->sell;
        ok !$error, 'sell without error';
        is $txn->price_slippage, '1.00', 'correct price slippage';
    };

    subtest 'executed at zero payout' => sub {
        $args->{date_pricing} = $args->{date_start};
        my $contract = produce_contract($args);
        my $txn      = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 100,
            amount        => 100,
            amount_type   => 'stake',
            source        => 19,
            purchase_date => $contract->date_start,
        });
        my $error = $txn->buy();
        ok !$error, 'buy without error';
        ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db accumulator => $txn->transaction_id;

        my $price = $contract->calculate_payout(2);
        $args->{date_pricing} = $args->{date_start}->epoch + 4;
        my $sell_contract = produce_contract($args);

        $txn = BOM::Transaction->new({
            client        => $cl,
            contract_id   => $fmb->{id},
            contract      => $sell_contract,
            price         => $price,
            purchase_date => $contract->date_start,
        });

        my $mocked_validation = Test::MockModule->new('BOM::Transaction::Validation');
        $mocked_validation->mock(
            '_validate_sell_pricing_adjustment',
            sub {
                my $self = shift;
                return $self->_validate_non_binary_price_adjustment();
            });

        $error = $txn->sell;
        ok !$error, 'sell without error';
        is $txn->price_slippage, '-101.00', 'correct price slippage';

        $mocked_validation->unmock_all();
    }

};

subtest 'buy accumulator on crash/boom with VRTC' => sub {
    my $vr = create_client('VRTC');
    top_up $vr, 'USD', 5000;

    $args->{underlying} = "CRASH500";
    my $contract = produce_contract($args);

    my $txn = BOM::Transaction->new({
        client        => $vr,
        contract      => $contract,
        price         => 100,
        amount        => 100,
        amount_type   => 'stake',
        source        => 19,
        purchase_date => $contract->date_start,
    });

    my $error = $txn->buy();
    is $error->{-message_to_client}, 'Trading is not offered for this asset.', 'crash/boom symbols are not offered';

};

subtest 'calculate limits', sub {
    my $crcl = create_client('CR');
    top_up $crcl, 'USD', 5000;

    my $acc_usd = $crcl->account;
    is $acc_usd->currency_code, 'USD', 'got USD account';

    my $bal;
    is + ($bal = $acc_usd->balance + 0), 5000, 'USD balance is 5000 got: ' . $bal;
    my $contract = produce_contract($args);

    my $txn = BOM::Transaction->new({
        client        => $crcl,
        contract      => $contract,
        price         => 100,
        amount        => 100,
        amount_type   => 'stake',
        source        => 19,
        purchase_date => $contract->date_start,
    });

    my $lim = $txn->calculate_limits;
    is $lim->{max_aggregate_open_stake}, 3000, "max_aggregate_open_stake is correct";
};

done_testing();
