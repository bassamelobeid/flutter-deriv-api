#!perl

use strict;
use warnings;
use Test::Warnings;
use Test::More tests => 16;
use Test::Exception;
use Test::FailWarnings -allow_from => [qw/BOM::Database::Rose::DB/];
use BOM::Database::Model::Account;
use BOM::Database::Model::FinancialMarketBet;
use BOM::Database::Model::FinancialMarketBetOpen;
use BOM::Database::Model::FinancialMarketBet::Factory;
use BOM::Database::Model::Constants;
use BOM::Database::Helper::FinancialMarketBet;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use Date::Utility;

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
'expecting to create the required account models for transfer';
my %account_data = (
    account_data => {
        client_loginid => $account->client_loginid,
        currency_code  => $account->currency_code
    });

my $financial_market_bet;
my $financial_market_bet_id;
my $financial_market_bet_helper;

$financial_market_bet = BOM::Database::Model::FinancialMarketBet::HigherLowerBet->new({
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
            'is_sold'           => 0,
            'bet_class'         => 'higher_lower_bet',
            'bet_type'          => 'CALL',
            'short_code'        => 'CALL_IXIC_20_8_MAR_05_22_MAR_05_2089_0',
            'quantity'          => 1,
        },
    },
);

lives_ok {
    $financial_market_bet_helper = BOM::Database::Helper::FinancialMarketBet->new({
        %account_data,
        bet => $financial_market_bet,
        db  => $connection_builder->db,
    });
    $financial_market_bet_helper->bet_data->{quantity} = 1;
    $financial_market_bet_helper->buy_bet;

    $financial_market_bet_id = $financial_market_bet->financial_market_bet_open_record->id;
}
'expect to be able to buy the bet';

lives_ok {
    my $extracted_params = {
        loginid         => 'CR10002',
        sell_price      => 40,
        currency        => 'USD',
        order_reference => 0,
        quantity        => 1,
        short_code      => 'CALL_IXIC_20_8_MAR_05_22_MAR_05_2089_0',
        price           => 40,
        staff_loginid   => 'CR10002',
        client_loginid  => 'CR10002',
        remark          => 'bet expired',
        bet_type        => 'CALL',
    };
    $extracted_params->{account_id} = $account->id;

    $financial_market_bet->sell_price(40);
    my $financial_market_bet_helper = BOM::Database::Helper::FinancialMarketBet->new({
        %account_data,
        bet => $financial_market_bet,
        db  => $connection_builder->db,
    });
    $financial_market_bet_helper->bet_data->{quantity}  = 1;
    $financial_market_bet_helper->bet_data->{sell_time} = Date::Utility::today()->db_timestamp;
    $financial_market_bet_helper->sell_bet // die "Bet not sold";

    $financial_market_bet = BOM::Database::Model::FinancialMarketBet->new({
            'data_object_params' => {
                'financial_market_bet_id' => $financial_market_bet_id,
            },
            db => $connection_builder->db,
        },
    );
    $financial_market_bet->load();
}
'expect to sell and adjust and load again';

is_deeply([
        $financial_market_bet->financial_market_bet_record->account_id,
        $financial_market_bet->financial_market_bet_record->underlying_symbol,
        $financial_market_bet->financial_market_bet_record->payout_price,
        $financial_market_bet->financial_market_bet_record->buy_price,
        $financial_market_bet->financial_market_bet_record->sell_price,
        $financial_market_bet->financial_market_bet_record->remark,
        $financial_market_bet->financial_market_bet_record->start_time->epoch,
        $financial_market_bet->financial_market_bet_record->expiry_time->epoch,
        $financial_market_bet->financial_market_bet_record->is_expired,
        $financial_market_bet->financial_market_bet_record->is_sold,
        $financial_market_bet->financial_market_bet_record->bet_class,
        $financial_market_bet->financial_market_bet_record->bet_type,
        $financial_market_bet->financial_market_bet_record->short_code,
    ],
    [
        $account->id, 'frxUSDJPY', '200.00', '20.00', '40.00', 'Test Remark', '1291291200', '1291298400', 1, 1, 'higher_lower_bet', 'CALL',
        'CALL_IXIC_20_8_MAR_05_22_MAR_05_2089_0',
    ],
    'correct data read back'
);

throws_ok(sub { $financial_market_bet->save }, qr/permission denied/, 'updating fmb is not allowed');

lives_ok {
    $financial_market_bet = BOM::Database::Model::FinancialMarketBet::HigherLowerBet->new({
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
                'is_sold'           => 0,
                'bet_class'         => 'higher_lower_bet',
                'bet_type'          => 'CALL',
                'short_code'        => 'CALL_FRXUSDJPY_15_23_OCT_09_S30_05H5648',
            },
        },
    );

    my $financial_market_bet_helper = BOM::Database::Helper::FinancialMarketBet->new({
        %account_data,
        bet => $financial_market_bet,
        db  => $connection_builder->db,
    });
    $financial_market_bet_helper->bet_data->{quantity} = 1;
    $financial_market_bet_helper->buy_bet;

    $financial_market_bet = BOM::Database::Model::FinancialMarketBetOpen->new({
            data_object_params => {
                'financial_market_bet_id' => $financial_market_bet->financial_market_bet_open_record->id,
            },
            db => $connection_builder->db,
        },
    );
    $financial_market_bet->load;

    $financial_market_bet->sell_price(40);
    $financial_market_bet_helper->clear_bet_data;
    $financial_market_bet_helper->bet($financial_market_bet);
    $financial_market_bet_helper->bet_data->{quantity}  = 1;
    $financial_market_bet_helper->bet_data->{sell_time} = Date::Utility::today()->db_timestamp;
    $financial_market_bet_helper->sell_bet // die "Bet not sold";

}
'Buy a non legacy bet and sell it (expired).';

