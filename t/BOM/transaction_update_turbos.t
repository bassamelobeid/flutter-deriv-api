#!/etc/rmg/bin/perl

use strict;
use warnings;

use BOM::Config::Redis;
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use BOM::Platform::Client::IDAuthentication;
use BOM::Product::ContractFactory                qw( produce_contract );
use BOM::Test::Data::Utility::FeedTestDatabase   qw(:init);
use BOM::Test::Data::Utility::UnitTestDatabase   qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis      qw(initialize_realtime_ticks_db);
use BOM::Test::Helper::Client                    qw(top_up);
use BOM::Transaction;
use BOM::Transaction::ContractUpdate;
use BOM::Transaction::ContractUpdateHistory;
use BOM::Transaction::Validation;
use BOM::User::Client;
use BOM::User::Password;
use BOM::User::Utility;
use BOM::User;
use Crypt::NamedKeys;
use Date::Utility;
use ExpiryQueue;
use Guard;
use Test::Exception;
use Test::MockModule;
use Test::More;

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

my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');
$mock_validation->mock(validate_tnc => sub { note "mocked Transaction::Validation->validate_tnc returning nothing"; undef });

my $mocked_contract = Test::MockModule->new('BOM::Product::Contract::Turboslong');
$mocked_contract->mock('strike_price_choices', sub { return ['-22.00'] });

my $underlying = create_underlying('R_100');
my $now        = Date::Utility->new;
BOM::Test::Data::Utility::UnitTestMarketData::create_doc('currency', {symbol => 'USD'});
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'index',
    {
        symbol => 'R_100',
        date   => $now,
    });

initialize_realtime_ticks_db();

BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100'], [100, $now->epoch + 1, 'R_100']);

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

