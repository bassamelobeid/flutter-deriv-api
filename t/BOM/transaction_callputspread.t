#!/usr/bin/perl

use strict;
use warnings;

use Test::MockModule;
use Test::More;
use Test::FailWarnings;
use Test::Exception;

use Crypt::NamedKeys;
use Date::Utility;
use BOM::Database::ClientDB;
use BOM::Transaction;
use BOM::Transaction::Validation;
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Helper::Client qw(create_client top_up);
use JSON::MaybeXS;

initialize_realtime_ticks_db();

Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';
my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');
$mock_validation->mock(validate_tnc => sub { note "mocked Transaction::Validation->validate_tnc returning nothing"; undef });

my $now = Date::Utility->new;
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $now
    }) for qw(USD JPY-USD);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $now
    });

my $tick_r100 = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch,
    underlying => 'R_100',
    quote      => 100,
});

my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
$mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

my $mock_transaction = Test::MockModule->new('BOM::Transaction');
# _validate_trade_pricing_adjustment() is tested in trade_validation.t
$mock_validation->mock(
    _validate_trade_pricing_adjustment => sub { note "mocked Transaction::Validation->_validate_trade_pricing_adjustment returning nothing"; () });
$mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning '[]'"; [] });

my $cl = create_client('CR');
top_up $cl, 'USD', 5000;
my $acc_usd;
isnt + ($acc_usd = $cl->account), 'USD', 'got USD account';

