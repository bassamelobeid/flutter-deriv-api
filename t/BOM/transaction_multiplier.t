#!/etc/rmg/bin/perl

use strict;
use warnings;
use Test::MockTime qw/:all/;
use Test::MockModule;
use Test::More;
use Test::Exception;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Helper::Client qw(top_up);

use Guard;
use Crypt::NamedKeys;
use Date::Utility;

use BOM::User::Client;
use BOM::User::Password;
use BOM::User::Utility;
use BOM::User;

use BOM::Transaction;
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
    undeerlying => $underlying->symbol,
    epoch       => $now->epoch,
    quote       => 100,
});

initialize_realtime_ticks_db();

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

subtest 'buy MULTUP', sub {
    lives_ok {
        my $contract = produce_contract({
            underlying   => $underlying,
            bet_type     => 'MULTUP',
            currency     => 'USD',
            multiplier   => 5.0,
            amount       => 100,
            amount_type  => 'stake',
            current_tick => $current_tick,
        });

        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 100,
            amount        => 100,
            amount_type   => 'stake',
            source        => 19,
            purchase_date => $contract->date_start,
        });

        my $error = $txn->buy;
        ok !$error, 'buy without error';

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
        ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db multiplier => $txn->transaction_id;

        # note explain $trx;

        subtest 'transaction row', sub {
            plan tests => 12;
            cmp_ok $trx->{id}, '>', 0, 'id';
            is $trx->{account_id}, $acc_usd->id, 'account_id';
            is $trx->{action_type}, 'buy', 'action_type';
            is $trx->{amount} + 0, -100, 'amount';
            is $trx->{balance_after} + 0, 5000 - 100, 'balance_after';
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
            is $fmb->{bet_class}, 'multiplier', 'bet_class';
            is $fmb->{bet_type},  'MULTUP',     'bet_type';
            is $fmb->{buy_price} + 0, 100, 'buy_price';
            is !$fmb->{expiry_daily}, !$contract->expiry_daily, 'expiry_daily';
            cmp_ok +Date::Utility->new($fmb->{expiry_time})->epoch, '>', time, 'expiry_time';
            is $fmb->{fixed_expiry}, undef, 'fixed_expiry';
            is !$fmb->{is_expired}, !0, 'is_expired';
            is !$fmb->{is_sold},    !0, 'is_sold';
            cmp_ok +Date::Utility->new($fmb->{purchase_time})->epoch, '<=', time, 'purchase_time';
            like $fmb->{remark},   qr/\btrade\[100\.00000\]/, 'remark';
            is $fmb->{sell_price}, undef,                     'sell_price';
            is $fmb->{sell_time},  undef,                     'sell_time';
            cmp_ok +Date::Utility->new($fmb->{settlement_time})->epoch, '>', time, 'settlement_time';
            like $fmb->{short_code}, qr/MULTUP/, 'short_code';
            cmp_ok +Date::Utility->new($fmb->{start_time})->epoch, '<=', time, 'start_time';
            is $fmb->{tick_count},        undef,   'tick_count';
            is $fmb->{underlying_symbol}, 'R_100', 'underlying_symbol';
        };

        # note explain $chld;

        subtest 'chld row', sub {
            is $chld->{financial_market_bet_id}, $fmb->{id}, 'financial_market_bet_id';
            is $chld->{'multiplier'},             5,        'multiplier is 5';
            is $chld->{'basis_spot'},             '100.00', 'basis_spot is 100.00';
            is $chld->{'stop_loss_order_amount'}, undef,    'stop_loss_order_amount is undef';
            is $chld->{'stop_loss_basis_spot'},   undef,    'stop_loss_basis_spot is undef';
            is $chld->{'stop_out_order_amount'} + 0, -100, 'stop_out_order_amount is -100';
            cmp_ok $chld->{'stop_out_order_date'}, "eq", $fmb->{start_time}, 'stop_out_order_date is correctly set';
            is $chld->{'take_profit_order_amount'}, undef, 'take_profit_order_amount is undef';
            is $chld->{'take_profit_order_date'},   undef, 'take_profit_order_date is undef';
        };

    }
    'survived';
};

