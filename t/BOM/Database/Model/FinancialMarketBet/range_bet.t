#!/etc/rmg/bin/perl

use strict;
use warnings;
use Test::More (tests => 9);
use Test::Exception;
use BOM::Database::Model::Account;
use BOM::Database::Model::FinancialMarketBet::RangeBet;
use BOM::Database::Model::Constants;
use BOM::Database::Helper::FinancialMarketBet;
use BOM::Database::AutoGenerated::Rose::FinancialMarketBetOpen::Manager;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $connection_builder = BOM::Database::ClientDB->new({
    broker_code => 'CR',
});

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
my $account = $client->set_default_account('USD');
my %account_data = (account_data => {client_loginid => $account->client_loginid, currency_code => $account->currency_code});

$client->payment_legacy_payment(
    currency         => 'USD',
    amount           => 100,
    remark           => 'free gift',
    payment_type     => 'credit_debit_card',
    transaction_time => Date::Utility->new->datetime_yyyymmdd_hhmmss,
);

my $range;
my $range_id;

lives_ok {

    $range = BOM::Database::Model::FinancialMarketBet::RangeBet->new({
            'data_object_params' => {
                'account_id'        => $account->id,
                'underlying_symbol' => 'frxUSDJPY',
                'payout_price'      => 200,
                'buy_price'         => 20,
                'remark'            => 'Test Remark',
                'purchase_time'     => '2010-12-02 12:00:00',
                'start_time'        => '2010-12-02 12:00:00',
                'expiry_time'       => '2010-12-02 14:00:00',
                'is_expired'        => 1,
                'bet_class'         => 'range_bet',
                'bet_type'          => 'RANGE',
                'short_code'        => 'RANGE_FRXUSDJPY_100_30_APR_09_1_MAY_09_13450_13000',

                'absolute_higher_barrier' => '865300',
                'absolute_lower_barrier'  => '857900',
                'prediction'              => 'in',
            },
        },
    );

    my $range_helper = BOM::Database::Helper::FinancialMarketBet->new({
        %account_data,
        bet => $range,
        db  => $connection_builder->db,
    });
    $range_helper->buy_bet;

    $range_id = $range->financial_market_bet_open_record->id;
}
'expect to be able to buy the bet';

isa_ok($range->class_orm_record, 'BOM::Database::AutoGenerated::Rose::RangeBet');

# Check if it can be initialized propery by sendin the parent orm object that has the run_bet table joined
my $fmb_records = BOM::Database::AutoGenerated::Rose::FinancialMarketBetOpen::Manager->get_financial_market_bet_open(
    require_objects => ['range_bet'],
    query           => [
        id => [$range_id],
    ],
    db => $connection_builder->db,
);

my $range_bet_by_orm_object = BOM::Database::Model::FinancialMarketBet::RangeBet->new({
    'financial_market_bet_open_record' => $fmb_records->[0],
    'db'                          => $connection_builder->db
});
cmp_ok($range_bet_by_orm_object->range_bet_record->absolute_higher_barrier, '==', 865300,
    'Check the child params to see if they are laoded properly');
cmp_ok($range_bet_by_orm_object->range_bet_record->absolute_lower_barrier, '==', 857900, 'Check prediction to see if the object was loaded properly');
cmp_ok($range_bet_by_orm_object->financial_market_bet_open_record->payout_price, '==', 200, 'Check the parent paramt to see if they are loaded properly');

lives_ok {
    $range = BOM::Database::Model::FinancialMarketBet::RangeBet->new({
            data_object_params => {
                'financial_market_bet_id' => $range_id,
            },
            db => $connection_builder->db,
        },
    );
    $range->load;

}
'expect to load the bet records after saving them';

lives_ok {
    $range = BOM::Database::Model::FinancialMarketBet::RangeBet->new({
            'data_object_params' => {
                'financial_market_bet_id' => $range_id,
            },
            db => $connection_builder->db,
        },
    );
    $range->load;
    $range->sell_price(40);

    my $range_helper = BOM::Database::Helper::FinancialMarketBet->new({
        %account_data,
        bet => $range,
        db  => $connection_builder->db,
    });

    $range_helper->sell_bet // die "Bet not sold";
}
'expect to sell';

ok((
                $range->financial_market_bet_open_record->account_id eq $account->id
            and $range->financial_market_bet_open_record->underlying_symbol eq 'frxUSDJPY'
            and $range->financial_market_bet_open_record->payout_price == 200
            and $range->financial_market_bet_open_record->buy_price == 20
            and $range->financial_market_bet_open_record->sell_price == 40
            and $range->financial_market_bet_open_record->remark eq 'Test Remark'
            and $range->financial_market_bet_open_record->start_time->datetime() eq '2010-12-02T12:00:00'
            and $range->financial_market_bet_open_record->expiry_time->datetime() eq '2010-12-02T14:00:00'
            and $range->financial_market_bet_open_record->is_expired == 1
            and $range->financial_market_bet_open_record->is_sold == 1
            and $range->financial_market_bet_open_record->bet_class eq 'range_bet'
            and $range->financial_market_bet_open_record->bet_type eq 'RANGE'
            and $range->financial_market_bet_open_record->short_code eq 'RANGE_FRXUSDJPY_100_30_APR_09_1_MAY_09_13450_13000'
            and

            $range->range_bet_record->absolute_lower_barrier == 857900
            and $range->range_bet_record->absolute_higher_barrier == 865300
            and $range->range_bet_record->prediction eq 'in'
    ),
    'Expect that all fields are the same after loading FROM account transfer record'
);