subtest 'buy CALLSPREAD' => sub {
    my $contract = produce_contract({
        underlying   => 'R_100',
        bet_type     => 'CALLSPREAD',
        currency     => 'USD',
        payout       => 100,
        duration     => '2m',
        current_tick => $tick_r100,
        high_barrier => 'S10P',
        low_barrier  => 'S-10P',
    });

    my $txn = BOM::Transaction->new({
        client        => $cl,
        contract      => $contract,
        price         => 50,
        payout        => $contract->payout,
        amount_type   => 'payout',
        purchase_date => $contract->date_start,
    });

    my $error = $txn->buy;
    ok !$error, 'no error';

    subtest 'transaction report', sub {
        note $txn->report;
        my $report = $txn->report;
        like $report, qr/\ATransaction Report:$/m,                                                    'header';
        like $report, qr/^\s*Client: \Q${\$cl}\E$/m,                                                  'client';
        like $report, qr/^\s*Contract: \Q${\$contract->code}\E$/m,                                    'contract';
        like $report, qr/^\s*Price: \Q${\$txn->price}\E$/m,                                           'price';
        like $report, qr/^\s*Payout: \Q${\$txn->payout}\E$/m,                                         'payout';
        like $report, qr/^\s*Amount Type: \Q${\$txn->amount_type}\E$/m,                               'amount_type';
        like $report, qr/^\s*Staff: \Q${\$txn->staff}\E$/m,                                           'staff';
        like $report, qr/^\s*Transaction Parameters: \$VAR1 = \{$/m,                                  'transaction parameters';
        like $report, qr/^\s*Transaction ID: \Q${\$txn->transaction_id}\E$/m,                         'transaction id';
        like $report, qr/^\s*Purchase Date: \Q${\$txn->purchase_date->datetime_yyyymmdd_hhmmss}\E$/m, 'purchase date';
    };

    my ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db(callput_spread => $txn->transaction_id);

    # note explain $trx;

    subtest 'transaction row', sub {
        cmp_ok $trx->{id}, '>', 0, 'id';
        is $trx->{account_id}, $acc_usd->id, 'account_id';
        is $trx->{action_type}, 'buy', 'action_type';
        is $trx->{amount} + 0, -50, 'amount';
        is $trx->{balance_after} + 0, 5000 - 50, 'balance_after';
        is $trx->{financial_market_bet_id}, $fmb->{id}, 'financial_market_bet_id';
        is $trx->{payment_id}, undef, 'payment_id';

        is $trx->{referrer_type}, 'financial_market_bet', 'referrer_type';
        is $trx->{remark}, undef, 'remark';
        is $trx->{staff_loginid}, $cl->loginid, 'staff_loginid';
        cmp_ok +Date::Utility->new($trx->{transaction_time})->epoch, '<=', time, 'transaction_time';
    };

    # note explain $fmb;

    subtest 'fmb row', sub {
        cmp_ok $fmb->{id}, '>', 0, 'id';
        is $fmb->{account_id}, $acc_usd->id, 'account_id';
        is $fmb->{bet_class}, 'callput_spread', 'bet_class';
        is $fmb->{bet_type},  'CALLSPREAD',     'bet_type';
        is $fmb->{buy_price} + 0, 50, 'buy_price';
        is !$fmb->{expiry_daily}, !$contract->expiry_daily, 'expiry_daily';
        cmp_ok +Date::Utility->new($fmb->{expiry_time})->epoch, '>', time, 'expiry_time';
        is $fmb->{fixed_expiry}, undef, 'fixed_expiry';
        is !$fmb->{is_expired}, !0, 'is_expired';
        is !$fmb->{is_sold},    !0, 'is_sold';
        cmp_ok +Date::Utility->new($fmb->{purchase_time})->epoch, '<=', time, 'purchase_time';
        is $fmb->{sell_price}, undef, 'sell_price';
        is $fmb->{sell_time},  undef, 'sell_time';
        cmp_ok +Date::Utility->new($fmb->{settlement_time})->epoch, '>', time, 'settlement_time';
        like $fmb->{short_code}, qr/CALLSPREAD/, 'short_code';
        cmp_ok +Date::Utility->new($fmb->{start_time})->epoch, '<=', time, 'start_time';
        is $fmb->{tick_count},        undef,   'tick_count';
        is $fmb->{underlying_symbol}, 'R_100', 'underlying_symbol';
    };

    # note explain $chld;

    subtest 'chld row', sub {
        is $chld->{absolute_high_barrier}, undef, 'absolute_high_barrier';
        is $chld->{absolute_low_barrier},  undef, 'absolute_low_barrier';
        is $chld->{financial_market_bet_id}, $fmb->{id}, 'financial_market_bet_id';
        is $chld->{prediction},            undef,   'prediction';
        is $chld->{relative_high_barrier}, 'S10P',  'relative_high_barrier';
        is $chld->{relative_low_barrier},  'S-10P', 'relative_low_barrier';
    };
};

subtest 'buy PUTSPREAD' => sub {
    my $contract = produce_contract({
        underlying   => 'R_100',
        bet_type     => 'PUTSPREAD',
        currency     => 'USD',
        payout       => 100,
        duration     => '2m',
        current_tick => $tick_r100,
        high_barrier => 100,
        low_barrier  => 99,
    });

    my $txn = BOM::Transaction->new({
        client        => $cl,
        contract      => $contract,
        price         => 50,
        payout        => $contract->payout,
        amount_type   => 'payout',
        purchase_date => $contract->date_start,
    });
    my $error = $txn->buy;
    ok !$error;

    subtest 'transaction report', sub {
        note $txn->report;
        my $report = $txn->report;
        like $report, qr/\ATransaction Report:$/m,                                                    'header';
        like $report, qr/^\s*Client: \Q${\$cl}\E$/m,                                                  'client';
        like $report, qr/^\s*Contract: \Q${\$contract->code}\E$/m,                                    'contract';
        like $report, qr/^\s*Price: \Q${\$txn->price}\E$/m,                                           'price';
        like $report, qr/^\s*Payout: \Q${\$txn->payout}\E$/m,                                         'payout';
        like $report, qr/^\s*Amount Type: \Q${\$txn->amount_type}\E$/m,                               'amount_type';
        like $report, qr/^\s*Staff: \Q${\$txn->staff}\E$/m,                                           'staff';
        like $report, qr/^\s*Transaction Parameters: \$VAR1 = \{$/m,                                  'transaction parameters';
        like $report, qr/^\s*Transaction ID: \Q${\$txn->transaction_id}\E$/m,                         'transaction id';
        like $report, qr/^\s*Purchase Date: \Q${\$txn->purchase_date->datetime_yyyymmdd_hhmmss}\E$/m, 'purchase date';
    };

    my ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db(callput_spread => $txn->transaction_id);

    # note explain $trx;

    subtest 'transaction row', sub {
        cmp_ok $trx->{id}, '>', 0, 'id';
        is $trx->{account_id}, $acc_usd->id, 'account_id';
        is $trx->{action_type}, 'buy', 'action_type';
        is $trx->{amount} + 0, -50, 'amount';
        is $trx->{balance_after} + 0, 5000 - 50 - 50, 'balance_after';
        is $trx->{financial_market_bet_id}, $fmb->{id}, 'financial_market_bet_id';
        is $trx->{payment_id}, undef, 'payment_id';

        is $trx->{referrer_type}, 'financial_market_bet', 'referrer_type';
        is $trx->{remark}, undef, 'remark';
        is $trx->{staff_loginid}, $cl->loginid, 'staff_loginid';
        cmp_ok +Date::Utility->new($trx->{transaction_time})->epoch, '<=', time, 'transaction_time';
    };

    # note explain $fmb;

    subtest 'fmb row', sub {
        cmp_ok $fmb->{id}, '>', 0, 'id';
        is $fmb->{account_id}, $acc_usd->id, 'account_id';
        is $fmb->{bet_class}, 'callput_spread', 'bet_class';
        is $fmb->{bet_type},  'PUTSPREAD',      'bet_type';
        is $fmb->{buy_price} + 0, 50, 'buy_price';
        is !$fmb->{expiry_daily}, !$contract->expiry_daily, 'expiry_daily';
        cmp_ok +Date::Utility->new($fmb->{expiry_time})->epoch, '>', time, 'expiry_time';
        is $fmb->{fixed_expiry}, undef, 'fixed_expiry';
        is !$fmb->{is_expired}, !0, 'is_expired';
        is !$fmb->{is_sold},    !0, 'is_sold';
        cmp_ok +Date::Utility->new($fmb->{purchase_time})->epoch, '<=', time, 'purchase_time';
        is $fmb->{sell_price}, undef, 'sell_price';
        is $fmb->{sell_time},  undef, 'sell_time';
        cmp_ok +Date::Utility->new($fmb->{settlement_time})->epoch, '>', time, 'settlement_time';
        like $fmb->{short_code}, qr/PUTSPREAD/, 'short_code';
        cmp_ok +Date::Utility->new($fmb->{start_time})->epoch, '<=', time, 'start_time';
        is $fmb->{tick_count},        undef,   'tick_count';
        is $fmb->{underlying_symbol}, 'R_100', 'underlying_symbol';
    };

    # note explain $chld;

    subtest 'chld row', sub {
        is $chld->{absolute_high_barrier}, 100, 'absolute_high_barrier';
        is $chld->{absolute_low_barrier},  99,  'absolute_low_barrier';
        is $chld->{financial_market_bet_id}, $fmb->{id}, 'financial_market_bet_id';
        is $chld->{prediction},            undef, 'prediction';
        is $chld->{relative_high_barrier}, undef, 'relative_high_barrier';
        is $chld->{relative_low_barrier},  undef, 'relative_low_barrier';
    };

};

subtest 'offerings' => sub {
    my $args = {
        bet_type     => 'PUTSPREAD',
        currency     => 'USD',
        payout       => 100,
        high_barrier => 100,
        low_barrier  => 99,
    };
    my $invalid_duration = 'Intraday duration not acceptable';
    my $invalid_category = 'Invalid contract category';
    foreach my $data ((
            ['R_100', '15s', 1],
            ['R_100',     '14s',   0, $invalid_duration],
            ['frxUSDJPY', '1m59s', 0, $invalid_category],
            ['AEX',       '1d',    0, $invalid_category],
            ['frxXAGUSD', '1d',    0, $invalid_category]))
    {
        $args->{underlying}   = $data->[0];
        $args->{duration}     = $data->[1];
        $args->{current_tick} = $tick_r100;    # just a fake tick

        my $contract = produce_contract($args);
        my $txn      = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 50,
            payout        => $contract->payout,
            amount_type   => 'payout',
            purchase_date => $contract->date_start,
        });
        delete $args->{current_tick};
        note('attempting to buy ' . JSON::MaybeXS->new->encode($args));
        my $error = $txn->buy;

        if ($data->[2]) {
            ok !$error, 'no error';
        } else {
            ok $error, 'invalid buy';
            is $error->{'-type'}, 'InvalidOfferings', 'InvalidOfferings';
            is $error->{'-mesg'}, $data->[3], $data->[3];
        }
    }
};

done_testing();

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

    my $db = BOM::Database::ClientDB->new({
            broker_code => 'CR',
        })->db;
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

