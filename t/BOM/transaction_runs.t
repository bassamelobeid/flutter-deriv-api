#!/usr/bin/perl

use strict;
use warnings;

use Test::MockModule;
use Test::More;
use Test::Warnings;
use Test::Exception;

use Date::Utility;
use BOM::Transaction;
use BOM::Transaction::Validation;
use Math::Util::CalculatedValue::Validatable;
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Helper::Client qw(create_client top_up);
use BOM::Database::ClientDB;

Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';

my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');
my $mock_contract   = Test::MockModule->new('BOM::Product::Contract');

$mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });
$mock_validation->mock(validate_tnc           => sub { note "mocked Transaction::Validation->validate_tnc returning nothing"; undef });
$mock_validation->mock(_validate_date_pricing => sub { note "mocked Transaction::Validation->_validate_date_pricing returning nothing"; () });
$mock_validation->mock(_is_valid_to_buy       => sub { note "mocked Transaction::Validation->_is_valid_to_buy returning nothing"; () });
$mock_validation->mock(
    _validate_trade_pricing_adjustment => sub { note "mocked Transaction::Validation->_validate_trade_pricing_adjustment returning nothing"; () });

my $now               = Date::Utility->new;
my $underlying_symbol = 'R_100';
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => 'USD',
        recorded_date => $now
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'randomindex',
    {
        symbol        => $underlying_symbol,
        recorded_date => $now
    });
my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch,
    underlying => $underlying_symbol,
});

