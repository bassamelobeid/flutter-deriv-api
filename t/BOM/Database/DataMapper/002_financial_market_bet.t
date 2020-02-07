#!perl

use strict;
use warnings;
use Test::More (tests => 33);
use Test::Warnings;

use Test::Exception;
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Database::Model::Account;
use BOM::Database::Model::FinancialMarketBet;
use BOM::Database::Model::FinancialMarketBet::DigitBet;
use BOM::Database::Model::FinancialMarketBet::HigherLowerBet;
use BOM::Database::Model::FinancialMarketBet::TouchBet;
use BOM::Database::Model::FinancialMarketBet::RangeBet;
use BOM::Database::Helper::FinancialMarketBet;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client qw( create_client top_up );
use BOM::Database::ClientDB;
use Date::Utility;

my $connection_builder;
my $account;

sub buy {
    my $bet_data = shift;
    my $transaction_data = shift // {};

    return BOM::Database::Helper::FinancialMarketBet->new({
            account_data => {
                client_loginid => $account->client_loginid,
                currency_code  => $account->currency_code,
            },
            transaction_data => {
                transaction_time => scalar $bet_data->{transaction_time},
                staff_loginid    => scalar $bet_data->{staff_loginid},
                %$transaction_data,
            },
            bet_data => $bet_data,
            db       => $connection_builder->db,
        })->buy_bet;
}

sub sell {
    my $bet_data         = shift;
    my $transaction_data = shift;

    my $helper = BOM::Database::Helper::FinancialMarketBet->new({
            account_data => {
                client_loginid => $account->client_loginid,
                currency_code  => $account->currency_code,
            },
            bet_data => +{
                sell_time => Date::Utility::today()->db_timestamp,
                %$bet_data
            },
            db => $connection_builder->db,
        });

    $helper->transaction_data($transaction_data) if $transaction_data;

    return $helper->sell_bet;
}

sub buy_multiple_bets {
    my ($acc, $bet_data, $transaction_data) = @_;

    my $fmb = BOM::Database::Helper::FinancialMarketBet->new({
            account_data     => [map { +{client_loginid => $_->client_loginid, currency_code => $_->currency_code} } @$acc],
            bet_data         => $bet_data,
            transaction_data => {
                transaction_time => scalar $bet_data->{transaction_time},
                staff_loginid    => scalar $bet_data->{staff_loginid},
                %$transaction_data,
            },
            db => $connection_builder->db,
        });
    return $fmb->batch_buy_bet;
}

sub sell_by_shortcode {
    my ($shortcode, $acc, $bet_data, $transaction_data) = @_;

    my $now = Date::Utility->new->plus_time_interval('1s');

    my $fmb = BOM::Database::Helper::FinancialMarketBet->new({
            bet_data         => $bet_data,
            account_data     => [map { +{client_loginid => $_->client_loginid, currency_code => $_->currency_code} } @$acc],
            transaction_data => {
                transaction_time => scalar $bet_data->{transaction_time},
                staff_loginid    => scalar $bet_data->{staff_loginid},
            },
            db => $connection_builder->db,
        });

    $fmb->transaction_data($transaction_data) if $transaction_data;
    return $fmb->sell_by_shortcode($shortcode);
}

sub batch_sell {
    my $bet_ids          = shift;
    my $transaction_data = shift;

    my @bets_to_sell =
        map { {id => $_, quantity => 1, sell_price => 30, sell_time => Date::Utility->new->plus_time_interval('1s')->db_timestamp,} } @$bet_ids;

    my $fmb = BOM::Database::Helper::FinancialMarketBet->new({
            account_data => {
                client_loginid => $account->client_loginid,
                currency_code  => $account->currency_code,
            },
            bet_data => \@bets_to_sell,
            db       => $connection_builder->db,
        });

    $fmb->transaction_data([map { $transaction_data } @$bet_ids]) if $transaction_data;

    return $fmb->batch_sell_bet;
}

lives_ok {
    $connection_builder = BOM::Database::ClientDB->new({
        broker_code => 'CR',
    });

    $account = BOM::Database::Model::Account->new({
            'data_object_params' => {
                'client_loginid' => 'CR0021',
                'currency_code'  => 'USD'
            },
            db => $connection_builder->db
        });
    $account->load();
}
'build connection builder & account';