lives_ok {
    my $financial_market_bet = BOM::Database::Model::FinancialMarketBet::HigherLowerBet->new({
            'data_object_params' => {
                'account_id'        => $account->id,
                'underlying_symbol' => 'frxUSDJPY',
                'payout_price'      => 200,
                'buy_price'         => 20,
                'remark'            => 'Test Remark',
                'purchase_time'     => '2010-12-02 12:00:00',
                'start_time'        => '2010-12-02 12:00:00',
                'expiry_time'       => '2010-12-02 14:00:00',
                'is_expired'        => 0,
                'is_sold'           => 0,
                'bet_class'         => 'higher_lower_bet',
                'bet_type'          => 'CALL',
                'short_code'        => 'CALL_FRXUSDJPY_15_23_OCT_09_S30_05H5648',
            },
        },
    );

    my $financial_market_bet_helper = BOM::Database::Helper::FinancialMarketBet->new({
        %account_data,
        bet => $financial_market_bet,
        db  => $connection_builder->db,
    });
    $financial_market_bet_helper->bet_data->{quantity} = 1;
    $financial_market_bet_helper->buy_bet;

    $financial_market_bet = BOM::Database::Model::FinancialMarketBetOpen->new({
            'data_object_params' => {
                'financial_market_bet_id' => $financial_market_bet->financial_market_bet_open_record->id,
                ,
            },
            db => $connection_builder->db,
        },
    );
    $financial_market_bet->load;

    $financial_market_bet->sell_price(40);
    $financial_market_bet_helper->clear_bet_data;
    $financial_market_bet_helper->bet($financial_market_bet);
    $financial_market_bet_helper->bet_data->{quantity}  = 1;
    $financial_market_bet_helper->bet_data->{sell_time} = Date::Utility::today()->db_timestamp;
    $financial_market_bet_helper->sell_bet // die "Bet not sold";
}
'Buy a non legacy bet and sell it (not expired).';

lives_ok {
    $financial_market_bet = BOM::Database::Model::FinancialMarketBet->new({
            'data_object_params' => {
                'financial_market_bet_id' => $financial_market_bet_id,
            },
            db => $connection_builder->db,
        },
    );
    $financial_market_bet->load;

}
'expect to load the bet records after saving them';

lives_ok {
    my $financial_market_bet_2 = BOM::Database::Model::FinancialMarketBet->new({
            db => $connection_builder->db,
        },
    );

}
'expect to instansiate the model without params';

throws_ok {
    my $financial_market_bet_helper = BOM::Database::Helper::FinancialMarketBet->new({bet_data => {}});
    $financial_market_bet_helper->sell_bet() // die "Bet not sold";
}
qr/undefined value/, 'Check if sell will die if there is no DB at all';

lives_ok {
    my %bet_params = (
        'account_id'        => $account->id,
        'underlying_symbol' => 'frxUSDJPY',
        'payout_price'      => 200,
        'buy_price'         => 20,
        'remark'            => 'Test Remark',
        'purchase_time'     => '2010-12-02 12:00:00',
        'start_time'        => '2010-12-02 12:00:00',
        'expiry_time'       => '2010-12-02 14:00:00',
        'bet_class'         => 'higher_lower_bet',
        'bet_type'          => 'CALL',
        'short_code'        => 'CALL_FRXUSDJPY_15_23_OCT_09_S30_05H5648',
        'quantity'          => 1,
        'number_of_ticks'   => 5,
        'prediction'        => 'up',
    );

    my @fmbs;

    my $financial_market_bet = BOM::Database::Model::FinancialMarketBet::HigherLowerBet->new({'data_object_params' => \%bet_params});
    $financial_market_bet->financial_market_bet_open_record->account_id($account->id);
    my $financial_market_bet_helper = BOM::Database::Helper::FinancialMarketBet->new({
        %account_data,
        bet => $financial_market_bet,
        db  => $connection_builder->db,
    });

    $financial_market_bet_helper->bet_data->{quantity} = 1;
    push @fmbs, ($financial_market_bet_helper->buy_bet)[0];    # buy 1st bet
    push @fmbs, ($financial_market_bet_helper->buy_bet)[0];    # and the 2nd one

    cmp_ok $fmbs[0]->{id}, '>', 0, 'got 1st fmb id';
    cmp_ok $fmbs[1]->{id}, '>', 0, 'got 2nd fmb id';

    $financial_market_bet->id($fmbs[0]->{id});
    $financial_market_bet->sell_price(20);
    $financial_market_bet_helper->clear_bet_data;
    $financial_market_bet_helper->bet_data->{quantity}  = 1;
    $financial_market_bet_helper->bet_data->{sell_time} = Date::Utility::today()->db_timestamp;
    push @fmbs, ($financial_market_bet_helper->sell_bet)[0];    # sell 1st bet

    $financial_market_bet->id($fmbs[1]->{id});
    $financial_market_bet->sell_price(20);
    $financial_market_bet_helper->clear_bet_data;
    $financial_market_bet_helper->bet_data->{quantity}  = 1;
    $financial_market_bet_helper->bet_data->{sell_time} = Date::Utility::today()->db_timestamp;
    push @fmbs, ($financial_market_bet_helper->sell_bet)[0];    # sell 1st bet

    is $fmbs[0]->{id}, $fmbs[2]->{id}, 'sold 1st bet';
    is $fmbs[1]->{id}, $fmbs[3]->{id}, 'sold 2nd bet';
}
'expect to buy 2 identical bets & sell 2 bets';

done_testing;
