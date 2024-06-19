#!perl

use 5.010;
use Test::Most 0.22 (tests => 2);
use Test::Exception;
use Test::Warnings;

use BOM::Database::DataMapper::Transaction;
use BOM::Database::Model::FinancialMarketBet::HigherLowerBet;
use BOM::Database::Model::Constants;
use BOM::Database::Helper::FinancialMarketBet;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

# add client
my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$client->set_default_account('USD');

# insert transactions
sub insert_payment {
    my ($date, $amount) = @_;
    my $trx = $client->payment_legacy_payment(
        currency     => 'USD',
        amount       => $amount,
        payment_type => 'adjustment',
        remark       => 'play money'
    );
    return $trx->payment_id;
}

# inserts higher/lower bet
sub insert_hl_bet {
    my ($date, $duration, $price, $payout, $win) = @_;
    my $hl_helper = BOM::Database::Helper::FinancialMarketBet->new({
            account_data => {
                client_loginid => $client->loginid,
                currency_code  => $client->currency,
            },
            transaction_data => {
                staff_loginid    => $client->loginid,
                transaction_time => $date->db_timestamp,
            },
            bet_data => {
                underlying_symbol => 'frxUSDJPY',
                payout_price      => $payout,
                buy_price         => $price,
                remark            => 'higher lower bet',
                purchase_time     => $date->db_timestamp,
                start_time        => $date->db_timestamp,
                expiry_time       => Date::Utility->new($date->epoch + $duration)->db_timestamp,
                is_expired        => 0,
                bet_class         => 'higher_lower_bet',
                bet_type          => 'CALL',
                relative_barrier  => '1.1',
                absolute_barrier  => '1673.828',
                prediction        => 'up',
                quantity          => 1,
                short_code        => 'some short code',
            },
            db       => $client->db,
            quantity => 1,
        });

    my ($fmb, $txn) = $hl_helper->buy_bet;
    $fmb->{quantity} = 1;
    $hl_helper->bet_data($fmb);
    $fmb->{sell_price}                               = ($win) ? $payout : 0;
    $fmb->{sell_time}                                = Date::Utility->new($date->epoch + 10)->db_timestamp;
    $hl_helper->transaction_data->{transaction_time} = Date::Utility->new($date->epoch + 10)->db_timestamp;

    ($fmb, $txn) = $hl_helper->sell_bet;
}

lives_ok {
    insert_payment(Date::Utility->new('2005-01-08'), '1000');

    insert_hl_bet(Date::Utility->new('2005-01-20 08:00:34'), 3600, 11, 20, 1);

    insert_payment(Date::Utility->new('2005-02-15'), '-100');

    insert_hl_bet(Date::Utility->new('2005-04-02 08:30:30'), 3600, 13, 20, 0);
    insert_hl_bet(Date::Utility->new('2005-04-02 09:30:30'), 3600, 13, 20, 0);
    insert_hl_bet(Date::Utility->new('2005-04-02 10:30:30'), 3600, 13, 20, 1);
    insert_hl_bet(Date::Utility->new('2005-04-02 11:30:30'), 3600, 13, 20, 1);

    insert_hl_bet(Date::Utility->new('2005-04-04 08:30:30'), 3600, 13,  20,  0);
    insert_hl_bet(Date::Utility->new('2005-04-04 09:30:30'), 3600, 13,  20,  1);
    insert_hl_bet(Date::Utility->new('2005-04-04 10:30:30'), 3600, 13,  20,  0);
    insert_hl_bet(Date::Utility->new('2005-04-04 11:30:30'), 3600, 130, 200, 0);

    insert_hl_bet(Date::Utility->new('2005-04-16 08:30:30'), 3600, 130, 200, 1);
    insert_hl_bet(Date::Utility->new('2005-04-16 16:30:30'), 3600, 130, 200, 1);

    insert_payment(Date::Utility->new('2005-04-18'), '-200');

    insert_hl_bet(Date::Utility->new('2005-04-19 08:30:00'), 7200, 500, 1200, 0);
    insert_payment(Date::Utility->new('2005-04-19 10:30:00'), '500');
}
'USD acc - Added test data';