my $clientdb;
lives_ok {
    $clientdb = BOM::Database::ClientDB->new({broker_code => 'CR'});
}
'build fmb data mapper';

## higher lower - absolute barrier
my $short_code = 'PUT_FRXUSDJPY_2_1311570485_25_JUL_11_784600_0';
cmp_ok(scalar @{$clientdb->getall_arrayref('select * from bet.get_open_bets_of_account(?,?,?)', ['CR0021', 'USD', 'false'])},
    '==', 0, 'check qty open bet = 0');

# buy bet
lives_ok {
    buy {
        'underlying_symbol' => 'frxUSDJPY',
        'payout_price'      => 2,
        'buy_price'         => 1.07,
        'remark' =>
            'vega[-0.00002] atmf_fct[0.70411] div[0.00252] recalc[1.07000] int[0.00107] theta[0.00092] iv[0.10500] emp[1.06000] fwdst_fct[1.00000] win[2.00000] trade[1.07000] dscrt_fct[0.99299] spot[78.46000] gamma[0.03950] delta[-1.63768] theo[1.00000] base_spread[0.10000] ia_fct[1.00000] news_fct[1.00000]',
        'purchase_time'    => '2011-07-25 05:08:05',
        'start_time'       => '2011-07-25 05:08:05',
        'expiry_time'      => '2011-07-25 23:59:59',
        'bet_class'        => 'higher_lower_bet',
        'bet_type'         => 'PUT',
        'absolute_barrier' => '78.46',
        'short_code'       => $short_code,
        'quantity'         => 1,
    };
}
'buy higher lower absolute barrier bet';
cmp_ok(scalar @{$clientdb->getall_arrayref('select * from bet.get_open_bets_of_account(?,?,?)', ['CR0021', 'USD', 'false'])},
    '==', 1, 'check qty open bet = 1');

## higher lower - relative barrier
$short_code = 'CALL_FRXUSDJPY_20_1311574735_1311576535_S10P_0';
cmp_ok(scalar @{$clientdb->getall_arrayref('select * from bet.get_open_bets_of_account(?,?,?)', ['CR0021', 'USD', 'false'])},
    '==', 1, 'check qty open bet = 1');

# buy bet
my @fmb_id;
lives_ok {
    my ($fmb, $txn) = buy {
        'underlying_symbol' => 'frxUSDJPY',
        'payout_price'      => 20,
        'buy_price'         => 4.04,
        'remark' =>
            'vega[0.03177] atmf_fct[1.00000] div[0.00252] recalc[4.04000] int[0.00107] theta[-76.23706] iv[0.09900] emp[0.00000] fwdst_fct[1.00000] win[20.00000] trade[4.04000] dscrt_fct[0.88803] spot[78.41000] gamma[569.41770] delta[24.91933] theo[0.88000] base_spread[0.35552] ia_fct[1.00000] news_fct[1.00000]',
        'purchase_time'    => '2011-07-25 06:18:55',
        'start_time'       => '2011-07-25 06:18:55',
        'expiry_time'      => '2011-07-25 06:48:55',
        'bet_class'        => 'higher_lower_bet',
        'bet_type'         => 'CALL',
        'relative_barrier' => 'S10P',
        'short_code'       => $short_code,
        'quantity'         => 1,
    };
    push @fmb_id, $fmb->{id};
}
'buy higher lower relative barrier bet';
cmp_ok(scalar @{$clientdb->getall_arrayref('select * from bet.get_open_bets_of_account(?,?,?)', ['CR0021', 'USD', 'false'])},
    '==', 2, 'check qty open bet = 1');

