#!/usr/bin/perl

use strict;
use warnings;
use Test::MockTime qw/:all/;
use Test::MockModule;
use Test::More tests => 24;
use Test::NoWarnings ();    # no END block test
use Test::Exception;
use Guard;
use Crypt::NamedKeys;
use BOM::Platform::Client;
use BOM::System::Password;
use BOM::Platform::Client::Utility;
use BOM::Platform::Static::Config;

use Date::Utility;
use BOM::Product::Transaction;
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';

my $requestmod = Test::MockModule->new('BOM::Platform::Context::Request');
$requestmod->mock('session_cookie', sub { return bless({token => 1}, 'BOM::Platform::SessionCookie'); });

my $now       = Date::Utility->new;
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'currency',
    {
        symbol => $_,
        date   => Date::Utility->new,
    }) for qw(JPY USD JPY-USD);

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'randomindex',
    {
        symbol => 'R_50',
        date   => Date::Utility->new
    });

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_delta', {
        symbol => 'frxUSDJPY',
        recorded_date => $now,
    }
);
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
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
});

my $underlying      = BOM::Market::Underlying->new('R_50');
my $underlying_r100 = BOM::Market::Underlying->new('R_100');

sub db {
    return BOM::Database::ClientDB->new({
            broker_code => 'CR',
        })->db;
}

