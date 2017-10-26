#!/etc/rmg/bin/perl

use strict;
use warnings;
use Test::More (tests => 23);
use Test::Warnings;
use Test::Exception;
use DateTime::Format::HTTP;

use Format::Util::Numbers qw/financialrounding/;

use BOM::Database::AutoGenerated::Rose::FinancialMarketBetOpen::Manager;
use BOM::Database::Model::Account;
use BOM::Database::Model::FinancialMarketBet::TouchBet;
use BOM::Database::Helper::FinancialMarketBet;
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

    $client->payment_free_gift(
        currency => 'USD',
        amount   => 500,
        remark   => 'free gift',
    );

}
'create & credit acc';
my %account_data = (
    account_data => {
        client_loginid => $account->client_loginid,
        currency_code  => $account->currency_code
    });

my $touch_bet;
my $touch_bet_financial_bet_id;

my $underlying_symbol = 'frxUSDJPY';
my $payout_price      = 200;
my $buy_price         = 20;
my $sell_price        = 0;
my $remark            = 'Test Remark';
my $start_time        = DateTime::Format::HTTP->parse_datetime('2010-12-02 12:00:00');
my $expiry_time       = DateTime::Format::HTTP->parse_datetime('2010-12-02 14:00:00');
my $is_expired        = 1;
my $bet_class         = 'touch_bet';
my $bet_type          = 'ONETOUCH';
my $short_code        = 'ONETOUCH_FRXUSDJPY_50_8_MAY_09_22_MAY_09_1005400_0';

my $relative_barrier = '1.1';
my $absolute_barrier = '1673.828';
my $prediction       = 'touch';

lives_ok {

    $touch_bet = BOM::Database::Model::FinancialMarketBet::TouchBet->new({
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

                'relative_barrier' => $relative_barrier,
                'absolute_barrier' => $absolute_barrier,
                'prediction'       => $prediction,
            },
        },
    );

    my $financial_market_bet_helper = BOM::Database::Helper::FinancialMarketBet->new({
        %account_data,
        bet => $touch_bet,
        db  => $connection_builder->db,
    });
    $financial_market_bet_helper->buy_bet;

    $touch_bet_financial_bet_id = $touch_bet->financial_market_bet_open_record->id;
}
'expect to be able to buy the bet';

isa_ok($touch_bet->class_orm_record, 'BOM::Database::AutoGenerated::Rose::TouchBet');

# Check if it can be initialized propery by sendin the parent orm object that has the run_bet table joined
my $fmb_records = BOM::Database::AutoGenerated::Rose::FinancialMarketBetOpen::Manager->get_financial_market_bet_open(
    require_objects => ['touch_bet'],
    query           => [
        id => [$touch_bet_financial_bet_id],
    ],
    db => $connection_builder->db,
);

my $touch_bet_by_orm_object = BOM::Database::Model::FinancialMarketBet::TouchBet->new({
    'financial_market_bet_open_record' => $fmb_records->[0],
    'db'                               => $connection_builder->db
});
cmp_ok($touch_bet_by_orm_object->touch_bet_record->relative_barrier,
    '==', $relative_barrier, 'Check the child params to see if they are laoded properly');
cmp_ok($touch_bet_by_orm_object->touch_bet_record->absolute_barrier,
    '==', $absolute_barrier, 'Check prediction to see if the object was loaded properly');
cmp_ok($touch_bet_by_orm_object->financial_market_bet_open_record->payout_price,
    '==', $payout_price, 'Check the parent parent to see if they are loaded properly');

lives_ok {
    $touch_bet = BOM::Database::Model::FinancialMarketBet::TouchBet->new({
            data_object_params => {
                'financial_market_bet_id' => $touch_bet_financial_bet_id,
            },
            db => $connection_builder->db,
        },
    );
    $touch_bet->load;

}
'expect to load the bet records after saving them';

lives_ok {
    $touch_bet = BOM::Database::Model::FinancialMarketBet::TouchBet->new({
            'data_object_params' => {
                'financial_market_bet_id' => $touch_bet_financial_bet_id,
            },
            db => $connection_builder->db,
        },
    );
    $touch_bet->load;
    $touch_bet->sell_price(40);

    my $financial_market_bet_helper = BOM::Database::Helper::FinancialMarketBet->new({
        %account_data,
        bet      => $touch_bet,
        bet_data => {is_expired => $is_expired},
        db       => $connection_builder->db,
    });

    $financial_market_bet_helper->sell_bet // die "Bet not sold";
    $sell_price = 40;
}
'expect to sell';

is($touch_bet->financial_market_bet_open_record->account_id,        $account->id,       'account_id');
is($touch_bet->financial_market_bet_open_record->underlying_symbol, $underlying_symbol, 'underlying_symbol');
cmp_ok($touch_bet->financial_market_bet_open_record->payout_price, '==', financialrounding('amount', 'USD', $payout_price), 'payout_price');
cmp_ok($touch_bet->financial_market_bet_open_record->buy_price,    '==', financialrounding('amount', 'USD', $buy_price),    'buy_price');
cmp_ok($touch_bet->financial_market_bet_open_record->sell_price,   '==', financialrounding('amount', 'USD', $sell_price),   'sell_price');
is($touch_bet->financial_market_bet_open_record->expiry_time, $expiry_time, 'expiry_time');
is($touch_bet->financial_market_bet_open_record->is_expired,  $is_expired,  'is_expired');
is($touch_bet->financial_market_bet_open_record->is_sold,     1,            'is_sold');
is($touch_bet->financial_market_bet_open_record->bet_class,   $bet_class,   'bet_class');
is($touch_bet->financial_market_bet_open_record->bet_type,    $bet_type,    'bet_type');
is($touch_bet->financial_market_bet_open_record->short_code,  $short_code,  'short_code');

is($touch_bet->touch_bet_record->relative_barrier, $relative_barrier, 'relative_barrier');
is($touch_bet->touch_bet_record->absolute_barrier, $absolute_barrier, 'absolute_barrier');
is($touch_bet->touch_bet_record->prediction,       $prediction,       'prediction');

