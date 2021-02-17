#!perl

use strict;
use warnings;
use Test::More (tests => 32);
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
use BOM::Database::ClientDB;
use Date::Utility;

my $connection_builder;
my $account;

sub buy {
    my $bet_data = shift;

    return BOM::Database::Helper::FinancialMarketBet->new({
            account_data => {
                client_loginid => $account->client_loginid,
                currency_code  => $account->currency_code,
            },
            transaction_data => {
                transaction_time => scalar $bet_data->{transaction_time},
                staff_loginid    => scalar $bet_data->{staff_loginid},
            },
            bet_data => $bet_data,
            db       => $connection_builder->db,
        })->buy_bet;
}

sub sell {
    my $bet_data = shift;

    return BOM::Database::Helper::FinancialMarketBet->new({
            account_data => {
                client_loginid => $account->client_loginid,
                currency_code  => $account->currency_code,
            },
            transaction_data => {
                transaction_time => scalar $bet_data->{transaction_time},
                staff_loginid    => scalar $bet_data->{staff_loginid},
            },
            bet_data => +{
                sell_time => Date::Utility::today()->db_timestamp,
                %$bet_data
            },
            db => $connection_builder->db,
        })->sell_bet;
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
        'remark'            =>
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
        'remark'            =>
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
        'remark'            =>
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
        'remark'            =>
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
        'remark'            =>
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
        'remark'            =>
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
        'remark'            =>
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
                    'remark'            =>
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

1;
