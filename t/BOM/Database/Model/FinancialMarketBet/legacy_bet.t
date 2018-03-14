#!/etc/rmg/bin/perl

use strict;
use warnings;
use Test::More (tests => 27);
use Test::Warnings;
use Test::Exception;
use Date::Utility;

use Format::Util::Numbers qw/financialrounding/;

use BOM::Database::AutoGenerated::Rose::FinancialMarketBetOpen::Manager;
use BOM::Database::Model::Account;
use BOM::Database::Model::FinancialMarketBet::LegacyBet;
use BOM::Database::Helper::FinancialMarketBet;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $connection_builder = BOM::Database::ClientDB->new({
    broker_code => 'CR',
});

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
my $account      = $client->set_default_account('USD');
my %account_data = (
    account_data => {
        client_loginid => $account->client_loginid,
        currency_code  => $account->currency_code
    });

$client->payment_free_gift(
    currency => 'USD',
    amount   => 500,
    remark   => 'free gift',
);

my $legacy_bet;
my $legacy_bet_financial_bet_id;

my $underlying_symbol = 'FRXXAUUSD';
my $payout_price      = 200;
my $buy_price         = 20;
my $sell_price        = 0;
my $remark            = 'Test Remark';
my $start_time        = Date::Utility->new('2010-12-02 12:00:00');
my $expiry_time       = Date::Utility->new('2010-12-02 14:00:00');
my $is_expired        = 1;
my $bet_class         = 'legacy_bet';
my $bet_type          = 'DOUBLEDBL';
my $short_code        = 'DOUBLEDBL_FRXXAUUSD_100_14_MAY_09_I_8H1_L_8H2_L_8H3';

# DOUBLEDBL_FRXUSDJPY_10_24_JAN_06_I_3H5_L_4_L_4H1
my $absolute_higher_barrier = '1.1';
my $absolute_lower_barrier  = '2.2';
my $intraday_endhour        = '4.1';
my $intraday_ifunless       = 'I';
my $intraday_leg1           = 'L';
my $intraday_leg2           = 'L';
my $intraday_midhour        = '4';
my $intraday_starthour      = '3.5';

lives_ok {

    $legacy_bet = BOM::Database::Model::FinancialMarketBet::LegacyBet->new({
            'data_object_params' => {
                'account_id' => $account->id,

                'underlying_symbol' => $underlying_symbol,
                'payout_price'      => $payout_price,
                'buy_price'         => $buy_price,
                'remark'            => $remark,
                'purchase_time'     => $start_time,
                'start_time'        => $start_time,
                'expiry_time'       => $expiry_time,
                'is_expired'        => $is_expired,
                'bet_class'         => $bet_class,
                'bet_type'          => $bet_type,
                'short_code'        => $short_code,

                'absolute_higher_barrier' => $absolute_higher_barrier,
                'absolute_lower_barrier'  => $absolute_lower_barrier,
                'intraday_endhour'        => $intraday_endhour,
                'intraday_ifunless'       => $intraday_ifunless,
                'intraday_leg1'           => $intraday_leg1,
                'intraday_leg2'           => $intraday_leg2,
                'intraday_midhour'        => $intraday_midhour,
                'intraday_starthour'      => $intraday_starthour,
            },
        },
    );

    my $financial_market_bet_helper = BOM::Database::Helper::FinancialMarketBet->new({
        %account_data,
        bet => $legacy_bet,
        db  => $connection_builder->db,
    });
    $financial_market_bet_helper->bet_data->{quantity} = 1;
    $financial_market_bet_helper->buy_bet;

    $legacy_bet_financial_bet_id = $legacy_bet->financial_market_bet_open_record->id;
}
'expect to be able to buy the bet';

isa_ok($legacy_bet->class_orm_record, 'BOM::Database::AutoGenerated::Rose::LegacyBet');

# Check if it can be initialized propery by sendin the parent orm object that has the run_bet table joined
my $fmb_records = BOM::Database::AutoGenerated::Rose::FinancialMarketBetOpen::Manager->get_financial_market_bet_open(
    require_objects => ['legacy_bet'],
    query           => [
        id => [$legacy_bet_financial_bet_id],
    ],
    db => $connection_builder->db,
);

