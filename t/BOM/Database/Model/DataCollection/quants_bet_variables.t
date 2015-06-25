use strict;
use warnings;
use Test::More (tests => 16);
use Test::NoWarnings;
use DBI;
use DBD::SQLite;
use Test::Exception;
use BOM::Database::Model::Account;
use BOM::Database::Model::FinancialMarketBet;
use BOM::Database::Model::FinancialMarketBet::Factory;
use BOM::Database::Model::Constants;
use BOM::Database::Helper::FinancialMarketBet;
use BOM::Database::Model::DataCollection::QuantsBetVariables;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $connection_builder;
my $account;

lives_ok {
    $connection_builder = BOM::Database::ClientDB->new({
        broker_code => 'CR',
    });

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $account = $client->set_default_account('USD');

    $client->payment_legacy_payment(
        currency         => 'USD',
        amount           => 100,
        remark           => 'free gift',
        payment_type     => 'credit_debit_card',
        transaction_time => Date::Utility->new->datetime_yyyymmdd_hhmmss,
    );
} 'expecting to create the required account models for transfer';

my $financial_market_bet_id;
my $financial_market_bet_helper;
my ($fmb, $txn);

lives_ok {
    # my $class = BOM::Database::Model::FinancialMarketBet::Factory
    #             ->map_bet_class_to_classname('higher_lower_bet');
    # $financial_market_bet = $class->new({
    #         'data_object_params' => {
    #             'account_id'        => $account->id,
    #             'underlying_symbol' => 'frxUSDJPY',
    #             'payout_price'      => 200,
    #             'buy_price'         => 20,
    #             'sell_price'        => 0,
    #             'remark'            => 'Test Remark',
    #             'purchase_time'     => '2010-12-02 12:00:00',
    #             'start_time'        => '2010-12-02 12:00:00',
    #             'expiry_time'       => '2010-12-02 14:00:00',
    #             'is_expired'        => 1,
    #             'is_sold'           => 1,
    #             'bet_class'         => 'higher_lower_bet',
    #             'bet_type'          => 'FLASHU',
    #             'short_code'        => 'FLASHU_FRXUSDJPY_15_23_OCT_09_S30_05H5648',
    #             'sell_time'         => '2010-12-02 14:00:10',
    #         },
    #     },
    # );

    my $legacy_line          = 'COMMENT:theo=1 trade=1 recalc=1 win=2 (0.5,buy) delta=0.002 vega=0 theta=0 gamma=0 intradaytime=0.856150104239055';
    my $quants_bet_variables = BOM::Database::Model::DataCollection::QuantsBetVariables->new({
        'data_object_params' => BOM::Database::Model::DataCollection::QuantsBetVariables->extract_parameters_from_line({'line' => $legacy_line}),
    });

    $financial_market_bet_helper = BOM::Database::Helper::FinancialMarketBet->new({
        account_data => {
            client_loginid => $account->client_loginid,
            currency_code  => $account->currency_code,
        },
        bet_data => {
            'underlying_symbol' => 'frxUSDJPY',
            'payout_price'      => 200,
            'buy_price'         => 20,
            'remark'            => 'Test Remark',
            'purchase_time'     => '2010-12-02 12:00:00',
            'start_time'        => '2010-12-02 12:00:00',
            'expiry_time'       => '2010-12-02 14:00:00',
            'bet_class'         => 'higher_lower_bet',
            'bet_type'          => 'FLASHU',
            'short_code'        => 'FLASHU_FRXUSDJPY_15_23_OCT_09_S30_05H5648',
        },
        quants_bet_variables => $quants_bet_variables,
        db                   => $connection_builder->db,
    });
    ($fmb, $txn) = $financial_market_bet_helper->buy_bet;
}
'expect to be able to buy the bet';

my $quants_bet_variables;
lives_ok {
    $quants_bet_variables = BOM::Database::Model::DataCollection::QuantsBetVariables->new({
        'data_object_params' => {'transaction_id' => $txn->{id}},
        db                   => $connection_builder->db,
    });
    $quants_bet_variables->load;
}
'expect to load quants variables properly.';

cmp_ok($quants_bet_variables->theo,         'eq', '1');
cmp_ok($quants_bet_variables->trade,        'eq', '1');
cmp_ok($quants_bet_variables->recalc,       'eq', '1');
cmp_ok($quants_bet_variables->win,          'eq', '2');
cmp_ok($quants_bet_variables->delta,        'eq', '0.002');
cmp_ok($quants_bet_variables->vega,         'eq', '0');
cmp_ok($quants_bet_variables->gamma,        'eq', '0');
cmp_ok($quants_bet_variables->intradaytime, 'eq', '0.856150104239055');

$quants_bet_variables->gamma(10);
$quants_bet_variables->save;

lives_ok {
    $quants_bet_variables = BOM::Database::Model::DataCollection::QuantsBetVariables->new({
        'data_object_params' => {'transaction_id' => $txn->{id}},
        db                   => $connection_builder->db,
    });
    $quants_bet_variables->load;
}
'expect to load quants variables properly after saving it.';

ok($quants_bet_variables->gamma eq '10' and 1, 'Expect that all fields are the same after loading',);

isa_ok($quants_bet_variables->class_orm_record, 'BOM::Database::AutoGenerated::Rose::QuantsBetVariable');

lives_ok {
    BOM::Database::Model::DataCollection::QuantsBetVariables->new({
        'data_object_params' => BOM::Database::Model::DataCollection::QuantsBetVariables->extract_parameters_from_line({'line' => 'COMMENT:'}),
    });
}
'It must be able to survive even if there is no variable in comment';