# buy 1 more same bet
lives_ok {
    my ($fmb, $txn) = buy {
        'underlying_symbol' => 'frxUSDJPY',
        'payout_price'      => 20,
        'buy_price'         => 4.04,
        'remark' =>
            'vega[0.03177] atmf_fct[1.00000] div[0.00252] recalc[4.04000] int[0.00107] theta[-76.23706] iv[0.09900] emp[0.00000] fwdst_fct[1.00000] win[20.00000] trade[4.04000] dscrt_fct[0.88803] spot[78.41000] gamma[569.41770] delta[24.91933] theo[0.88000] base_spread[0.35552] ia_fct[1.00000] news_fct[1.00000]',
        'purchase_time'    => '2011-07-25 06:18:55',
        'start_time'       => '2011-07-25 06:18:55',
        'expiry_time'      => '2011-07-25 06:48:55',
        'bet_class'        => 'higher_lower_bet',
        'bet_type'         => 'CALL',
        'relative_barrier' => 'S10P',
        'short_code'       => $short_code,
        'quantity'         => 1,
    };
    push @fmb_id, $fmb->{id};
}
'buy higher lower relative barrier bet';
cmp_ok(scalar @{$clientdb->getall_arrayref('select * from bet.get_open_bets_of_account(?,?,?)', ['CR0021', 'USD', 'false'])},
    '==', 3, 'check qty open bet = 2');

# sell 1 bet & test
isnt scalar sell({
        id         => shift(@fmb_id),
        sell_price => 20,
        quantity   => 1,
    }
    ),
    undef, 'sell 1 bet';
cmp_ok(scalar @{$clientdb->getall_arrayref('select * from bet.get_open_bets_of_account(?,?,?)', ['CR0021', 'USD', 'false'])},
    '==', 2, 'check qty open bet = 1');

# sell the other bet too
isnt scalar sell({
        id         => shift(@fmb_id),
        sell_price => 20,
        quantity   => 1,
    }
    ),
    undef, 'sell 1 bet';
cmp_ok(scalar @{$clientdb->getall_arrayref('select * from bet.get_open_bets_of_account(?,?,?)', ['CR0021', 'USD', 'false'])},
    '==', 1, 'check qty open bet = 0');

## touch bet - absolute barrier
$short_code = 'ONETOUCH_GDAXI_2_1311602700_1_AUG_11_7435_0';
# buy bet
lives_ok {
    my ($fmb, $txn) = buy {
        'underlying_symbol' => 'GDAXI',
        'payout_price'      => 2,
        'buy_price'         => 1.11,
        'remark' =>
            ' vega[0.00849] atmf_fct[1.00000] div[0.00000] recalc[1.11000] int[0.00730] theta[-0.06083] iv[0.13400] emp[1.60000] fwdst_fct[1.00000] win[2.00000] trade[1.11000] dscrt_fct[1.00000] spot[7341.28000] gamma[0.24015] delta[0.67803] theo[0.99000] base_spread[0.12000] ia_fct[1.00000] news_fct[1.00000]',
        'purchase_time'    => '2011-07-25 14:05:00',
        'start_time'       => '2011-07-25 14:05:00',
        'expiry_time'      => '2011-08-01 15:30:00',
        'bet_class'        => 'touch_bet',
        'bet_type'         => 'ONETOUCH',
        'absolute_barrier' => '7435',
        'short_code'       => $short_code,
        'quantity'         => 1,
    };
    push @fmb_id, $fmb->{id};
}
'buy touch bet absolute barrier bet';
cmp_ok(scalar @{$clientdb->getall_arrayref('select * from bet.get_open_bets_of_account(?,?,?)', ['CR0021', 'USD', 'false'])},
    '==', 2, 'check qty open bet = 1');

# sell it
isnt scalar sell({
        id         => shift(@fmb_id),
        sell_price => 2,
        quantity   => 1,
    }
    ),
    undef, 'sell 1 bet';
cmp_ok(scalar @{$clientdb->getall_arrayref('select * from bet.get_open_bets_of_account(?,?,?)', ['CR0021', 'USD', 'false'])},
    '==', 1, 'check qty open bet = 0');