my $legacy_bet_by_orm_object = BOM::Database::Model::FinancialMarketBet::LegacyBet->new({
    'financial_market_bet_open_record' => $fmb_records->[0],
    'db'                               => $connection_builder->db
});
cmp_ok($legacy_bet_by_orm_object->legacy_bet_record->absolute_higher_barrier,
    '==', $absolute_higher_barrier, 'Check the child params to see if they are laoded properly');
cmp_ok($legacy_bet_by_orm_object->legacy_bet_record->absolute_lower_barrier,
    '==', $absolute_lower_barrier, 'Check prediction to see if the object was loaded properly');
cmp_ok($legacy_bet_by_orm_object->financial_market_bet_open_record->payout_price,
    '==', $payout_price, 'Check the parent paramt to see if they are loaded properly');

lives_ok {
    $legacy_bet = BOM::Database::Model::FinancialMarketBet::LegacyBet->new({
            'data_object_params' => {
                'financial_market_bet_id' => $legacy_bet_financial_bet_id,
            },
            db => $connection_builder->db,
        },
    );
    $legacy_bet->load;

}
'expect to load the bet records after saving them';

lives_ok {
    $legacy_bet = BOM::Database::Model::FinancialMarketBet::LegacyBet->new({
            'data_object_params' => {
                'financial_market_bet_id' => $legacy_bet_financial_bet_id,
            },
            db => $connection_builder->db,
        },
    );
    $legacy_bet->load;
    $legacy_bet->sell_price(40);

    my $financial_market_bet_helper = BOM::Database::Helper::FinancialMarketBet->new({
        %account_data,
        bet      => $legacy_bet,
        bet_data => {is_expired => 1},
        db       => $connection_builder->db,
    });
    $financial_market_bet_helper->bet_data->{quantity} = 1;
    $financial_market_bet_helper->sell_bet // die "Bet not sold";
    $sell_price = 40;
}
'expect to sell';

is($legacy_bet->financial_market_bet_open_record->account_id,        $account->id,       'account_id');
is($legacy_bet->financial_market_bet_open_record->underlying_symbol, $underlying_symbol, 'underlying_symbol');
cmp_ok($legacy_bet->financial_market_bet_open_record->payout_price, '==', financialrounding('amount', 'USD', $payout_price), 'payout_price');
cmp_ok($legacy_bet->financial_market_bet_open_record->buy_price,    '==', financialrounding('amount', 'USD', $buy_price),    'buy_price');
cmp_ok($legacy_bet->financial_market_bet_open_record->sell_price,   '==', financialrounding('amount', 'USD', $sell_price),   'sell_price');
is($legacy_bet->financial_market_bet_open_record->expiry_time, $expiry_time, 'expiry_time');
is($legacy_bet->financial_market_bet_open_record->is_expired,  $is_expired,  'is_expired');
is($legacy_bet->financial_market_bet_open_record->is_sold,     1,            'is_sold');
is($legacy_bet->financial_market_bet_open_record->bet_class,   $bet_class,   'bet_class');
is($legacy_bet->financial_market_bet_open_record->bet_type,    $bet_type,    'bet_class');
is($legacy_bet->financial_market_bet_open_record->short_code,  $short_code,  'shoct_code');

is($legacy_bet->legacy_bet_record->absolute_higher_barrier, $absolute_higher_barrier, 'absolute_higher_barrier');
is($legacy_bet->legacy_bet_record->absolute_lower_barrier,  $absolute_lower_barrier,  'absolute_lower_barrier');
is($legacy_bet->legacy_bet_record->intraday_endhour,        $intraday_endhour,        'intraday_endhour');
is($legacy_bet->legacy_bet_record->intraday_ifunless,       $intraday_ifunless,       'intraday_ifunless');
is($legacy_bet->legacy_bet_record->intraday_leg1,           $intraday_leg1,           'intraday_leg1');
is($legacy_bet->legacy_bet_record->intraday_leg2,           $intraday_leg2,           'intraday_leg2');
is($legacy_bet->legacy_bet_record->intraday_midhour,        $intraday_midhour,        'intraday_midhour');
is($legacy_bet->legacy_bet_record->intraday_starthour,      $intraday_starthour,      'intraday_starthour');