sub get_audit_details_by_fmbid {
    my $fmb_id = shift;

    my $db  = db;
    my $sql = q{SELECT * from audit.turbos where financial_market_bet_id=? order by stamp desc};

    my $sth = $db->dbh->prepare($sql);
    $sth->execute($fmb_id);

    my $res = $sth->fetchall_arrayref();
    $sth->finish;

    return $res;
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
    $cl = create_client('VRTC');
    $cl->residence('aq');

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

subtest 'update take profit' => sub {
    my ($txn, $contract);

    my $args = {
        amount       => 100,
        amount_type  => 'stake',
        barrier      => '-22.00',
        bet_type     => 'TURBOSLONG',
        currency     => 'USD',
        date_start   => $now,
        date_pricing => $now,
        duration     => '1h',
        underlying   => $underlying->symbol,
    };

    $contract = produce_contract($args);

    $txn = BOM::Transaction->new({
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

    (undef, $fmb) = get_transaction_from_db turbos => $txn->transaction_id;

    my $updater = BOM::Transaction::ContractUpdate->new(
        client        => $cl,
        contract_id   => $fmb->{id},
        update_params => {take_profit => 10},
    );

    ok $updater->is_valid_to_update, 'valid to update';
    my $res = $updater->update;
    is $res->{updated_queue}->{in},  1, 'added one entry in the queue (take profit barrier)';
    is $res->{updated_queue}->{out}, 0, 'no entry removed';

    ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db turbos => $txn->transaction_id;

    subtest 'chld row', sub {
        is $chld->{financial_market_bet_id},    $fmb->{id}, 'financial_market_bet_id';
        is $chld->{'take_profit_order_amount'}, 10,         'take_profit_order_amount is 10';
        cmp_ok $chld->{'take_profit_order_date'}, "ge", $fmb->{start_time}, 'take_profit_order_date is correctly set';
    };

    my $audit_details = get_audit_details_by_fmbid($fmb->{id});
    ok !@$audit_details, 'no record is added to audit details';

    subtest 'too frequent updates' => sub {
        $updater = BOM::Transaction::ContractUpdate->new(
            client        => $cl,
            contract_id   => $fmb->{id},
            update_params => {take_profit => 30},
        );
        ok !$updater->is_valid_to_update, 'invalid to update again';
        is $updater->validation_error->{code}, 'TooFrequentUpdate', 'code - TooFrequentUpdate';
        is $updater->validation_error->{message_to_client},
            'Only one update per second is allowed.',
            'message_to_client - Only one update per second is allowed.';

        $audit_details = get_audit_details_by_fmbid($fmb->{id});
        ok !@$audit_details, 'no record is added to audit details';
    };

    subtest 'take profit amount less than current value' => sub {
        # only one update per second is allowed
        sleep 1;

        $mocked_contract->mock('_max_allowable_take_profit', sub { return 10 });

        $updater = BOM::Transaction::ContractUpdate->new(
            client        => $cl,
            contract_id   => $fmb->{id},
            update_params => {take_profit => 11},
        );

        ok !$updater->is_valid_to_update, 'invalid to update';
        is $updater->validation_error->{code},              'TakeProfitTooHigh',                                          'correct code';
        is $updater->validation_error->{message_to_client}, "Please enter a take profit amount that's lower than 10.00.", 'correct message_to_client';

        $audit_details = get_audit_details_by_fmbid($fmb->{id});
        ok !@$audit_details, 'no record is added to audit details';

        $mocked_contract->unmock('_max_allowable_take_profit');
    };

    $updater = BOM::Transaction::ContractUpdate->new(
        client        => $cl,
        contract_id   => $fmb->{id},
        update_params => {take_profit => 15},
    );
    ok $updater->is_valid_to_update, 'valid to update';
    $res = $updater->update;
    is $res->{updated_queue}->{in},  1, 'added one entry in the queue (new take profit barrier)';
    is $res->{updated_queue}->{out}, 1, 'removed one entry from the queue (old take profit barrier)';

    ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db turbos => $txn->transaction_id;

    subtest 'chld row', sub {
        is $chld->{financial_market_bet_id},    $fmb->{id}, 'financial_market_bet_id';
        is $chld->{'take_profit_order_amount'}, 15,         'take_profit_order_amount is 15';
        cmp_ok $chld->{'take_profit_order_date'}, "ge", $fmb->{start_time}, 'take_profit_order_date is correctly set';
    };

    $audit_details = get_audit_details_by_fmbid($fmb->{id});
    ok $audit_details->[0], 'audit populated';
    cmp_ok $audit_details->[0][6], "le", Date::Utility->new->db_timestamp, "timestamp is now";

    sleep 1;

    $updater = BOM::Transaction::ContractUpdate->new(
        client        => $cl,
        contract_id   => $fmb->{id},
        update_params => {take_profit => undef},
    );

    ok $updater->is_valid_to_update, 'valid to update';
    $res = $updater->update;
    is $res->{updated_queue}->{in},  0, 'no entry is added in the queue';
    is $res->{updated_queue}->{out}, 1, 'removed one entry from the queue (take profit barrier)';

    ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db turbos => $txn->transaction_id;

    subtest 'chld row', sub {
        is $chld->{financial_market_bet_id},    $fmb->{id}, 'financial_market_bet_id';
        is $chld->{'take_profit_order_amount'}, undef,      'take_profit_order_amount is undef';
        cmp_ok $chld->{'take_profit_order_date'}, "ge", $fmb->{start_time}, 'take_profit_order_date is correctly set';
    };

    $audit_details = get_audit_details_by_fmbid($fmb->{id});
    ok $audit_details->[0], 'audit cancel populated';
    ok $audit_details->[1], 'audit update populated';
    cmp_ok $audit_details->[1][6], "lt", $audit_details->[0][6], "timestamp are in order";

    subtest "get update history for $fmb->{id}" => sub {
        my $update_history = BOM::Transaction::ContractUpdateHistory->new(
            client => $cl,
        );
        my $history = $update_history->get_history_by_contract_id({
            contract_id => $fmb->{id},
            limit       => 5000
        });
        is scalar(@$history),             3, 'has three entries';
        is $history->[0]->{display_name}, 'Take profit';
        is $history->[0]->{order_amount}, 0;
        is $history->[1]->{display_name}, 'Take profit';
        is $history->[1]->{order_amount}, 15;
        is $history->[2]->{display_name}, 'Take profit';
        is $history->[2]->{order_amount}, 10;

        sleep 1;
        $updater = BOM::Transaction::ContractUpdate->new(
            client        => $cl,
            contract_id   => $fmb->{id},
            update_params => {take_profit => 11},
        );
        ok $updater->is_valid_to_update, 'valid to update';
        $updater->update;
        $res = $update_history->get_history_by_contract_id({
            contract_id => $fmb->{id},
            limit       => 5000
        });
        is $res->[0]->{display_name}, 'Take profit';
        is $res->[0]->{order_amount}, 11;
        is $res->[1]->{display_name}, 'Take profit';
        is $res->[1]->{order_amount}, 0;
        is $res->[2]->{display_name}, 'Take profit';
        is $res->[2]->{order_amount}, 15;
        is $res->[3]->{display_name}, 'Take profit';
        is $res->[3]->{order_amount}, 10;

        ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db turbos => $txn->transaction_id;
    };

    subtest 'update take profit on a sold contract' => sub {
        # we just want to _validate_trade_pricing_adjustment
        my $mocked = Test::MockModule->new('BOM::Transaction::Validation');
        $mocked->mock($_ => sub { '' })
            for (
            qw/
            _validate_sell_transaction_rate
            _is_valid_to_sell
            _validate_currency
            _validate_date_pricing/
            );

        # no limits
        $mocked->mock('limits', sub { {} });
        my $last_updated_record = $chld;

        $txn = BOM::Transaction->new({
                purchase_date       => $contract->date_start,
                client              => $cl,
                contract_parameters => {
                    shortcode       => $contract->shortcode,
                    currency        => $cl->currency,
                    landing_company => $cl->landing_company->short,
                    limit_order     => {
                        take_profit => {
                            order_amount => $last_updated_record->{take_profit_order_amount},
                            order_date   => $last_updated_record->{take_profit_order_date},
                        }
                    },
                },
                contract_id => $fmb->{id},
                price       => $contract->bid_price,
                amount_type => 'payout',
                source      => 23,
            });

        # only one update per second is allowed
        sleep 1;
        my $updater = BOM::Transaction::ContractUpdate->new(
            client        => $cl,
            contract_id   => $fmb->{id},
            update_params => {take_profit => 10},
        );
        ok $updater->is_valid_to_update, 'valid to update';
        # sell after is_valid_to_update is called
        ok !$txn->sell(), 'no error when sell';

        ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db turbos => $txn->transaction_id;
        ok $fmb->{is_sold}, 'contract is sold successfully';
        sleep 1;
        my $res = $updater->update;
        ok !$res->{updated_queue}, 'undefined updated_queue';
        ok !$res->{updated_table}, 'undefined updated_table';

        $updater = BOM::Transaction::ContractUpdate->new(
            client        => $cl,
            contract_id   => $fmb->{id},
            update_params => {take_profit => 10},
        );
        ok !$updater->is_valid_to_update, 'invalid to update';
        is $updater->validation_error->{code},              'ContractIsSold',        'code - ContractIsSold';
        is $updater->validation_error->{message_to_client}, 'Contract has expired.', 'message_to_client - Contract has expired.';
    };
};

done_testing();
