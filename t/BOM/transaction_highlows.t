#!perl

use strict;
use warnings;

use Test::Most;
use Test::FailWarnings;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase;
use BOM::Test::Helper::Client qw(top_up);
use BOM::Transaction;
use BOM::Transaction::Validation;
use BOM::Product::ContractFactory qw( produce_contract make_similar_contract );
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
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

initialize_realtime_ticks_db();

Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => $_,
        date   => Date::Utility->new,
    }) for (qw/USD JPY JPY-USD/);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'AS51',
        recorded_date => Date::Utility->new,
    });

my $now = Date::Utility->new;
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch,
    underlying => 'AS51',
});
my $currency   = 'USD';
my $underlying = create_underlying('AS51');

subtest 'validate client error message' => sub {

    my $mock_cal = Test::MockModule->new('Finance::Calendar');
    $mock_cal->mock('is_open_at', sub { 0 });

    my $now      = Date::Utility->new;
    my $contract = produce_contract({
        underlying    => $underlying,
        bet_type      => 'TICKHIGH',
        currency      => $currency,
        payout        => 1000,
        duration      => '5t',
        selected_tick => 3,
    });

    my $cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});

    my $transaction = BOM::Transaction->new({
        client        => $cr,
        contract      => $contract,
        purchase_date => $contract->date_start,
    });

    my $error = BOM::Transaction::Validation->new({
            clients     => [$cr],
            transaction => $transaction
        })->_is_valid_to_buy($cr);

    like($error->{-message_to_client}, qr/Try out the Synthetic Indices/, 'CR client got message about Synthetic Indices');

    # same params, but new object - not to hold prev error
    $contract = produce_contract({
        underlying    => $underlying,
        bet_type      => 'TICKLOW',
        currency      => $currency,
        payout        => 1000,
        date_start    => $now,
        duration      => '5t',
        selected_tick => 3,
    });
    my $mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'MF'});

    $transaction = BOM::Transaction->new({
        client        => $mf,
        contract      => $contract,
        purchase_date => $contract->date_start,
    });

    $error = BOM::Transaction::Validation->new({
            clients     => [$mf],
            transaction => $transaction
        })->_is_valid_to_buy($mf);

    unlike($error->{-message_to_client}, qr/Try out the Synthetic Indices/, 'MF client didnt got message about Synthetic Indices');

};

my $underlying_R50 = create_underlying('R_50');

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

# Create ticks
my $quote = 99.01;

my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch,
    underlying => 'R_50',
    quote      => $quote,
});

# Set up default arguments
my $args = {
    bet_type      => 'TICKHIGH',
    underlying    => 'R_50',
    selected_tick => 5,
    date_start    => $now,
    date_pricing  => $now,
    duration      => '5t',
    currency      => 'USD',
    payout        => 100,
};

subtest 'buy a bet', sub {
    #plan tests => 11;
    lives_ok {
        my $contract = produce_contract($args);

        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => $contract->ask_price,
            amount_type   => 'payout',
            source        => 19,
            purchase_date => $contract->date_start,
        });

        my $error = $txn->buy;
        is $error, undef, 'no error';

        my $sell_txn;

        my $sell_error = do {
            my $mocked           = Test::MockModule->new('BOM::Transaction');
            my $mocked_validator = Test::MockModule->new('BOM::Transaction::Validation');
            $mocked_validator->mock('_validate_trade_pricing_adjustment', sub { });
            $mocked->mock('price', sub { $contract->bid_price });
            $sell_txn = BOM::Transaction->new({
                client        => $cl,
                contract      => $contract,
                price         => $contract->ask_price,
                amount_type   => 'payout',
                source        => 23,
                purchase_date => $contract->date_start,
            });
            $sell_txn->sell;
        };

        isa_ok $sell_error, 'Error::Base', 'sellback not allowed error';

        for my $i (1 .. 5) {
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
                underlying => 'R_50',
                quote      => $quote,
                epoch      => $now->epoch + $i,
            });
            $quote += 0.01;
        }

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

        ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db highlowticks => $txn->transaction_id;

        subtest 'transaction row', sub {
            plan tests => 12;
            cmp_ok $trx->{id}, '>', 0, 'id';
            is $trx->{account_id}, $acc_usd->id, 'account_id';
            is $trx->{action_type}, 'buy', 'action_type';
            is $trx->{amount} + 0, -28.5, 'amount';
            is $trx->{balance_after} + 0, 5000 - 28.5, 'balance_after';
            is $trx->{financial_market_bet_id}, $fmb->{id}, 'financial_market_bet_id';
            is $trx->{payment_id},    undef,                  'payment_id';
            is $trx->{referrer_type}, 'financial_market_bet', 'referrer_type';
            is $trx->{remark},        undef,                  'remark';
            is $trx->{staff_loginid}, $cl->loginid, 'staff_loginid';
            is $trx->{source}, 19, 'source';
            cmp_ok +Date::Utility->new($trx->{transaction_time})->epoch, '<=', time, 'transaction_time';
        };

        subtest 'fmb row', sub {
            plan tests => 18;
            cmp_ok $fmb->{id}, '>', 0, 'id';
            is $fmb->{account_id}, $acc_usd->id, 'account_id';
            is $fmb->{bet_class}, 'highlowticks', 'bet_class';
            is $fmb->{bet_type},  'TICKHIGH',     'bet_type';
            is $fmb->{buy_price} + 0, 28.5, 'buy_price';
            is !$fmb->{expiry_daily}, !$contract->expiry_daily, 'expiry_daily';
            cmp_ok +Date::Utility->new($fmb->{expiry_time})->epoch, '>', time, 'expiry_time';
            is $fmb->{fixed_expiry}, undef, 'fixed_expiry';
            is !$fmb->{is_expired}, !0, 'is_expired';
            is !$fmb->{is_sold},    !0, 'is_sold';
            cmp_ok +Date::Utility->new($fmb->{purchase_time})->epoch, '<=', time, 'purchase_time';
            is $fmb->{sell_price}, undef, 'sell_price';
            is $fmb->{sell_time},  undef, 'sell_time';
            cmp_ok +Date::Utility->new($fmb->{settlement_time})->epoch, '>', time, 'settlement_time';
            like $fmb->{short_code}, qr/TICKHIGH/, 'short_code';
            cmp_ok +Date::Utility->new($fmb->{start_time})->epoch, '<=', time, 'start_time';
            is $fmb->{tick_count},        5,      'tick_count';
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
            is $qv1->{trade} + 0, 28.5, 'trade';
        };

        is $txn->contract_id,    $fmb->{id},            'txn->contract_id';
        is $txn->transaction_id, $trx->{id},            'txn->transaction_id';
        is $txn->balance_after,  $trx->{balance_after}, 'txn->balance_after';
        is $txn->execute_at_better_price, 0, 'txn->execute_at_better_price';
    }
    'survived';

};

done_testing;