sub db {
    return BOM::Database::ClientDB->new({
            broker_code => 'CR',
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

my $cl = create_client;
top_up $cl, 'USD', 5000;
my $acc_usd = $cl->account;

subtest 'buy - runhigh' => sub {
    lives_ok {
        my $contract = produce_contract({
            underlying   => $underlying_symbol,
            bet_type     => 'RUNHIGH',
            currency     => 'USD',
            payout       => 100,
            duration     => '2t',
            current_tick => $tick,
            barrier      => 'S0P',
        });

        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 50,
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

        my ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db runs => $txn->transaction_id;

        # note explain $trx;

        subtest 'transaction row', sub {
            plan tests => 13;
            cmp_ok $trx->{id},      '>', 0, 'id';
            is $trx->{account_id},  $acc_usd->id, 'account_id';
            is $trx->{action_type}, 'buy', 'action_type';
            is $trx->{amount} + 0, -50, 'amount';
            is $trx->{balance_after} + 0, 5000 - 50, 'balance_after';
            is $trx->{financial_market_bet_id}, $fmb->{id}, 'financial_market_bet_id';
            is $trx->{payment_id},              undef,                  'payment_id';
            is $trx->{quantity},                1,                      'quantity';
            is $trx->{referrer_type},           'financial_market_bet', 'referrer_type';
            is $trx->{remark},                  undef,                  'remark';
            is $trx->{staff_loginid},           $cl->loginid, 'staff_loginid';
            is $trx->{source},                  19, 'source';
            cmp_ok +Date::Utility->new($trx->{transaction_time})->epoch, '<=', time, 'transaction_time';
        };

        SKIP: {
            skip "skip running time sensitive tests for code coverage tests", 1 if $ENV{DEVEL_COVER_OPTIONS};

            # note explain $fmb;
            subtest 'fmb row', sub {
                plan tests => 20;
                cmp_ok $fmb->{id},     '>', 0, 'id';
                is $fmb->{account_id}, $acc_usd->id, 'account_id';
                is $fmb->{bet_class},  'runs',    'bet_class';
                is $fmb->{bet_type},   'RUNHIGH', 'bet_type';
                is $fmb->{buy_price} + 0, 50, 'buy_price';
                is !$fmb->{expiry_daily}, !$contract->expiry_daily, 'expiry_daily';
                cmp_ok +Date::Utility->new($fmb->{expiry_time})->epoch, '>', time, 'expiry_time';
                is $fmb->{fixed_expiry}, undef, 'fixed_expiry';
                is !$fmb->{is_expired}, !0, 'is_expired';
                is !$fmb->{is_sold},    !0, 'is_sold';
                cmp_ok $fmb->{payout_price} + 0, '==', 100, 'payout_price';
                cmp_ok +Date::Utility->new($fmb->{purchase_time})->epoch, '<=', time, 'purchase_time';
                like $fmb->{remark},   qr/\btrade\[50\.00000\]/, 'remark';
                is $fmb->{sell_price}, undef,                    'sell_price';
                is $fmb->{sell_time},  undef,                    'sell_time';
                cmp_ok +Date::Utility->new($fmb->{settlement_time})->epoch, '>', time, 'settlement_time';
                like $fmb->{short_code}, qr/RUNHIGH/, 'short_code';
                cmp_ok +Date::Utility->new($fmb->{start_time})->epoch, '<=', time, 'start_time';
                is $fmb->{tick_count},        2,       'tick_count';
                is $fmb->{underlying_symbol}, 'R_100', 'underlying_symbol';
            };
        }
        # note explain $chld;

        subtest 'chld row', sub {
            plan tests => 3;
            is $chld->{financial_market_bet_id}, $fmb->{id}, 'financial_market_bet_id';
            is $chld->{selected_tick},           2,     'selected_tick';
            is $chld->{relative_barrier},        'S0P', 'relative_barrier';
        };

        # note explain $qv1;

        subtest 'qv row', sub {
            plan tests => 3;
            is $qv1->{financial_market_bet_id}, $fmb->{id}, 'financial_market_bet_id';
            is $qv1->{transaction_id},          $trx->{id}, 'transaction_id';
            is $qv1->{trade} + 0, 50, 'trade';
        };

        is $txn->contract_id,             $fmb->{id},            'txn->contract_id';
        is $txn->transaction_id,          $trx->{id},            'txn->transaction_id';
        is $txn->balance_after,           $trx->{balance_after}, 'txn->balance_after';
        is $txn->execute_at_better_price, 0, 'txn->execute_at_better_price';
    }
    'survived';
};

subtest 'buy - runlow' => sub {
    lives_ok {
        my $contract = produce_contract({
            underlying   => $underlying_symbol,
            bet_type     => 'RUNLOW',
            currency     => 'USD',
            payout       => 100,
            duration     => '2t',
            current_tick => $tick,
            barrier      => 'S0P',
        });

        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 50,
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

        my ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db runs => $txn->transaction_id;

        # note explain $trx;

        subtest 'transaction row', sub {
            plan tests => 13;
            cmp_ok $trx->{id},      '>', 0, 'id';
            is $trx->{account_id},  $acc_usd->id, 'account_id';
            is $trx->{action_type}, 'buy', 'action_type';
            is $trx->{amount} + 0, -50, 'amount';
            is $trx->{balance_after} + 0, 5000 - 100, 'balance_after';
            is $trx->{financial_market_bet_id}, $fmb->{id}, 'financial_market_bet_id';
            is $trx->{payment_id},              undef,                  'payment_id';
            is $trx->{quantity},                1,                      'quantity';
            is $trx->{referrer_type},           'financial_market_bet', 'referrer_type';
            is $trx->{remark},                  undef,                  'remark';
            is $trx->{staff_loginid},           $cl->loginid, 'staff_loginid';
            is $trx->{source},                  19, 'source';
            cmp_ok +Date::Utility->new($trx->{transaction_time})->epoch, '<=', time, 'transaction_time';
        };

        # note explain $fmb;

        subtest 'fmb row', sub {
            plan tests => 20;
            cmp_ok $fmb->{id},     '>', 0, 'id';
            is $fmb->{account_id}, $acc_usd->id, 'account_id';
            is $fmb->{bet_class},  'runs',   'bet_class';
            is $fmb->{bet_type},   'RUNLOW', 'bet_type';
            is $fmb->{buy_price} + 0, 50, 'buy_price';
            is !$fmb->{expiry_daily}, !$contract->expiry_daily, 'expiry_daily';
            cmp_ok +Date::Utility->new($fmb->{expiry_time})->epoch, '>', time, 'expiry_time';
            is $fmb->{fixed_expiry}, undef, 'fixed_expiry';
            is !$fmb->{is_expired}, !0, 'is_expired';
            is !$fmb->{is_sold},    !0, 'is_sold';
            cmp_ok $fmb->{payout_price} + 0, '==', 100, 'payout_price';
            cmp_ok +Date::Utility->new($fmb->{purchase_time})->epoch, '<=', time, 'purchase_time';
            like $fmb->{remark},   qr/\btrade\[50\.00000\]/, 'remark';
            is $fmb->{sell_price}, undef,                    'sell_price';
            is $fmb->{sell_time},  undef,                    'sell_time';
            cmp_ok +Date::Utility->new($fmb->{settlement_time})->epoch, '>', time, 'settlement_time';
            like $fmb->{short_code}, qr/RUNLOW/, 'short_code';
            cmp_ok +Date::Utility->new($fmb->{start_time})->epoch, '<=', time, 'start_time';
            is $fmb->{tick_count},        2,       'tick_count';
            is $fmb->{underlying_symbol}, 'R_100', 'underlying_symbol';
        };

        # note explain $chld;

        subtest 'chld row', sub {
            plan tests => 3;
            is $chld->{financial_market_bet_id}, $fmb->{id}, 'financial_market_bet_id';
            is $chld->{selected_tick},           2,     'selected_tick';
            is $chld->{relative_barrier},        'S0P', 'relative_barrier';
        };

        # note explain $qv1;

        subtest 'qv row', sub {
            plan tests => 3;
            is $qv1->{financial_market_bet_id}, $fmb->{id}, 'financial_market_bet_id';
            is $qv1->{transaction_id},          $trx->{id}, 'transaction_id';
            is $qv1->{trade} + 0, 50, 'trade';
        };

        is $txn->contract_id,             $fmb->{id},            'txn->contract_id';
        is $txn->transaction_id,          $trx->{id},            'txn->transaction_id';
        is $txn->balance_after,           $trx->{balance_after}, 'txn->balance_after';
        is $txn->execute_at_better_price, 0, 'txn->execute_at_better_price';
    }
    'survived';
};
done_testing;
