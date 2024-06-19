use strict;
use warnings;
use Test::More (tests => 8);
use Test::Warnings;

use Test::Exception;
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Database::Model::Account;
use BOM::Database::Model::FinancialMarketBet;
use BOM::Database::Model::FinancialMarketBet::HigherLowerBet;
use BOM::Database::Helper::FinancialMarketBet;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Database::ClientDB;

# Buy a bet and try to manually close by using batch_sell_bet

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

sub batch_sell {
    my $bet_data = shift;

    return BOM::Database::Helper::FinancialMarketBet->new({
            account_data => {
                client_loginid => $account->client_loginid,
                currency_code  => $account->currency_code,
            },
            transaction_data => [{
                    transaction_time => scalar $bet_data->{transaction_time},
                    staff_loginid    => scalar $bet_data->{staff_loginid},
                }
            ],
            bet_data => [$bet_data],
            db       => $connection_builder->db,
        })->batch_sell_bet;
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

## higher lower bet
my $short_code = 'PUT_FRXUSDJPY_2_1311570485_25_JUL_11_784600_0';
cmp_ok(scalar @{$clientdb->getall_arrayref('select * from bet.get_open_bets_of_account(?,?,?)', ['CR0021', 'USD', 'false'])},
    '==', 0, 'check qty open bet = 0');

# buy bet
my @fmb_id;
lives_ok {
    my ($fmb, $txn) = buy {
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
    push @fmb_id, $fmb->{id};
}
'buy a bet';
cmp_ok(scalar @{$clientdb->getall_arrayref('select * from bet.get_open_bets_of_account(?,?,?)', ['CR0021', 'USD', 'false'])},
    '==', 1, 'check qty open bet = 1. Bought one bet.');

# Manually close bet using batch sell
isnt scalar batch_sell({
        id         => shift(@fmb_id),
        sell_price => 20,
        sell_time  => '2011-07-25 23:59:59',
        quantity   => 1,
    }
    ),
    undef, 'sell 1 bet';
cmp_ok(scalar @{$clientdb->getall_arrayref('select * from bet.get_open_bets_of_account(?,?,?)', ['CR0021', 'USD', 'false'])},
    '==', 0, 'check qty open bet = 0. Successfully close txn manually');

1;