subtest 'buy MULTUP with take profit', sub {
    lives_ok {
        my $contract = produce_contract({
                underlying   => $underlying,
                bet_type     => 'MULTUP',
                currency     => 'USD',
                multiplier   => 5,
                amount       => 100,
                amount_type  => 'stake',
                current_tick => $current_tick,
                limit_order  => [{
                        order_type   => 'take_profit',
                        order_amount => 5
                    }
                ],
            });

        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 100,
            amount        => 100,
            amount_type   => 'stake',
            source        => 19,
            purchase_date => $contract->date_start,
        });

        my $error = $txn->buy;
        ok !$error, 'buy without error';

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
        ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db multiplier => $txn->transaction_id;

        # note explain $trx;

        subtest 'transaction row', sub {
            plan tests => 12;
            cmp_ok $trx->{id}, '>', 0, 'id';
            is $trx->{account_id}, $acc_usd->id, 'account_id';
            is $trx->{action_type}, 'buy', 'action_type';
            is $trx->{amount} + 0, -100, 'amount';
            is $trx->{balance_after} + 0, 4900 - 100, 'balance_after';
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
            is $fmb->{bet_class}, 'multiplier', 'bet_class';
            is $fmb->{bet_type},  'MULTUP',     'bet_type';
            is $fmb->{buy_price} + 0, 100, 'buy_price';
            is !$fmb->{expiry_daily}, !$contract->expiry_daily, 'expiry_daily';
            cmp_ok +Date::Utility->new($fmb->{expiry_time})->epoch, '>', time, 'expiry_time';
            is $fmb->{fixed_expiry}, undef, 'fixed_expiry';
            is !$fmb->{is_expired}, !0, 'is_expired';
            is !$fmb->{is_sold},    !0, 'is_sold';
            cmp_ok +Date::Utility->new($fmb->{purchase_time})->epoch, '<=', time, 'purchase_time';
            like $fmb->{remark},   qr/\btrade\[100\.00000\]/, 'remark';
            is $fmb->{sell_price}, undef,                     'sell_price';
            is $fmb->{sell_time},  undef,                     'sell_time';
            cmp_ok +Date::Utility->new($fmb->{settlement_time})->epoch, '>', time, 'settlement_time';
            like $fmb->{short_code}, qr/MULTUP/, 'short_code';
            cmp_ok +Date::Utility->new($fmb->{start_time})->epoch, '<=', time, 'start_time';
            is $fmb->{tick_count},        undef,   'tick_count';
            is $fmb->{underlying_symbol}, 'R_100', 'underlying_symbol';
        };

        # note explain $chld;

        subtest 'chld row', sub {
            is $chld->{financial_market_bet_id}, $fmb->{id}, 'financial_market_bet_id';
            is $chld->{'multiplier'},             5,        'multiplier is 5';
            is $chld->{'basis_spot'},             '100.00', 'basis_spot is 100.00';
            is $chld->{'stop_loss_order_amount'}, undef,    'stop_loss_order_amount is undef';
            is $chld->{'stop_loss_order_date'},   undef,    'stop_loss_order_date is undef';
            is $chld->{'stop_out_order_amount'} + 0, -100, 'stop_out_order_amount is -100';
            cmp_ok $chld->{'stop_out_order_date'}, "eq", $fmb->{start_time}, 'stop_out_order_date is correctly set';
            is $chld->{'take_profit_order_amount'}, 5, 'take_profit_order_amount is 5';
            cmp_ok $chld->{'take_profit_order_date'}, "eq", $fmb->{start_time}, 'take_profit_order_date is correctly set';
        };

    }
    'survived';
};

subtest 'sell a bet', sub {
    lives_ok {
        sleep 1;    # sell_time != purchase_time
        my $contract = produce_contract({
            underlying   => $underlying,
            bet_type     => 'MULTUP',
            currency     => 'USD',
            multiplier   => 5,
            amount       => 100,
            amount_type  => 'stake',
            current_tick => $current_tick,
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
            cmp_ok $trx->{id}, '>', 0, 'id';
            is $trx->{account_id}, $acc_usd->id, 'account_id';
            is $trx->{action_type}, 'sell', 'action_type';
            is $trx->{amount} + 0, $contract->bid_price + 0, 'amount';
            is $trx->{balance_after} + 0, 4900, 'balance_after';
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
            cmp_ok $fmb->{id}, '>', 0, 'id';
            is $fmb->{account_id}, $acc_usd->id, 'account_id';
            is $fmb->{bet_class}, 'multiplier', 'bet_class';
            is $fmb->{bet_type},  'MULTUP',     'bet_type';
            is $fmb->{buy_price} + 0, 100, 'buy_price';
            ok $fmb->{expiry_daily}, 'expiry_daily';
            is $fmb->{fixed_expiry}, undef, 'fixed_expiry';
            is $fmb->{is_expired},   0, 'is_expired';
            ok $fmb->{is_sold},      'is_sold';
            is $fmb->{sell_price} + 0, $contract->bid_price + 0, 'sell_price';
            cmp_ok +Date::Utility->new($fmb->{sell_time})->epoch,       '<=', time, 'sell_time';
            cmp_ok +Date::Utility->new($fmb->{settlement_time})->epoch, '>',  time, 'settlement_time';
            like $fmb->{short_code}, qr/MULTUP/, 'short_code';
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

done_testing();