## touch bet - relative barrier
$short_code = 'NOTOUCH_R_50_2_1311603776_1311607376_S5004P_0';
# buy bet
lives_ok {
    my ($fmb, $txn) = buy {
        'underlying_symbol' => 'R_50',
        'payout_price'      => 2,
        'buy_price'         => 1.15,
        'remark' =>
            ' vega[0.00849] atmf_fct[1.00000] div[0.00000] recalc[1.11000] int[0.00730] theta[-0.06083] iv[0.13400] emp[1.60000] fwdst_fct[1.00000] win[2.00000] trade[1.11000] dscrt_fct[1.00000] spot[7341.28000] gamma[0.24015] delta[0.67803] theo[0.99000] base_spread[0.12000] ia_fct[1.00000] news_fct[1.00000]',
        'purchase_time'    => '2011-07-25 14:22:56',
        'start_time'       => '2011-07-25 14:22:56',
        'expiry_time'      => '2011-07-25 15:22:56',
        'bet_class'        => 'touch_bet',
        'bet_type'         => 'NOTOUCH',
        'relative_barrier' => 'S5004P',
        'short_code'       => $short_code,
        'quantity'         => 1,
    };
    push @fmb_id, $fmb->{id};
}
'buy touch bet relative barrier bet';
cmp_ok(scalar @{$clientdb->getall_arrayref('select * from bet.get_open_bets_of_account(?,?,?)', ['CR0021', 'USD', 'false'])},
    '==', 2, 'check qty open bet = 1');

# sell it
isnt scalar sell({
        id         => shift(@fmb_id),
        sell_price => 2,
        quantity   => 1,
    }
    ),
    undef, 'sell 1 bet';
cmp_ok(scalar @{$clientdb->getall_arrayref('select * from bet.get_open_bets_of_account(?,?,?)', ['CR0021', 'USD', 'false'])},
    '==', 1, 'check qty open bet = 0');

## range bet - absolute barrier
$short_code = 'RANGE_FTSE_4_1311604156_1_AUG_11_6064_5801';
# buy bet
lives_ok {
    my ($fmb, $txn) = buy {
        'underlying_symbol' => 'FTSE',
        'payout_price'      => 4,
        'buy_price'         => 2.5,
        'remark' =>
            'vega[-0.03734] atmf_fct[1.00000] div[0.00070] recalc[2.50000] int[0.00555] theta[0.26518] iv[0.14000] emp[0.65000] fwdst_fct[1.00000] win[4.00000] trade[2.50000] dscrt_fct[1.00000] spot[5932.22000] gamma[-0.99341] delta[-0.01521] theo[1.98000] base_spread[0.26000] ia_fct[1.00000] news_fct[1.00000]',
        'purchase_time'           => '2011-07-25 14:29:16',
        'start_time'              => '2011-07-25 14:29:16',
        'expiry_time'             => '2011-08-01 15:30:00',
        'bet_class'               => 'range_bet',
        'bet_type'                => 'RANGE',
        'absolute_lower_barrier'  => '5801',
        'absolute_higher_barrier' => '6064',
        'short_code'              => $short_code,
        'quantity'                => 1,
    };
    push @fmb_id, $fmb->{id};
}
'buy range bet absolute barrier bet';
cmp_ok(scalar @{$clientdb->getall_arrayref('select * from bet.get_open_bets_of_account(?,?,?)', ['CR0021', 'USD', 'false'])},
    '==', 2, 'check qty open bet = 1');

# sell it
isnt scalar sell({
        id         => shift(@fmb_id),
        sell_price => 2.5,
        quantity   => 1,
    }
    ),
    undef, 'sell 1 bet';
cmp_ok(scalar @{$clientdb->getall_arrayref('select * from bet.get_open_bets_of_account(?,?,?)', ['CR0021', 'USD', 'false'])},
    '==', 1, 'check qty open bet = 0');

