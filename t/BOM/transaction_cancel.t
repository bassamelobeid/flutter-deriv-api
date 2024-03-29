#!/etc/rmg/bin/perl

use strict;
use warnings;
use Test::MockTime qw/:all/;
use Test::MockModule;
use Test::More;
use Test::Exception;

use BOM::Test::Data::Utility::UnitTestDatabase   qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase   qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis      qw(initialize_realtime_ticks_db);
use BOM::Test::Helper::Client                    qw(top_up);
use ExpiryQueue;

use Guard;
use Crypt::NamedKeys;
use Date::Utility;

use BOM::User::Client;
use BOM::User::Password;
use BOM::User::Utility;
use BOM::User;

use BOM::Transaction;
use BOM::Transaction::ContractUpdate;
use BOM::Transaction::Validation;
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Platform::Client::IDAuthentication;
use BOM::Config::Redis;

use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;

my $password = 'jskjd8292922';
my $email    = 'test' . rand(999) . '@binary.com';
my $hash_pwd = BOM::User::Password::hashpw($password);

my $user = BOM::User->create(
    email    => $email,
    password => $hash_pwd
);

my $expiryq = ExpiryQueue->new(redis => BOM::Config::Redis::redis_expiryq_write);
$expiryq->queue_flush();

Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';

my $mocked_contract = Test::MockModule->new('BOM::Product::Contract::Multup');
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
my $mocked_u = Test::MockModule->new('Quant::Framework::Underlying');
$mocked_u->mock('spot_tick', sub { return $current_tick });

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

lives_ok {
    $cl = create_client;

    #make sure client can trade
    ok(!BOM::Transaction::Validation->new({clients => [$cl]})->_validate_client_status($cl), "client can trade: _validate_client_status");

    top_up $cl, 'USD', 5000;

    $acc_usd = $cl->account;
    is $acc_usd->currency_code, 'USD', 'got USD account';

    my $bal;
    is + ($bal = $acc_usd->balance + 0), 5000, 'USD balance is 5000 got: ' . $bal;
}
'client created and funded';

my ($trx, $fmb, $chld, $qv1, $qv2);

subtest 'test cancel functionality', sub {
    subtest 'buy deal cancellation with wrong duration' => sub {
        my $now      = time;
        my $contract = produce_contract({
            underlying   => 'R_100',
            bet_type     => 'MULTUP',
            currency     => 'USD',
            multiplier   => 10,
            amount       => 100,
            amount_type  => 'stake',
            current_tick => $current_tick,
            cancellation => 1,
        });

        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 104.35,
            amount        => 104.35,
            amount_type   => 'stake',
            source        => 19,
            purchase_date => $contract->date_start,
        });

        my $error = $txn->buy;
        is $error->{'-mesg'},              'invalid deal cancellation duration',                 'message';
        is $error->{'-message_to_client'}, 'Deal cancellation is not offered at this duration.', 'message to client';
    };
    subtest 'cancel without purchasing cancel option ' => sub {
        my $contract = produce_contract({
            underlying   => 'R_100',
            bet_type     => 'MULTUP',
            currency     => 'USD',
            multiplier   => 10,
            amount       => 100,
            amount_type  => 'stake',
            current_tick => $current_tick,
        });

        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 100,
            source        => 19,
            purchase_date => $contract->date_start,
        });

        my $error = $txn->cancel;
        ok $error, 'cancel failed with error';
        is $error->{-mesg}, 'Deal cancellation not purchased', 'message - Deal cancellation not purchased';
        is $error->{-message_to_client},
            'This contract does not include deal cancellation. Your contract can only be cancelled when you select deal cancellation in your purchase.',
            'message to client - This contract does not include deal cancellation. Your contract can only be cancelled when you select deal cancellation in your purchase.';
    };

    subtest 'cancel after deal cancellation expires' => sub {
        my $now      = time;
        my $contract = produce_contract({
            underlying   => 'R_100',
            bet_type     => 'MULTUP',
            currency     => 'USD',
            multiplier   => 10,
            amount       => 100,
            amount_type  => 'stake',
            current_tick => $current_tick,
            date_start   => $now,
            date_pricing => $now + 3601,
            cancellation => '1h',
        });

        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 100,
            source        => 19,
            purchase_date => $contract->date_start,
        });

        my $error = $txn->cancel;
        ok $error, 'cancel failed with error';
        is $error->{-mesg}, 'Deal cancellation expired', 'message - Deal cancellation expired';
        is $error->{-message_to_client},
            'Deal cancellation period has expired. Your contract can only be cancelled while deal cancellation is active.',
            'message to client - Deal cancellation period has expired. Your contract can only be cancelled while deal cancellation is active.';
    };

    subtest 'cancel and get back stake' => sub {
        my $now = time;
        BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([102, $now - 1, 'R_100'], [100, $now, 'R_100'], [101, $now + 1, 'R_100']);

        my $contract = produce_contract({
                underlying   => 'R_100',
                bet_type     => 'MULTUP',
                currency     => 'USD',
                multiplier   => 10,
                amount       => 100,
                amount_type  => 'stake',
                current_tick => $current_tick,
                cancellation => '1h',
                limit_order  => {
                    stop_out => {
                        order_type   => 'stop_out',
                        order_amount => -100,
                        order_date   => $now,
                        basis_spot   => 100
                    }}});

        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 104.35,
            amount        => 104.35,
            amount_type   => 'stake',
            source        => 19,
            purchase_date => $contract->date_start,
        });

        my $error = $txn->buy;
        ok !$error, 'buy without error';

        ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db multiplier => $txn->transaction_id;

        $contract = produce_contract({
                underlying   => 'R_100',
                bet_type     => 'MULTUP',
                currency     => 'USD',
                multiplier   => 10,
                amount       => 100,
                amount_type  => 'stake',
                current_tick => $current_tick,
                cancellation => '1h',
                date_start   => $now,
                date_pricing => $now + 30,
                limit_order  => {
                    stop_out => {
                        order_type   => 'stop_out',
                        order_amount => -100,
                        order_date   => $now,
                        basis_spot   => 100
                    }}});
        $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            contract_id   => $fmb->{id},
            source        => 19,
            purchase_date => $contract->date_start,
        });
        $error = $txn->cancel;
        ok !$error, 'no error on cancel';
        ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db multiplier => $txn->transaction_id;

        is $fmb->{sell_price} + 0, $contract->cancel_price, 'contract sold with stake';
    };
};

done_testing();