sub create_client {
    my $broker = shift;
    $broker ||= 'CR';

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

    top_up $cl, 'USD', 5000;

    isnt + ($acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';

    my $bal;
    is + ($bal = $acc_usd->balance + 0), 5000, 'USD balance is 5000 got: ' . $bal;
}
'client created and funded';

my ($trx, $fmb, $chld, $qv1, $qv2);

subtest 'buy a spread bet' => sub {
    # creating a new account so that I won't mess up current tests.
    my $new_client = create_client;
    top_up $new_client, 'USD', 5000;
    my $acc_usd = $new_client->find_account(query => [currency_code => 'USD'])->[0];
    local $ENV{REQUEST_STARTTIME} = time;
    my $c = produce_contract({
        underlying       => 'R_100',
        bet_type         => 'SPREADU',
        currency         => 'USD',
        amount_per_point => 2,
        stop_loss        => 10,
        stop_profit      => 20,
        entry_tick       => $tick_r100,
        current_tick     => $tick_r100,
        stop_type        => 'point',
    });
    my $txn = BOM::Product::Transaction->new({
        client   => $new_client,
        contract => $c,
        price    => 20.00,
        source   => 21,
    });

    ok !$txn->buy, 'buy spread bet without error';

    subtest 'transaction report', sub {
        plan tests => 11;
        note $txn->report;
        my $report = $txn->report;
        like $report, qr/\ATransaction Report:$/m,                                                    'header';
        like $report, qr/^\s*Client: \Q${\$new_client}\E$/m,                                          'client';
        like $report, qr/^\s*Contract: \Q${\$c->code}\E$/m,                                           'contract';
        like $report, qr/^\s*Price: \Q${\$txn->price}\E$/m,                                           'price';
        like $report, qr/^\s*Payout: \Q${\$txn->payout}\E$/m,                                         'payout';
        like $report, qr/^\s*Amount Type: \Q${\$txn->amount_type}\E$/m,                               'amount_type';
        like $report, qr/^\s*Comment: \Q${\$txn->comment}\E$/m,                                       'comment';
        like $report, qr/^\s*Staff: \Q${\$txn->staff}\E$/m,                                           'staff';
        like $report, qr/^\s*Transaction Parameters: \$VAR1 = \{$/m,                                  'transaction parameters';
        like $report, qr/^\s*Transaction ID: \Q${\$txn->transaction_id}\E$/m,                         'transaction id';
        like $report, qr/^\s*Purchase Date: \Q${\$txn->purchase_date->datetime_yyyymmdd_hhmmss}\E$/m, 'purchase date';
    };

    ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db spread_bet => $txn->transaction_id;

    # note explain $trx;

    subtest 'transaction row', sub {
        plan tests => 13;
        cmp_ok $trx->{id}, '>', 0, 'id';
        is $trx->{account_id}, $acc_usd->id, 'account_id';
        is $trx->{action_type}, 'buy', 'action_type';
        is $trx->{amount} + 0, -20, 'amount';
        is $trx->{balance_after} + 0, 5000 - 20, 'balance_after';
        is $trx->{financial_market_bet_id}, $fmb->{id}, 'financial_market_bet_id';
        is $trx->{payment_id},    undef,                  'payment_id';
        is $trx->{quantity},      1,                      'quantity';
        is $trx->{referrer_type}, 'financial_market_bet', 'referrer_type';
        is $trx->{remark},        undef,                  'remark';
        is $trx->{staff_loginid}, $new_client->loginid, 'staff_loginid';
        is $trx->{source}, 21, 'source';
        cmp_ok +Date::Utility->new($trx->{transaction_time})->epoch, '<=', time, 'transaction_time';
    };

    # note explain $fmb;

    subtest 'fmb row', sub {
        plan tests => 21;
        cmp_ok $fmb->{id}, '>', 0, 'id';
        is $fmb->{account_id}, $acc_usd->id, 'account_id';
        is $fmb->{bet_class}, 'spread_bet', 'bet_class';
        is $fmb->{bet_type},  'SPREADU',    'bet_type';
        is $fmb->{buy_price} + 0, 20, 'buy_price';
        note "time=" . time . ', expiry=' . Date::Utility->new($fmb->{expiry_time})->epoch;
        cmp_ok +Date::Utility->new($fmb->{expiry_time})->epoch, '>', time + 365 * 24 * 3600 - 60, 'expiry_time lower boundary';
        cmp_ok +Date::Utility->new($fmb->{expiry_time})->epoch, '<=', time + 365 * 24 * 3600, 'expiry_time upper boundary';
        is $fmb->{fixed_expiry}, undef, 'fixed_expiry';
        is !$fmb->{is_expired}, !0, 'is_expired';
        is !$fmb->{is_sold},    !0, 'is_sold';
        cmp_ok $fmb->{payout_price}, '==', 40, 'payout_price';
        cmp_ok +Date::Utility->new($fmb->{purchase_time})->epoch, '<=', time, 'purchase_time';
        like $fmb->{remark},   qr/amount_per_point/, 'remark';
        is $fmb->{sell_price}, undef,                'sell_price';
        is $fmb->{sell_time},  undef,                'sell_time';
        note "time=" . time . ', settlement=' . Date::Utility->new($fmb->{settlement_time})->epoch;
        cmp_ok +Date::Utility->new($fmb->{settlement_time})->epoch, '>', time + 365 * 24 * 3600 - 60, 'settlement_time lower boundary';
        cmp_ok +Date::Utility->new($fmb->{settlement_time})->epoch, '<=', time + 365 * 24 * 3600, 'settlement_time upper boundary';
        like $fmb->{short_code}, qr/SPREADU/, 'short_code';
        cmp_ok +Date::Utility->new($fmb->{start_time})->epoch, '<=', time, 'start_time';
        is $fmb->{tick_count},        undef,   'tick_count';
        is $fmb->{underlying_symbol}, 'R_100', 'underlying_symbol';
    };

    # note explain $chld;
    subtest 'chld row', sub {
        plan tests => 4;
        is $chld->{amount_per_point}, 2, 'amount_per_point is 2';
        is $chld->{financial_market_bet_id}, $fmb->{id}, 'financial_market_bet_id';
        is $chld->{stop_loss},   10, 'stop_loss is 10';
        is $chld->{stop_profit}, 20, 'stop_profit is 20';
    };

    local $ENV{REQUEST_STARTTIME} = time;
    $c = produce_contract({
        date_pricing     => time,
        underlying       => 'R_100',
        bet_type         => 'SPREADU',
        currency         => 'USD',
        amount_per_point => 2,
        stop_loss        => 10,
        stop_profit      => 20,
        entry_tick       => $tick_r100,
        current_tick     => $tick_r100,
        stop_type        => 'dollar',
    });
    $txn = BOM::Product::Transaction->new({
        client   => $new_client,
        contract => $c,
        price    => 10,
        source   => 22,
    });

    ok !$txn->buy, 'buy spread bet without error';

    subtest 'transaction report', sub {
        plan tests => 11;
        note $txn->report;
        my $report = $txn->report;
        like $report, qr/\ATransaction Report:$/m,                                                    'header';
        like $report, qr/^\s*Client: \Q${\$new_client}\E$/m,                                          'client';
        like $report, qr/^\s*Contract: \Q${\$c->code}\E$/m,                                           'contract';
        like $report, qr/^\s*Price: \Q${\$txn->price}\E$/m,                                           'price';
        like $report, qr/^\s*Payout: \Q${\$txn->payout}\E$/m,                                         'payout';
        like $report, qr/^\s*Amount Type: \Q${\$txn->amount_type}\E$/m,                               'amount_type';
        like $report, qr/^\s*Comment: \Q${\$txn->comment}\E$/m,                                       'comment';
        like $report, qr/^\s*Staff: \Q${\$txn->staff}\E$/m,                                           'staff';
        like $report, qr/^\s*Transaction Parameters: \$VAR1 = \{$/m,                                  'transaction parameters';
        like $report, qr/^\s*Transaction ID: \Q${\$txn->transaction_id}\E$/m,                         'transaction id';
        like $report, qr/^\s*Purchase Date: \Q${\$txn->purchase_date->datetime_yyyymmdd_hhmmss}\E$/m, 'purchase date';
    };

    ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db spread_bet => $txn->transaction_id;

    # note explain $trx;

    subtest 'transaction row', sub {
        plan tests => 13;
        cmp_ok $trx->{id}, '>', 0, 'id';
        is $trx->{account_id}, $acc_usd->id, 'account_id';
        is $trx->{action_type}, 'buy', 'action_type';
        is $trx->{amount} + 0, -10, 'amount';
        is $trx->{balance_after} + 0, 5000 - 30, 'balance_after';
        is $trx->{financial_market_bet_id}, $fmb->{id}, 'financial_market_bet_id';
        is $trx->{payment_id},    undef,                  'payment_id';
        is $trx->{quantity},      1,                      'quantity';
        is $trx->{referrer_type}, 'financial_market_bet', 'referrer_type';
        is $trx->{remark},        undef,                  'remark';
        is $trx->{staff_loginid}, $new_client->loginid, 'staff_loginid';
        is $trx->{source}, 22, 'source';
        cmp_ok +Date::Utility->new($trx->{transaction_time})->epoch, '<=', time, 'transaction_time';
    };

    # note explain $fmb;

    subtest 'fmb row', sub {
        plan tests => 21;
        cmp_ok $fmb->{id}, '>', 0, 'id';
        is $fmb->{account_id}, $acc_usd->id, 'account_id';
        is $fmb->{bet_class}, 'spread_bet', 'bet_class';
        is $fmb->{bet_type},  'SPREADU',    'bet_type';
        is $fmb->{buy_price} + 0, 10, 'buy_price';
        note "time=" . time . ', expiry=' . Date::Utility->new($fmb->{expiry_time})->epoch;
        cmp_ok +Date::Utility->new($fmb->{expiry_time})->epoch, '>', time + 365 * 24 * 3600 - 60, 'expiry_time lower boundary';
        cmp_ok +Date::Utility->new($fmb->{expiry_time})->epoch, '<=', time + 365 * 24 * 3600, 'expiry_time upper boundary';
        is $fmb->{fixed_expiry}, undef, 'fixed_expiry';
        is !$fmb->{is_expired}, !0, 'is_expired';
        is !$fmb->{is_sold},    !0, 'is_sold';
        cmp_ok $fmb->{payout_price}, '==', 20, 'payout_price';
        cmp_ok +Date::Utility->new($fmb->{purchase_time})->epoch, '<=', time, 'purchase_time';
        like $fmb->{remark},   qr/amount_per_point/, 'remark';
        is $fmb->{sell_price}, undef,                'sell_price';
        is $fmb->{sell_time},  undef,                'sell_time';
        note "time=" . time . ', settlement=' . Date::Utility->new($fmb->{settlement_time})->epoch;
        cmp_ok +Date::Utility->new($fmb->{settlement_time})->epoch, '>', time + 365 * 24 * 3600 - 60, 'settlement_time lower boundary';
        cmp_ok +Date::Utility->new($fmb->{settlement_time})->epoch, '<=', time + 365 * 24 * 3600, 'settlement_time upper boundary';
        like $fmb->{short_code}, qr/SPREADU/, 'short_code';
        cmp_ok +Date::Utility->new($fmb->{start_time})->epoch, '<=', time, 'start_time';
        is $fmb->{tick_count},        undef,   'tick_count';
        is $fmb->{underlying_symbol}, 'R_100', 'underlying_symbol';
    };

    # note explain $chld;
    subtest 'chld row', sub {
        plan tests => 4;
        is $chld->{amount_per_point}, 2, 'amount_per_point is 2';
        is $chld->{financial_market_bet_id}, $fmb->{id}, 'financial_market_bet_id';
        is $chld->{stop_loss},   10, 'stop_loss is 10';
        is $chld->{stop_profit}, 20, 'stop_profit is 20';
    };
};

subtest 'buy a bet', sub {
    plan tests => 11;
    lives_ok {
        local $ENV{REQUEST_STARTTIME} = time;    # fix race condition
        my $contract = produce_contract({
                underlying => $underlying,
                bet_type   => 'FLASHU',
                currency   => 'USD',
                payout     => 1000,
                duration   => '15m',
#        date_start   => $now->epoch + 1,
#        date_expiry  => $now->epoch + 300,
                current_tick => $tick,
                barrier      => 'S0P',
        });

        my $txn = BOM::Product::Transaction->new({
            client      => $cl,
            contract    => $contract,
            price       => 514.00,
            payout      => $contract->payout,
            amount_type => 'payout',
            source      => 19,
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
            like $report, qr/^\s*Comment: \Q${\$txn->comment}\E$/m,                                       'comment';
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
        local $ENV{REQUEST_STARTTIME} = time;    # fix race condition
        my $contract = produce_contract({
                underlying => $underlying,
                bet_type   => 'FLASHU',
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

        note 'bid price: ' . $contract->bid_price;

        my $txn = BOM::Product::Transaction->new({
            client      => $cl,
            contract    => $contract,
            contract_id => $fmb->{id},
            price       => $contract->bid_price + 5,
            source      => 23,
        });
        my $error = $txn->sell;
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
    plan tests => 8;
    lives_ok {
        top_up $cl, 'USD', 100 - $trx->{balance_after};
        $acc_usd->load;
        is $acc_usd->balance + 0, 100, 'USD balance is now 100';

        local $ENV{REQUEST_STARTTIME} = time;    # fix race condition
        my $contract = produce_contract({
            underlying   => $underlying,
            bet_type     => 'FLASHU',
            currency     => 'USD',
            stake        => 100.01,
            duration     => '15m',
            current_tick => $tick,
            barrier      => 'S0P',
        });

        my $txn = BOM::Product::Transaction->new({
            client      => $cl,
            contract    => $contract,
            price       => 100.01,
            payout      => $contract->payout,
            amount_type => 'stake',
        });
        my $error = $txn->buy;
        SKIP: {
            skip 'no error', 5
                unless isa_ok $error, 'Error::Base';

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
                    bet_type     => 'FLASHU',
                    currency     => 'USD',
                    stake        => 100,
                    date_start   => $now->epoch - 100,
                    date_expiry  => $now->epoch - 50,
                    current_tick => $tick,
                    entry_tick   => $old_tick1,
                    exit_tick    => $old_tick2,
                    barrier      => 'S0P',
                });

                my $txn = BOM::Product::Transaction->new({
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

                $txn = BOM::Product::Transaction->new({
                    client      => $cl,
                    contract    => $contract,
                    price       => 100.01,
                    payout      => $contract->payout,
                    amount_type => 'stake',
                    source      => 31,
                });
                $error = $txn->buy;

                is $error, undef, 'no error';

                # check if the expired contract has been sold
                ($trx, $fmb, $chld, $qv1, $qv2, my $trx2) = get_transaction_from_db higher_lower_bet => $txn_id_buy_expired_contract;

                is $fmb->{is_sold},    1,     'previously unsold contract is now sold';
                is $fmb->{is_expired}, 1,     '... and expired';
                is $trx->{source},     undef, 'source';
                is $trx2->{source},    31,    'source';

                # now check the buy transaction itself
                ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db higher_lower_bet => $txn->transaction_id;

                is $trx->{source}, 31, 'source';
                is $txn->contract_id, $fmb->{id}, 'txn->contract_id';
                cmp_ok $txn->contract_id, '>', 0, 'txn->contract_id > 0';
                is $txn->transaction_id, $trx->{id}, 'txn->transaction_id';
                cmp_ok $txn->transaction_id, '>', 0, 'txn->transaction_id > 0';
                is $txn->balance_after, $trx->{balance_after}, 'txn->balance_after';
                is $txn->balance_after + 0, 100 + 100 - 100.01,
                    'txn->balance_after == 99.99 (100 (balance) + 100 (unsold bet) - 100.01 (bought bet))';
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

        local $ENV{REQUEST_STARTTIME} = time;    # fix race condition
        my $contract = produce_contract({
            underlying   => $underlying,
            bet_type     => 'FLASHU',
            currency     => 'USD',
            stake        => 100.00,
            duration     => '15m',
            current_tick => $tick,
            barrier      => 'S0P',
        });

        my $txn = BOM::Product::Transaction->new({
            client      => $cl,
            contract    => $contract,
            price       => 100.00,
            payout      => $contract->payout,
            amount_type => 'stake',
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
    plan tests => 9;
    lives_ok {
        $acc_usd->load;
        unless ($acc_usd->balance + 0 == 100) {
            top_up $cl, 'USD', 100 - $acc_usd->balance;
            $acc_usd->load;
        }
        is $acc_usd->balance + 0, 100, 'USD balance is now 100';

        local $ENV{REQUEST_STARTTIME} = time;    # fix race condition
        my $contract = produce_contract({
            underlying   => $underlying,
            bet_type     => 'FLASHU',
            currency     => 'USD',
            stake        => 100.00,
            duration     => '15m',
            current_tick => $tick,
            barrier      => 'S0P',
        });

        my $txn = BOM::Product::Transaction->new({
            client      => $cl,
            contract    => $contract,
            price       => 100.00,
            payout      => $contract->payout,
            amount_type => 'stake',
        });

        my $error = do {
            my $mock_client = Test::MockModule->new('BOM::Platform::Client');
            $mock_client->mock(get_limit_for_account_balance => sub { note "mocked Client->get_limit_for_account_balance returning 99.99"; 99.99 });

            $txn->buy;
        };
        SKIP: {
            skip 'no error', 6
                unless isa_ok $error, 'Error::Base';

            is $error->get_type, 'AccountBalanceExceedsLimit', 'error is AccountBalanceExceedsLimit';

            like $error->{-message_to_client}, qr/balance is too high \(USD100\.00\)/, 'message_to_client contains balance';
            like $error->{-message_to_client}, qr/maximum account balance is 99\.99/,  'message_to_client contains limit';

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

        local $ENV{REQUEST_STARTTIME} = time;    # fix race condition
        my $contract = produce_contract({
            underlying   => $underlying,
            bet_type     => 'FLASHU',
            currency     => 'USD',
            stake        => 100.00,
            duration     => '15m',
            current_tick => $tick,
            barrier      => 'S0P',
        });

        my $txn = BOM::Product::Transaction->new({
            client      => $cl,
            contract    => $contract,
            price       => 100.00,
            payout      => $contract->payout,
            amount_type => 'stake',
        });

        my $error = do {
            my $mock_client = Test::MockModule->new('BOM::Platform::Client');
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
    plan tests => 11;
    lives_ok {
        my $cl = create_client;

        top_up $cl, 'USD', 100;

        isnt + (my $acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';

        my $bal;
        is + ($bal = $acc_usd->balance + 0), 100, 'USD balance is 100 got: ' . $bal;

        local $ENV{REQUEST_STARTTIME} = time;    # fix race condition
        my $contract = produce_contract({
            underlying   => $underlying,
            bet_type     => 'FLASHU',
            currency     => 'USD',
            stake        => 1.00,
            duration     => '15m',
            current_tick => $tick,
            barrier      => 'S0P',
        });

        my $txn = BOM::Product::Transaction->new({
            client      => $cl,
            contract    => $contract,
            price       => 1.00,
            payout      => $contract->payout,
            amount_type => 'stake',
        });

        my $error = do {
            my $mock_client = Test::MockModule->new('BOM::Platform::Client');
            $mock_client->mock(get_limit_for_open_positions => sub { note "mocked Client->get_limit_for_open_positions returning 2"; 2 });

            is +BOM::Product::Transaction->new({
                    client      => $cl,
                    contract    => $contract,
                    price       => 1.00,
                    payout      => $contract->payout,
                    amount_type => 'stake',
                })->buy, undef, '1st bet bought';

            is +BOM::Product::Transaction->new({
                    client      => $cl,
                    contract    => $contract,
                    price       => 1.00,
                    payout      => $contract->payout,
                    amount_type => 'stake',
                })->buy, undef, '2nd bet bought';

            $txn->buy;
        };
        SKIP: {
            skip 'no error', 5
                unless isa_ok $error, 'Error::Base';

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
    plan tests => 16;
    lives_ok {
        my $cl = create_client;

        top_up $cl, 'USD', 100;

        isnt + (my $acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';

        my $bal;
        is + ($bal = $acc_usd->balance + 0), 100, 'USD balance is 100 got: ' . $bal;

        local $ENV{REQUEST_STARTTIME} = time;    # fix race condition
        my $contract = produce_contract({
            underlying   => $underlying,
            bet_type     => 'FLASHU',
            currency     => 'USD',
            stake        => 1.00,
            duration     => '15m',
            current_tick => $tick,
            barrier      => 'S0P',
        });

        my $txn = BOM::Product::Transaction->new({
            client      => $cl,
            contract    => $contract,
            price       => 1.00,
            payout      => $contract->payout,
            amount_type => 'stake',
        });

        my $txn_id_buy_expired_contract;
        my $error = do {
            my $mock_client = Test::MockModule->new('BOM::Platform::Client');
            $mock_client->mock(get_limit_for_open_positions => sub { note "mocked Client->get_limit_for_open_positions returning 2"; 2 });

            is +BOM::Product::Transaction->new({
                    client      => $cl,
                    contract    => $contract,
                    price       => 1.00,
                    payout      => $contract->payout,
                    amount_type => 'stake',
                })->buy, undef, '1st bet bought';

            my $contract_expired = produce_contract({
                underlying   => $underlying,
                bet_type     => 'FLASHU',
                currency     => 'USD',
                stake        => 1,
                date_start   => $now->epoch - 100,
                date_expiry  => $now->epoch - 50,
                current_tick => $tick,
                entry_tick   => $old_tick1,
                exit_tick    => $old_tick2,
                barrier      => 'S0P',
            });

            my $exp_txn = BOM::Product::Transaction->new({
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
            # Hence, the buy should succeed selling the expired bet.

            $txn_id_buy_expired_contract = $exp_txn->transaction_id;
            ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db higher_lower_bet => $txn_id_buy_expired_contract;
            is $fmb->{is_sold}, 0, 'have expired but unsold contract in DB';

            $txn->buy;
        };

        is $error, undef, 'no error';

        # check if the expired contract has been sold
        ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db higher_lower_bet => $txn_id_buy_expired_contract;

        is $fmb->{is_sold},    1, 'previously unsold contract is now sold';
        is $fmb->{is_expired}, 1, '... and expired';

        # now check the buy transaction itself
        ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db higher_lower_bet => $txn->transaction_id;

        is $txn->contract_id, $fmb->{id}, 'txn->contract_id';
        cmp_ok $txn->contract_id, '>', 0, 'txn->contract_id > 0';
        is $txn->transaction_id, $trx->{id}, 'txn->transaction_id';
        cmp_ok $txn->transaction_id, '>', 0, 'txn->transaction_id > 0';
        is $txn->balance_after, $trx->{balance_after}, 'txn->balance_after';
        is $txn->balance_after + 0, 98, 'txn->balance_after == 98';
    }
    'survived';
};

subtest 'max_payout_open_bets validation', sub {
    plan tests => 24;
    lives_ok {
        my $cl = create_client;

        top_up $cl, 'USD', 100;

        isnt + (my $acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';

        my $bal;
        is + ($bal = $acc_usd->balance + 0), 100, 'USD balance is 100 got: ' . $bal;

        local $ENV{REQUEST_STARTTIME} = time;    # fix race condition
        my $contract = produce_contract({
            underlying   => $underlying,
            bet_type     => 'FLASHU',
            currency     => 'USD',
            payout       => 10.00,
            duration     => '15m',
            current_tick => $tick,
            barrier      => 'S0P',
        });

        my $txn = BOM::Product::Transaction->new({
            client      => $cl,
            contract    => $contract,
            price       => 5.20,
            payout      => $contract->payout,
            amount_type => 'payout',
        });

        my $error = do {
            my $mock_client = Test::MockModule->new('BOM::Platform::Client');
            $mock_client->mock(get_limit_for_payout => sub { note "mocked Client->get_limit_for_payout returning 29.99"; 29.99 });

            is +BOM::Product::Transaction->new({
                    client      => $cl,
                    contract    => $contract,
                    price       => 5.20,
                    payout      => $contract->payout,
                    amount_type => 'payout',
                })->buy, undef, '1st bet bought';

            is +BOM::Product::Transaction->new({
                    client      => $cl,
                    contract    => $contract,
                    price       => 5.20,
                    payout      => $contract->payout,
                    amount_type => 'payout',
                })->buy, undef, '2nd bet bought';

            $txn->buy;
        };
        SKIP: {
            skip 'no error', 5
                unless isa_ok $error, 'Error::Base';

            is $error->get_type, 'OpenPositionPayoutLimit', 'error is OpenPositionPayoutLimit';

            like $error->{-message_to_client}, qr/aggregate payouts of contracts on your account cannot exceed USD29\.99/,
                'message_to_client contains balance';

            is $txn->contract_id,    undef, 'txn->contract_id';
            is $txn->transaction_id, undef, 'txn->transaction_id';
            is $txn->balance_after,  undef, 'txn->balance_after';
        }

        # retry with a slightly higher limit should succeed
        $error = do {
            my $mock_client = Test::MockModule->new('BOM::Platform::Client');
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

        local $ENV{REQUEST_STARTTIME} = time;    # fix race condition
        my $contract = produce_contract({
            underlying   => 'frxUSDJPY',
            bet_type     => 'FLASHU',
            currency     => 'USD',
            payout       => 10.00,
            duration     => '6h',
            current_tick => $usdjpy_tick,
            barrier      => 'S0P',
        });

        my $txn = BOM::Product::Transaction->new({
            client      => $cl,
            contract    => $contract,
            price       => 5.37,
            payout      => $contract->payout,
            amount_type => 'payout',
        });

        my $error = do {
            note "Set max_payout_open_positions for MF Client => 29.99";
            BOM::Platform::Static::Config::quants->{client_limits}->{max_payout_open_positions}->{maltainvest}->{USD} = 29.99;

            is +BOM::Product::Transaction->new({
                    client      => $cl,
                    contract    => $contract,
                    price       => 5.37,
                    payout      => $contract->payout,
                    amount_type => 'payout',
                })->buy, undef, '1st bet bought';

            is +BOM::Product::Transaction->new({
                    client      => $cl,
                    contract    => $contract,
                    price       => 5.37,
                    payout      => $contract->payout,
                    amount_type => 'payout',
                })->buy, undef, '2nd bet bought';

            $txn->buy;
        };
        SKIP: {
            skip 'no error', 5
                unless isa_ok $error, 'Error::Base';

            is $error->get_type, 'OpenPositionPayoutLimit', 'error is OpenPositionPayoutLimit';

            like $error->{-message_to_client}, qr/aggregate payouts of contracts on your account cannot exceed USD29\.99/,
                'message_to_client contains balance';

            is $txn->contract_id,    undef, 'txn->contract_id';
            is $txn->transaction_id, undef, 'txn->transaction_id';
            is $txn->balance_after,  undef, 'txn->balance_after';
        }

        # retry with a slightly higher limit should succeed
        $error = do {
            my $mock_client = Test::MockModule->new('BOM::Platform::Client');
            $mock_client->mock(get_limit_for_payout => sub { note "mocked Client->get_limit_for_payout returning 30.00"; 30.00 });

            $txn->buy;
        };

        is $error, undef, 'no error';
    }
    'survived';
};

subtest 'max_payout_open_bets validation: selling bets on the way', sub {
    plan tests => 11;
    lives_ok {
        my $cl = create_client;

        top_up $cl, 'USD', 100;

        isnt + (my $acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';

        my $bal;
        is + ($bal = $acc_usd->balance + 0), 100, 'free_gift USD balance is 100 got: ' . $bal;

        local $ENV{REQUEST_STARTTIME} = time;    # fix race condition
        my $contract = produce_contract({
            underlying   => $underlying,
            bet_type     => 'FLASHU',
            currency     => 'USD',
            payout       => 10.00,
            duration     => '15m',
            current_tick => $tick,
            barrier      => 'S0P',
        });

        my $txn = BOM::Product::Transaction->new({
            client      => $cl,
            contract    => $contract,
            price       => 5.20,
            payout      => $contract->payout,
            amount_type => 'payout',
        });

        my $txn_id_buy_expired_contract;
        my $error = do {
            my $mock_client = Test::MockModule->new('BOM::Platform::Client');
            $mock_client->mock(get_limit_for_payout => sub { note "mocked Client->get_limit_for_payout returning 29.99"; 29.99 });

            is +BOM::Product::Transaction->new({
                    client      => $cl,
                    contract    => $contract,
                    price       => 5.20,
                    payout      => $contract->payout,
                    amount_type => 'payout',
                })->buy, undef, '1st bet bought';

            my $contract_expired = produce_contract({
                underlying   => $underlying,
                bet_type     => 'FLASHU',
                currency     => 'USD',
                payout       => 10.00,
                date_start   => $now->epoch - 100,
                date_expiry  => $now->epoch - 50,
                current_tick => $tick,
                entry_tick   => $old_tick1,
                exit_tick    => $old_tick2,
                barrier      => 'S0P',
            });

            my $exp_txn = BOM::Product::Transaction->new({
                client        => $cl,
                contract      => $contract_expired,
                price         => 5.20,
                payout        => $contract->payout,
                amount_type   => 'payout',
                purchase_date => $now->epoch - 101,
            });

            is $exp_txn->buy(skip_validation => 1), undef, '2nd, expired bet bought';

            # Now we have 2 open bets. The net payout of them is 20.
            # One of them is expired.
            # Hence, the buy should succeed selling the expired bet.

            $txn_id_buy_expired_contract = $exp_txn->transaction_id;
            ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db higher_lower_bet => $txn_id_buy_expired_contract;
            is $fmb->{is_sold}, 0, 'have expired but unsold contract in DB';

            $txn->buy;
        };

        is $error, undef, 'no error';

        # check if the expired contract has been sold
        ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db higher_lower_bet => $txn_id_buy_expired_contract;

        is $fmb->{is_sold},    1, 'previously unsold contract is now sold';
        is $fmb->{is_expired}, 1, '... and expired';

        cmp_ok $txn->contract_id,    '>', 0, 'txn->contract_id > 0';
        cmp_ok $txn->transaction_id, '>', 0, 'txn->transaction_id > 0';
    }
    'survived';
};

subtest 'max_payout_per_symbol_and_bet_type validation', sub {
    plan tests => 12;
    lives_ok {
        my $cl = create_client;

        top_up $cl, 'USD', 100;

        isnt + (my $acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';

        my $bal;
        is + ($bal = $acc_usd->balance + 0), 100, 'USD balance is 100 got: ' . $bal;

        local $ENV{REQUEST_STARTTIME} = time;    # fix race condition
        my $contract = produce_contract({
            underlying   => $underlying,
            bet_type     => 'FLASHU',
            currency     => 'USD',
            payout       => 10.00,
            duration     => '15m',
            current_tick => $tick,
            barrier      => 'S0P',
        });

        my $txn = BOM::Product::Transaction->new({
            client      => $cl,
            contract    => $contract,
            price       => 5.20,
            payout      => $contract->payout,
            amount_type => 'payout',
        });

        my $error = do {
            note "change quants->{client_limits}->{payout_per_symbol_and_bet_type_limit->{USD}} to 29.99";
            BOM::Platform::Static::Config::quants->{client_limits}->{payout_per_symbol_and_bet_type_limit}->{USD} = 29.99;

            is +BOM::Product::Transaction->new({
                    client      => $cl,
                    contract    => $contract,
                    price       => 5.20,
                    payout      => $contract->payout,
                    amount_type => 'payout',
                })->buy, undef, '1st bet bought';

            is +BOM::Product::Transaction->new({
                    client      => $cl,
                    contract    => $contract,
                    price       => 5.20,
                    payout      => $contract->payout,
                    amount_type => 'payout',
                })->buy, undef, '2nd bet bought';

            $txn->buy;
        };
        SKIP: {
            skip 'no error', 4
                unless isa_ok $error, 'Error::Base';

            is $error->get_type, 'PotentialPayoutLimitForSameContractExceeded', 'error is PotentialPayoutLimitForSameContractExceeded';

            is $txn->contract_id,    undef, 'txn->contract_id';
            is $txn->transaction_id, undef, 'txn->transaction_id';
            is $txn->balance_after,  undef, 'txn->balance_after';
        }

        # retry with a slightly higher limit should succeed
        $error = do {
            note "change quants->{client_limits}->{payout_per_symbol_and_bet_type_limit}->{USD} to 30";
            BOM::Platform::Static::Config::quants->{client_limits}->{payout_per_symbol_and_bet_type_limit}->{USD} = 30;

            my $contract_r100 = produce_contract({
                underlying   => $underlying_r100,
                bet_type     => 'FLASHU',
                currency     => 'USD',
                payout       => 10.00,
                duration     => '15m',
                current_tick => $tick_r100,
                barrier      => 'S0P',
            });

            is +BOM::Product::Transaction->new({
                    client      => $cl,
                    contract    => $contract_r100,
                    price       => 5.20,
                    payout      => $contract_r100->payout,
                    amount_type => 'payout',
                })->buy, undef, 'R_100 contract bought -- should not interfere R_50 trading';

            $txn->buy;
        };

        is $error, undef, 'no error';
    }
    'survived';
};

subtest 'max_payout_per_symbol_and_bet_type validation: selling bets on the way', sub {
    plan tests => 11;
    lives_ok {
        my $cl = create_client;

        top_up $cl, 'USD', 100;

        isnt + (my $acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';

        my $bal;
        is + ($bal = $acc_usd->balance + 0), 100, 'free_gift USD balance is 100 got: ' . $bal;

        local $ENV{REQUEST_STARTTIME} = time;    # fix race condition
        my $contract = produce_contract({
            underlying   => $underlying,
            bet_type     => 'FLASHU',
            currency     => 'USD',
            payout       => 10.00,
            duration     => '15m',
            current_tick => $tick,
            barrier      => 'S0P',
        });

        my $txn = BOM::Product::Transaction->new({
            client      => $cl,
            contract    => $contract,
            price       => 5.20,
            payout      => $contract->payout,
            amount_type => 'payout',
        });

        my $txn_id_buy_expired_contract;
        my $error = do {
            note "change quants->{client_limits}->{payout_per_symbol_and_bet_type_limit}->{USD} to 29.99";
            BOM::Platform::Static::Config::quants->{client_limits}->{payout_per_symbol_and_bet_type_limit}->{USD} = 29.99;

            is +BOM::Product::Transaction->new({
                    client      => $cl,
                    contract    => $contract,
                    price       => 5.20,
                    payout      => $contract->payout,
                    amount_type => 'payout',
                })->buy, undef, '1st bet bought';

            my $contract_expired = produce_contract({
                underlying   => $underlying,
                bet_type     => 'FLASHU',
                currency     => 'USD',
                payout       => 10.00,
                date_start   => $now->epoch - 100,
                date_expiry  => $now->epoch - 50,
                current_tick => $tick,
                entry_tick   => $old_tick1,
                exit_tick    => $old_tick2,
                barrier      => 'S0P',
            });

            my $exp_txn = BOM::Product::Transaction->new({
                client        => $cl,
                contract      => $contract_expired,
                price         => 5.20,
                payout        => $contract->payout,
                amount_type   => 'payout',
                purchase_date => $now->epoch - 101,
            });

            is $exp_txn->buy(skip_validation => 1), undef, '2nd, expired bet bought';

            # Now we have 2 open bets. The net payout of them is 20.
            # One of them is expired.
            # Hence, the buy should succeed selling the expired bet.

            $txn_id_buy_expired_contract = $exp_txn->transaction_id;
            ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db higher_lower_bet => $txn_id_buy_expired_contract;
            is $fmb->{is_sold}, 0, 'have expired but unsold contract in DB';

            $txn->buy;
        };

        is $error, undef, 'no error';

        # check if the expired contract has been sold
        ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db higher_lower_bet => $txn_id_buy_expired_contract;

        is $fmb->{is_sold},    1, 'previously unsold contract is now sold';
        is $fmb->{is_expired}, 1, '... and expired';

        cmp_ok $txn->contract_id,    '>', 0, 'txn->contract_id > 0';
        cmp_ok $txn->transaction_id, '>', 0, 'txn->transaction_id > 0';
    }
    'survived';
};

subtest 'max_turnover validation', sub {
    plan tests => 21;
    lives_ok {
        my $cl = create_client;

        top_up $cl, 'USD', 100;

        isnt + (my $acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';

        my $bal;
        is + ($bal = $acc_usd->balance + 0), 100, 'USD balance is 100 got: ' . $bal;

        local $ENV{REQUEST_STARTTIME} = time;    # fix race condition
        my $contract_up = produce_contract({
            underlying   => $underlying,
            bet_type     => 'FLASHU',
            currency     => 'USD',
            payout       => 10.00,
            duration     => '15m',
            current_tick => $tick,
            barrier      => 'S0P',
        });

        my $contract_down = produce_contract({
            underlying   => $underlying_r100,
            bet_type     => 'FLASHD',
            currency     => 'USD',
            payout       => 10.00,
            duration     => '15m',
            current_tick => $tick,
            barrier      => 'S0P',
        });

        my $txn = BOM::Product::Transaction->new({
            client      => $cl,
            contract    => $contract_up,
            price       => 5.20,
            payout      => $contract_up->payout,
            amount_type => 'payout',
        });

        my $error = do {
            my $mock_client = Test::MockModule->new('BOM::Platform::Client');
            $mock_client->mock(get_limit_for_daily_turnover =>
                    sub { note "mocked Client->get_limit_for_daily_turnover returning " . (3 * 5.20 - .01); 3 * 5.20 - .01 });
            $mock_client->mock(client_fully_authenticated => sub { note "mocked Client->client_fully_authenticated returning false"; undef });

            is +BOM::Product::Transaction->new({
                    client      => $cl,
                    contract    => $contract_up,
                    price       => 5.20,
                    payout      => $contract_up->payout,
                    amount_type => 'payout',
                })->buy, undef, 'FLASHU bet bought';

            is +BOM::Product::Transaction->new({
                    client      => $cl,
                    contract    => $contract_down,
                    price       => 5.20,
                    payout      => $contract_down->payout,
                    amount_type => 'payout',
                })->buy, undef, 'FLASHD bet bought';

            $txn->buy;
        };
        SKIP: {
            skip 'no error', 6
                unless isa_ok $error, 'Error::Base';

            is $error->get_type, 'DailyTurnoverLimitExceeded', 'error is DailyTurnoverLimitExceeded';

            like $error->{-message_to_client}, qr/daily turnover limit of USD15\.59/, 'message_to_client contains limit';
            like $error->{-message_to_client}, qr/If you wish to raise these limits, please authenticate your account/,
                'message_to_client contains authentication notice';

            is $txn->contract_id,    undef, 'txn->contract_id';
            is $txn->transaction_id, undef, 'txn->transaction_id';
            is $txn->balance_after,  undef, 'txn->balance_after';
        }

        $error = do {
            my $mock_client = Test::MockModule->new('BOM::Platform::Client');
            $mock_client->mock(get_limit_for_daily_turnover =>
                    sub { note "mocked Client->get_limit_for_daily_turnover returning " . (3 * 5.20 - .01); 3 * 5.20 - .01 });
            $mock_client->mock(client_fully_authenticated => sub { note "mocked Client->client_fully_authenticated returning true"; 1 });

            $txn->buy;
        };
        SKIP: {
            skip 'no error', 6
                unless isa_ok $error, 'Error::Base';

            is $error->get_type, 'DailyTurnoverLimitExceeded', 'error is DailyTurnoverLimitExceeded';

            like $error->{-message_to_client}, qr/daily turnover limit of USD15\.59/, 'message_to_client contains limit';
            unlike $error->{-message_to_client}, qr/If you wish to raise these limits, please authenticate your account/,
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
                            bet_type          => 'FLASHU',
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

            my $mock_client = Test::MockModule->new('BOM::Platform::Client');
            $mock_client->mock(
                get_limit_for_daily_turnover => sub { note "mocked Client->get_limit_for_daily_turnover returning " . (3 * 5.20); 3 * 5.20 });

            $txn->buy;
        };

        is $error, undef, 'no error';
    }
    'survived';
};

subtest 'max_7day_turnover validation', sub {
    plan tests => 12;
    lives_ok {
        my $cl = create_client;

        top_up $cl, 'USD', 100;

        isnt + (my $acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';

        my $bal;
        is + ($bal = $acc_usd->balance + 0), 100, 'USD balance is 100 got: ' . $bal;

        local $ENV{REQUEST_STARTTIME} = time;    # fix race condition
        my $contract_up = produce_contract({
            underlying   => $underlying,
            bet_type     => 'FLASHU',
            currency     => 'USD',
            payout       => 10.00,
            duration     => '15m',
            current_tick => $tick,
            barrier      => 'S0P',
        });

        my $contract_down = produce_contract({
            underlying   => $underlying_r100,
            bet_type     => 'FLASHD',
            currency     => 'USD',
            payout       => 10.00,
            duration     => '15m',
            current_tick => $tick,
            barrier      => 'S0P',
        });

        my $txn = BOM::Product::Transaction->new({
            client      => $cl,
            contract    => $contract_up,
            price       => 5.20,
            payout      => $contract_up->payout,
            amount_type => 'payout',
        });

        my $error = do {
            my $mock_client = Test::MockModule->new('BOM::Platform::Client');
            $mock_client->mock(
                get_limit_for_7day_turnover => sub { note "mocked Client->get_limit_for_7day_turnover returning " . (3 * 5.20 - .01); 3 * 5.20 - .01 }
            );

            is +BOM::Product::Transaction->new({
                    client      => $cl,
                    contract    => $contract_up,
                    price       => 5.20,
                    payout      => $contract_up->payout,
                    amount_type => 'payout',
                })->buy, undef, 'FLASHU bet bought';

            is +BOM::Product::Transaction->new({
                    client      => $cl,
                    contract    => $contract_down,
                    price       => 5.20,
                    payout      => $contract_down->payout,
                    amount_type => 'payout',
                })->buy, undef, 'FLASHD bet bought';

            $txn->buy;
        };
        SKIP: {
            skip 'no error', 5
                unless isa_ok $error, 'Error::Base';

            is $error->get_type, '7DayTurnoverLimitExceeded', 'error is 7DayTurnoverLimitExceeded';

            like $error->{-message_to_client}, qr/7-day turnover limit of USD15\.59/, 'message_to_client contains limit';

            is $txn->contract_id,    undef, 'txn->contract_id';
            is $txn->transaction_id, undef, 'txn->transaction_id';
            is $txn->balance_after,  undef, 'txn->balance_after';
        }

        # retry with a slightly higher limit should succeed
        $error = do {
            my $mock_client = Test::MockModule->new('BOM::Platform::Client');
            $mock_client->mock(
                get_limit_for_7day_turnover => sub { note "mocked Client->get_limit_for_7day_turnover returning " . (3 * 5.20); 3 * 5.20 });

            $txn->buy;
        };

        is $error, undef, 'no error';
    }
    'survived';
};

subtest 'max_30day_turnover validation', sub {
    plan tests => 12;
    lives_ok {
        my $cl = create_client;

        top_up $cl, 'USD', 100;

        isnt + (my $acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';

        my $bal;
        is + ($bal = $acc_usd->balance + 0), 100, 'USD balance is 100 got: ' . $bal;

        local $ENV{REQUEST_STARTTIME} = time;    # fix race condition
        my $contract_up = produce_contract({
            underlying   => $underlying,
            bet_type     => 'FLASHU',
            currency     => 'USD',
            payout       => 10.00,
            duration     => '15m',
            current_tick => $tick,
            barrier      => 'S0P',
        });

        my $contract_down = produce_contract({
            underlying   => $underlying_r100,
            bet_type     => 'FLASHD',
            currency     => 'USD',
            payout       => 10.00,
            duration     => '15m',
            current_tick => $tick,
            barrier      => 'S0P',
        });

        my $txn = BOM::Product::Transaction->new({
            client      => $cl,
            contract    => $contract_up,
            price       => 5.20,
            payout      => $contract_up->payout,
            amount_type => 'payout',
        });

        my $error = do {
            my $mock_client = Test::MockModule->new('BOM::Platform::Client');
            $mock_client->mock(get_limit_for_30day_turnover =>
                    sub { note "mocked Client->get_limit_for_30day_turnover returning " . (3 * 5.20 - .01); 3 * 5.20 - .01 });

            is +BOM::Product::Transaction->new({
                    client      => $cl,
                    contract    => $contract_up,
                    price       => 5.20,
                    payout      => $contract_up->payout,
                    amount_type => 'payout',
                })->buy, undef, 'FLASHU bet bought';

            is +BOM::Product::Transaction->new({
                    client      => $cl,
                    contract    => $contract_down,
                    price       => 5.20,
                    payout      => $contract_down->payout,
                    amount_type => 'payout',
                })->buy, undef, 'FLASHD bet bought';

            $txn->buy;
        };
        SKIP: {
            skip 'no error', 5
                unless isa_ok $error, 'Error::Base';

            is $error->get_type, '30DayTurnoverLimitExceeded', 'error is 30DayTurnoverLimitExceeded';

            like $error->{-message_to_client}, qr/30-day turnover limit of USD15\.59/, 'message_to_client contains limit';

            is $txn->contract_id,    undef, 'txn->contract_id';
            is $txn->transaction_id, undef, 'txn->transaction_id';
            is $txn->balance_after,  undef, 'txn->balance_after';
        }

        # retry with a slightly higher limit should succeed
        $error = do {
            my $mock_client = Test::MockModule->new('BOM::Platform::Client');
            $mock_client->mock(
                get_limit_for_30day_turnover => sub { note "mocked Client->get_limit_for_30day_turnover returning " . (3 * 5.20); 3 * 5.20 });

            $txn->buy;
        };

        is $error, undef, 'no error';
    }
    'survived';
};

subtest 'max_losses validation', sub {
    plan tests => 14;
    lives_ok {
        my $cl = create_client;

        top_up $cl, 'USD', 100;

        isnt + (my $acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';

        my $bal;
        is + ($bal = $acc_usd->balance + 0), 100, 'USD balance is 100 got: ' . $bal;

        local $ENV{REQUEST_STARTTIME} = time;    # fix race condition
        my $contract_up = produce_contract({
            underlying   => $underlying,
            bet_type     => 'FLASHU',
            currency     => 'USD',
            payout       => 10.00,
            duration     => '15m',
            current_tick => $tick,
            barrier      => 'S0P',
            date_pricing => Date::Utility->new(time + 10),
        });

        my $contract_down = produce_contract({
            underlying   => $underlying_r100,
            bet_type     => 'FLASHD',
            currency     => 'USD',
            payout       => 10.00,
            duration     => '15m',
            current_tick => $tick,
            barrier      => 'S0P',
            date_pricing => Date::Utility->new(time + 10),
        });

        my $txn = BOM::Product::Transaction->new({
            client      => $cl,
            contract    => $contract_up,
            price       => 5.20,
            payout      => $contract_up->payout,
            amount_type => 'payout',
        });

        my $error = do {
            my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
            $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

            my $mock_transaction = Test::MockModule->new('BOM::Product::Transaction');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_transaction->mock(
                _validate_trade_pricing_adjustment => sub { note "mocked Transaction->_validate_trade_pricing_adjustment returning nothing"; () });
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning 'TEST'"; 'TEST' });
            my $mock_client = Test::MockModule->new('BOM::Platform::Client');
            $mock_client->mock(
                get_limit_for_daily_losses => sub { note "mocked Client->get_limit_for_daily_losses returning " . (3 * 5.20 - .01); 3 * 5.20 - .01 });

            my $t = BOM::Product::Transaction->new({
                client      => $cl,
                contract    => $contract_up,
                price       => 5.20,
                payout      => $contract_up->payout,
                amount_type => 'payout',
            });
            is $t->buy, undef, 'FLASHU bet bought';
            $t = BOM::Product::Transaction->new({
                client      => $cl,
                contract    => $contract_up,
                contract_id => $t->contract_id,
                price       => 0,
            });
            is $t->sell(skip_validation => 1), undef, 'FLASHU bet sold';

            $t = BOM::Product::Transaction->new({
                client      => $cl,
                contract    => $contract_down,
                price       => 5.20,
                payout      => $contract_down->payout,
                amount_type => 'payout',
            });
            is $t->buy, undef, 'FLASHD bet bought';
            $t = BOM::Product::Transaction->new({
                client      => $cl,
                contract    => $contract_down,
                contract_id => $t->contract_id,
                price       => 0,
            });
            is $t->sell(skip_validation => 1), undef, 'FLASHU bet sold';

            $txn->buy;
        };
        SKIP: {
            skip 'no error', 5
                unless isa_ok $error, 'Error::Base';

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

            my $mock_transaction = Test::MockModule->new('BOM::Product::Transaction');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_transaction->mock(
                _validate_trade_pricing_adjustment => sub { note "mocked Transaction->_validate_trade_pricing_adjustment returning nothing"; () });
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning 'TEST'"; 'TEST' });
            my $mock_client = Test::MockModule->new('BOM::Platform::Client');
            $mock_client->mock(
                get_limit_for_daily_losses => sub { note "mocked Client->get_limit_for_daily_losses returning " . (3 * 5.20); 3 * 5.20 });

            $txn->buy;
        };

        is $error, undef, 'no error';
    }
    'survived';
};

subtest 'max_7day_losses validation', sub {
    plan tests => 14;
    lives_ok {
        my $cl = create_client;

        top_up $cl, 'USD', 100;

        isnt + (my $acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';

        my $bal;
        is + ($bal = $acc_usd->balance + 0), 100, 'USD balance is 100 got: ' . $bal;

        local $ENV{REQUEST_STARTTIME} = time;    # fix race condition
        my $contract_up = produce_contract({
            underlying   => $underlying,
            bet_type     => 'FLASHU',
            currency     => 'USD',
            payout       => 10.00,
            duration     => '15m',
            current_tick => $tick,
            barrier      => 'S0P',
            date_pricing => Date::Utility->new(time + 10),
        });

        my $contract_down = produce_contract({
            underlying   => $underlying_r100,
            bet_type     => 'FLASHD',
            currency     => 'USD',
            payout       => 10.00,
            duration     => '15m',
            current_tick => $tick,
            barrier      => 'S0P',
            date_pricing => Date::Utility->new(time + 10),
        });

        my $txn = BOM::Product::Transaction->new({
            client      => $cl,
            contract    => $contract_up,
            price       => 5.20,
            payout      => $contract_up->payout,
            amount_type => 'payout',
        });

        my $error = do {
            my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
            $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

            my $mock_transaction = Test::MockModule->new('BOM::Product::Transaction');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_transaction->mock(
                _validate_trade_pricing_adjustment => sub { note "mocked Transaction->_validate_trade_pricing_adjustment returning nothing"; () });
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning 'TEST'"; 'TEST' });
            my $mock_client = Test::MockModule->new('BOM::Platform::Client');
            $mock_client->mock(
                get_limit_for_7day_losses => sub { note "mocked Client->get_limit_for_7day_losses returning " . (3 * 5.20 - .01); 3 * 5.20 - .01 });

            my $t = BOM::Product::Transaction->new({
                client      => $cl,
                contract    => $contract_up,
                price       => 5.20,
                payout      => $contract_up->payout,
                amount_type => 'payout',
            });
            is $t->buy, undef, 'FLASHU bet bought';
            $t = BOM::Product::Transaction->new({
                client      => $cl,
                contract    => $contract_up,
                contract_id => $t->contract_id,
                price       => 0,
            });
            is $t->sell(skip_validation => 1), undef, 'FLASHU bet sold';

            $t = BOM::Product::Transaction->new({
                client      => $cl,
                contract    => $contract_down,
                price       => 5.20,
                payout      => $contract_down->payout,
                amount_type => 'payout',
            });
            is $t->buy, undef, 'FLASHD bet bought';
            $t = BOM::Product::Transaction->new({
                client      => $cl,
                contract    => $contract_down,
                contract_id => $t->contract_id,
                price       => 0,
            });
            is $t->sell(skip_validation => 1), undef, 'FLASHU bet sold';

            $txn->buy;
        };
        SKIP: {
            skip 'no error', 5
                unless isa_ok $error, 'Error::Base';

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

            my $mock_transaction = Test::MockModule->new('BOM::Product::Transaction');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_transaction->mock(
                _validate_trade_pricing_adjustment => sub { note "mocked Transaction->_validate_trade_pricing_adjustment returning nothing"; () });
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning 'TEST'"; 'TEST' });
            my $mock_client = Test::MockModule->new('BOM::Platform::Client');
            $mock_client->mock(get_limit_for_7day_losses => sub { note "mocked Client->get_limit_for_7day_losses returning " . (3 * 5.20); 3 * 5.20 }
            );

            $txn->buy;
        };

        is $error, undef, 'no error';
    }
    'survived';
};

subtest 'max_30day_losses validation', sub {
    plan tests => 14;
    lives_ok {
        my $cl = create_client;

        top_up $cl, 'USD', 100;

        isnt + (my $acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';

        my $bal;
        is + ($bal = $acc_usd->balance + 0), 100, 'USD balance is 100 got: ' . $bal;

        local $ENV{REQUEST_STARTTIME} = time;    # fix race condition
        my $contract_up = produce_contract({
            underlying   => $underlying,
            bet_type     => 'FLASHU',
            currency     => 'USD',
            payout       => 10.00,
            duration     => '15m',
            current_tick => $tick,
            barrier      => 'S0P',
            date_pricing => Date::Utility->new(time + 10),
        });

        my $contract_down = produce_contract({
            underlying   => $underlying_r100,
            bet_type     => 'FLASHD',
            currency     => 'USD',
            payout       => 10.00,
            duration     => '15m',
            current_tick => $tick,
            barrier      => 'S0P',
            date_pricing => Date::Utility->new(time + 10),
        });

        my $txn = BOM::Product::Transaction->new({
            client      => $cl,
            contract    => $contract_up,
            price       => 5.20,
            payout      => $contract_up->payout,
            amount_type => 'payout',
        });

        my $error = do {
            my $mock_contract = Test::MockModule->new('BOM::Product::Contract');
            $mock_contract->mock(is_valid_to_buy => sub { note "mocked Contract->is_valid_to_buy returning true"; 1 });

            my $mock_transaction = Test::MockModule->new('BOM::Product::Transaction');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_transaction->mock(
                _validate_trade_pricing_adjustment => sub { note "mocked Transaction->_validate_trade_pricing_adjustment returning nothing"; () });
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning 'TEST'"; 'TEST' });
            my $mock_client = Test::MockModule->new('BOM::Platform::Client');
            $mock_client->mock(
                get_limit_for_30day_losses => sub { note "mocked Client->get_limit_for_30day_losses returning " . (3 * 5.20 - .01); 3 * 5.20 - .01 });

            my $t = BOM::Product::Transaction->new({
                client      => $cl,
                contract    => $contract_up,
                price       => 5.20,
                payout      => $contract_up->payout,
                amount_type => 'payout',
            });
            is $t->buy, undef, 'FLASHU bet bought';
            $t = BOM::Product::Transaction->new({
                client      => $cl,
                contract    => $contract_up,
                contract_id => $t->contract_id,
                price       => 0,
            });
            is $t->sell(skip_validation => 1), undef, 'FLASHU bet sold';

            $t = BOM::Product::Transaction->new({
                client      => $cl,
                contract    => $contract_down,
                price       => 5.20,
                payout      => $contract_down->payout,
                amount_type => 'payout',
            });
            is $t->buy, undef, 'FLASHD bet bought';
            $t = BOM::Product::Transaction->new({
                client      => $cl,
                contract    => $contract_down,
                contract_id => $t->contract_id,
                price       => 0,
            });
            is $t->sell(skip_validation => 1), undef, 'FLASHU bet sold';

            $txn->buy;
        };
        SKIP: {
            skip 'no error', 5
                unless isa_ok $error, 'Error::Base';

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

            my $mock_transaction = Test::MockModule->new('BOM::Product::Transaction');
            # _validate_trade_pricing_adjustment() is tested in trade_validation.t
            $mock_transaction->mock(
                _validate_trade_pricing_adjustment => sub { note "mocked Transaction->_validate_trade_pricing_adjustment returning nothing"; () });
            $mock_transaction->mock(_build_pricing_comment => sub { note "mocked Transaction->_build_pricing_comment returning 'TEST'"; 'TEST' });
            my $mock_client = Test::MockModule->new('BOM::Platform::Client');
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
            bet_type     => 'FLASHU',
            currency     => 'USD',
            stake        => 100,
            date_start   => $now->epoch - 100,
            date_expiry  => $now->epoch - 50,
            current_tick => $tick,
            entry_tick   => $old_tick1,
            exit_tick    => $old_tick2,
            barrier      => 'S0P',
        });

        my $txn = BOM::Product::Transaction->new({
            client        => $cl,
            contract      => $contract_expired,
            price         => 100,
            payout        => $contract_expired->payout,
            amount_type   => 'stake',
            purchase_date => $now->epoch - 101,
        });

        my (@expired_txnids, @expired_fmbids);
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
            bet_type     => 'FLASHU',
            currency     => 'USD',
            stake        => 100,
            date_start   => $now->epoch - 100,
            date_expiry  => $now->epoch + 2,
            current_tick => $tick,
            entry_tick   => $old_tick1,
            barrier      => 'S0P',
        });

        $txn = BOM::Product::Transaction->new({
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
            push @txnids, $txn->transaction_id;
        }

        $acc_usd->load;
        is $acc_usd->balance + 0, 0, 'USD balance is down to 0';

        # First sell some particular ones by id.
        my $res = BOM::Product::Transaction::sell_expired_contracts + {
            client       => $cl,
            source       => 29,
            contract_ids => [@expired_fmbids[0 .. 1]],
        };

        is_deeply $res,
            +{
            number_of_sold_bets => 2,
            skip_contract       => 0,
            total_credited      => 200,
            },
            'sold the two requested contracts';

        $res = BOM::Product::Transaction::sell_expired_contracts + {
            client => $cl,
            source => 29
        };

        is_deeply $res, +{
            number_of_sold_bets => 3,
            skip_contract       => 5,     # this means the contract was looked at but skipped due to invalid to sell
            total_credited      => 300,
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

# see further transaction2.t: special turnover limits
#             transaction3.t: intraday fx action

Test::NoWarnings::had_no_warnings;

done_testing;