## range bet - relative barrier
$short_code = 'EXPIRYMISS_R_25_3_1311605282_1311634082_S7147P_S-7148P';
# buy bet
lives_ok {
    my ($fmb, $txn) = buy {
        'underlying_symbol' => 'R_25',
        'payout_price'      => 3,
        'buy_price'         => 1.55,
        'remark' =>
            'vega[0.01290] atmf_fct[1.00000] div[0.00000] recalc[1.55000] int[0.00000] theta[-1.93557] iv[0.25000] emp[0.13000] fwdst_fct[1.00000] win[3.00000] trade[1.55000] dscrt_fct[1.00000] spot[1393.94800] gamma[2.26075] delta[-0.00340] theo[1.49000] base_spread[0.04000] ia_fct[1.00000] news_fct[1.00000]',
        'purchase_time'           => '2011-07-25 14:48:02',
        'start_time'              => '2011-07-25 14:48:02',
        'expiry_time'             => '2011-07-25 22:48:02',
        'bet_class'               => 'range_bet',
        'bet_type'                => 'EXPIRYMISS',
        'relative_lower_barrier'  => 'S-7148P',
        'relative_higher_barrier' => 'S7147P',
        'short_code'              => $short_code,
        'quantity'                => 1,
    };
    push @fmb_id, $fmb->{id};
}
'buy range bet relative barrier bet';
cmp_ok(scalar @{$clientdb->getall_arrayref('select * from bet.get_open_bets_of_account(?,?,?)', ['CR0021', 'USD', 'false'])},
    '==', 2, 'check qty open bet = 1');

# sell it
isnt scalar sell({
        id         => shift(@fmb_id),
        sell_price => 2.5,
        quantity   => 1,
    }
    ),
    undef, 'sell 1 bet';
cmp_ok(scalar @{$clientdb->getall_arrayref('select * from bet.get_open_bets_of_account(?,?,?)', ['CR0021', 'USD', 'false'])},
    '==', 1, 'check qty open bet = 0');

subtest 'digits' => sub {
    my %type_prediction = (
        DIGITDIFF  => 'differ',
        DIGITMATCH => 'match',
        DIGITODD   => 'odd',
        DIGITEVEN  => 'even',
        DIGITOVER  => 'over',
        DIGITUNDER => 'under',
    );

    foreach my $type (sort keys %type_prediction) {
        subtest $type => sub {
            lives_ok {
                my ($fmb, $txn) = buy {
                    'underlying_symbol' => 'R_25',
                    'payout_price'      => 3,
                    'buy_price'         => 1.55,
                    'remark' =>
                        'vega[0.01290] atmf_fct[1.00000] div[0.00000] recalc[1.55000] int[0.00000] theta[-1.93557] iv[0.25000] emp[0.13000] fwdst_fct[1.00000] win[3.00000] trade[1.55000] dscrt_fct[1.00000] spot[1393.94800] gamma[2.26075] delta[-0.00340] theo[1.49000] base_spread[0.04000] ia_fct[1.00000] news_fct[1.00000]',
                    'purchase_time' => '2011-07-25 14:48:02',
                    'start_time'    => '2011-07-25 14:48:02',
                    'expiry_time'   => '2011-07-25 22:48:02',
                    'bet_class'     => 'digit_bet',
                    'bet_type'      => $type,
                    'last_digit'    => 7,
                    'prediction'    => $type_prediction{$type},
                    'short_code'    => $short_code,
                    'quantity'      => 1,
                };
                push @fmb_id, $fmb->{id};
            }
            'buy';
            cmp_ok(scalar @{$clientdb->getall_arrayref('select * from bet.get_open_bets_of_account(?,?,?)', ['CR0021', 'USD', 'false'])},
                '==', 2, 'check qty open bet = 1');

            isnt scalar sell({
                    id         => shift(@fmb_id),
                    sell_price => 2.5,
                    quantity   => 1,
                }
                ),
                undef, 'sell';
            cmp_ok(scalar @{$clientdb->getall_arrayref('select * from bet.get_open_bets_of_account(?,?,?)', ['CR0021', 'USD', 'false'])},
                '==', 1, 'check qty open bet = 0');
        };
    }
};

