#!/etc/rmg/bin/perl

use strict;
use warnings;
use Test::More (tests => 11);
use Test::Warnings;
use Test::Exception;
use BOM::Database::Model::Account;
use BOM::Database::Model::FinancialMarketBet::HigherLowerBet;
use BOM::Database::Model::Constants;
use BOM::Database::Helper::FinancialMarketBet;
use BOM::Database::AutoGenerated::Rose::FinancialMarketBet::Manager;
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

$client->payment_free_gift(
    currency    => 'USD',
    amount      => 500,
    remark      => 'free gift',
);

my $higher_lower;
my $higher_lower_id;

lives_ok {
    $higher_lower = BOM::Database::Model::FinancialMarketBet::HigherLowerBet->new({});
}
'Initiate object without passing data_object_params';

# Normal High Low Bet
lives_ok {

    $higher_lower = BOM::Database::Model::FinancialMarketBet::HigherLowerBet->new({
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
                'bet_class'         => 'higher_lower_bet',
                'bet_type'          => 'CALL',
                'short_code'        => 'CALL_FRXUSDJPY_2_1301038969_1301038999_S0P_0',
                'relative_barrier'  => '1.1',
                'absolute_barrier'  => '1673.828',
                'prediction'        => 'up',

            },
        },
    );

    my $higher_lower_helper = BOM::Database::Helper::FinancialMarketBet->new({
        %account_data,
        bet => $higher_lower,
        db  => $connection_builder->db,
    });
    $higher_lower_helper->buy_bet;

    $higher_lower_id = $higher_lower->financial_market_bet_open_record->id;
}
'expect to be able to buy the bet';

isa_ok($higher_lower->class_orm_record, 'BOM::Database::AutoGenerated::Rose::HigherLowerBet');

# Check if it can be initialized propery by sendin the parent orm object that has the run_bet table joined
my $fmb_records = BOM::Database::AutoGenerated::Rose::FinancialMarketBetOpen::Manager->get_financial_market_bet_open(
    require_objects => ['higher_lower_bet'],
    query           => [
        id => [$higher_lower_id],
    ],
    db => $connection_builder->db,
);

my $higher_lower_by_orm_object = BOM::Database::Model::FinancialMarketBet::HigherLowerBet->new({
    'financial_market_bet_open_record' => $fmb_records->[0],
    'db'                          => $connection_builder->db
});
cmp_ok($higher_lower_by_orm_object->higher_lower_bet_record->relative_barrier, '==', 1.1,
    'Check the child params to see if they are laoded properly');
cmp_ok($higher_lower_by_orm_object->higher_lower_bet_record->absolute_barrier,
    '==', 1673.828, 'Check prediction to see if the object was loaded properly');
cmp_ok($higher_lower_by_orm_object->financial_market_bet_open_record->payout_price,
    '==', 200, 'Check the parent paramt to see if they are loaded properly');

lives_ok {
    $higher_lower = BOM::Database::Model::FinancialMarketBet::HigherLowerBet->new({
            'data_object_params' => {
                'financial_market_bet_id' => $higher_lower_id,
            },
            db => $connection_builder->db,
        },
    );
    $higher_lower->load;

}
'expect to load the bet records after saving them';

lives_ok {
    $higher_lower = BOM::Database::Model::FinancialMarketBet::HigherLowerBet->new({
            'data_object_params' => {
                'financial_market_bet_id' => $higher_lower_id,
            },
            db => $connection_builder->db,
        },
    );
    $higher_lower->load;
    $higher_lower->sell_price(40);

    my $higher_lower_helper = BOM::Database::Helper::FinancialMarketBet->new({
        %account_data,
        bet_data => {
            id         => $higher_lower_id,
            sell_price => 40,
            is_expired => 1,
            },
        db  => $connection_builder->db,
    });

    $higher_lower_helper->sell_bet() // die "Bet not sold";
}
'expect to sell';

subtest 'Expect that all fields are the same after loading FROM account transfer record' => sub {
    is $higher_lower->financial_market_bet_open_record->account_id, $account->id;
    is $higher_lower->financial_market_bet_open_record->underlying_symbol, 'frxUSDJPY';
    is $higher_lower->financial_market_bet_open_record->payout_price, '200.00';
    is $higher_lower->financial_market_bet_open_record->buy_price, '20.00';
    is $higher_lower->financial_market_bet_open_record->sell_price, '40.00';
    is $higher_lower->financial_market_bet_open_record->remark, 'Test Remark';
    is $higher_lower->financial_market_bet_open_record->start_time->datetime(), '2010-12-02T12:00:00';
    is $higher_lower->financial_market_bet_open_record->expiry_time->datetime(), '2010-12-02T14:00:00';
    is $higher_lower->financial_market_bet_open_record->is_expired, 1;
    is $higher_lower->financial_market_bet_open_record->is_sold, 1;
    is $higher_lower->financial_market_bet_open_record->bet_class, 'higher_lower_bet';
    is $higher_lower->financial_market_bet_open_record->bet_type, 'CALL';


    is $higher_lower->higher_lower_bet_record->relative_barrier, 1.1;
    is $higher_lower->higher_lower_bet_record->absolute_barrier, 1673.828;
    is $higher_lower->higher_lower_bet_record->prediction, 'up';
};

lives_ok {
    my $new_higher_lower_bet = BOM::Database::Model::FinancialMarketBet::HigherLowerBet->new({
        'higher_lower_bet_record'     => $higher_lower->higher_lower_bet_record,
        'financial_market_bet_open_record' => $higher_lower->financial_market_bet_open_record,
    });
}
'check if we can instantiate a higher_lowe_bet by passing an orm object.'