subtest buy_sell_return_values => sub {
    my $bet_info = {
        'underlying_symbol' => 'R_25',
        'payout_price'      => 3,
        'buy_price'         => 1.55,
        'remark'            => 'test remark',
        'purchase_time'     => '2011-07-25 14:48:02',
        'start_time'        => '2011-07-25 14:48:02',
        'expiry_time'       => '2011-07-25 22:48:02',
        'bet_class'         => 'digit_bet',
        'bet_type'          => 'CALL',
        'last_digit'        => 7,
        'prediction'        => 'match',
        'short_code'        => 'EXPIRYMISS_R_25_3_1311605282_1311634082_S7147P_S-7148P',
        'quantity'          => 1,
    };

    my $buy_txn_info = {
        source => 1000,
    };
    my $sell_txn_info = {
        source => 10,
    };

    my $cl1 = create_client;
    my $cl2 = create_client;

    top_up $cl1, 'USD', 5000;
    top_up $cl2, 'USD', 1000;

    my $acc1 = $cl1->account;
    my $acc2 = $cl2->account;

    subtest 'buy_bet and sell_bet' => sub {
        my ($buy_fmb, $buy_txn) = buy($bet_info, $buy_txn_info);
        is $buy_txn->{source}, $buy_txn_info->{source}, 'buy source is set correctly';

        my ($sell_fmb, $sell_txn, $buy_txn_id, $buy_source) = sell({
                id         => $buy_fmb->{id},
                sell_price => 2.5,
                quantity   => 1,
            },
            $sell_txn_info
        );

        is $sell_txn->{source}, $sell_txn_info->{source}, 'sell source is correctly set';
        is $buy_txn_id, $buy_txn->{id},     'correct buy txn id returned';
        is $buy_source, $buy_txn->{source}, 'correct buy source returned';
    };

    subtest 'multiple buy_bet / batch_sell' => sub {
        my @buys;

        push @buys, [buy($bet_info, $buy_txn_info)];
        push @buys, [buy($bet_info, $buy_txn_info)];
        push @buys, [buy($bet_info, $buy_txn_info)];

        my $res = batch_sell([map { $_->[0]->{id} } @buys], $sell_txn_info);
        is scalar @$res, scalar @buys, 'Correct number of contracts sold';

        my %sell_res = map { $_->{buy_txn_id} => $_ } @$res;

        for my $i (0 .. @buys - 1) {
            my ($buy_fmb, $buy_txn) = $buys[$i]->@*;

            is $buy_txn->{source}, $buy_txn_info->{source}, 'buy source is correctly set';
            ok my $sell_data = $sell_res{$buy_txn->{id}}, "buy txn id $buy_txn->{id} found in sells";

            is $sell_data->{txn}->{source}, $sell_txn_info->{source}, 'sell source is correctly set';
            is $sell_data->{buy_txn_id}, $buy_txn->{id},     "correct buy txn id $buy_txn->{id} returned by sell";
            is $sell_data->{buy_source}, $buy_txn->{source}, 'correct buy source returned by sell';
        }
    };

    subtest 'batch_buy / sell_by_shortcode' => sub {
        my $accounts = [$account, $acc1, $acc2];
        my $buy = buy_multiple_bets($accounts, $bet_info, $buy_txn_info);
        is scalar @$buy, 3, 'correct number of buy transactions returned';
        is $_->{txn}->{source}, $buy_txn_info->{source}, 'buy source is set correctly' for @$buy;

        my $now  = Date::Utility->new->plus_time_interval('1s');
        my $sell = sell_by_shortcode(
            $bet_info->{short_code},
            $accounts,
            {
                'sell_price' => '2.5',
                'sell_time'  => $now->db_timestamp,
                'id'         => undef,
                'quantity'   => 1,
            },
            $sell_txn_info
        );
        is scalar @$sell, 3, 'correct number of sell transactions returned';

        for my $i (0 .. @$accounts - 1) {
            my %buy_data  = $buy->[$i]->%*;
            my %sell_data = $sell->[$i]->%*;
            my $loginid   = $accounts->[$i]->client_loginid;
            is $buy_data{loginid},  $loginid, "buy loginid is correct: $loginid";
            is $sell_data{loginid}, $loginid, "sell loginid is correct: $loginid";
            is $buy_data{txn}->{source}, $buy_txn_info->{source}, "$loginid: buy source is set correctly";

            is $sell_data{txn}->{source}, $sell_txn_info->{source}, "$loginid: sell source is correctly set";
            is $sell_data{buy_tr_id},  $buy_data{txn}->{id},     "$loginid: correct buy txn id returned";
            is $sell_data{buy_source}, $buy_data{txn}->{source}, "$loginid: correct buy source returned";
        }
    };

    #TODO: to be completed by checking the whole txn and fmb structures.
};

1;
