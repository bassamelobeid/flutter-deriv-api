#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 28;
use Test::Warnings;
use Test::Exception;

use BOM::User::Client;

use BOM::Database::ClientDB;
use BOM::Database::Helper::FinancialMarketBet;
use BOM::Database::Model::FinancialMarketBet::Factory;
use BOM::Platform::Client::IDAuthentication;
use BOM::User::Password;

use BOM::Test::Helper::Client qw( create_client top_up );

Crypt::NamedKeys->keyfile('/etc/rmg/aes_keys.yml');

sub db {
    return BOM::Database::ClientDB->new({
            broker_code => 'CR',
        })->db;
}

sub buy_one_bet {
    my ($acc, $args) = @_;

    my $buy_price    = delete $args->{buy_price}    // 20;
    my $payout_price = delete $args->{payout_price} // $buy_price * 10;
    my $limits       = delete $args->{limits};
    my $duration     = delete $args->{duration}     // '15s';

    my $now      = Date::Utility->new;
    my $bet_data = +{
        underlying_symbol => 'frxUSDJPY',
        payout_price      => $payout_price,
        buy_price         => $buy_price,
        remark            => 'Test Remark',
        purchase_time     => $now->db_timestamp,
        start_time        => $now->db_timestamp,
        expiry_time       => $now->plus_time_interval($duration)->db_timestamp,
        settlement_time   => $now->plus_time_interval($duration)->db_timestamp,
        is_expired        => 1,
        is_sold           => 0,
        bet_class         => 'higher_lower_bet',
        bet_type          => 'CALL',
        short_code        => ('CALL_R_50_' . $payout_price . '_' . $now->epoch . '_' . $now->plus_time_interval($duration)->epoch . '_S0P_0'),
        relative_barrier  => 'S0P',
        quantity          => 1,
        %$args,
    };

    my $fmb = BOM::Database::Helper::FinancialMarketBet->new({
            bet_data     => $bet_data,
            account_data => {
                client_loginid => $acc->client_loginid,
                currency_code  => $acc->currency_code
            },
            limits => $limits,
            db     => db,
        });
    my ($bet, $txn) = $fmb->buy_bet;
    # note explain [$bet, $txn];
    return ($txn->{id}, $bet->{id}, $txn->{balance_after});
}
my $buy_multiple_shortcode;

sub buy_multiple_bets {
    my ($acc) = @_;

    my $now = Date::Utility->new;
    $buy_multiple_shortcode = ('CALL_R_50_200_' . $now->epoch . '_' . $now->plus_time_interval('15s')->epoch . '_S0P_0'),
        my $bet_data = +{
        underlying_symbol => 'frxUSDJPY',
        payout_price      => 200,
        buy_price         => 20,
        quantity          => 1,
        remark            => 'Test Remark',
        purchase_time     => $now->db_timestamp,
        start_time        => $now->db_timestamp,
        expiry_time       => $now->plus_time_interval('15s')->db_timestamp,
        settlement_time   => $now->plus_time_interval('15s')->db_timestamp,
        is_expired        => 1,
        is_sold           => 0,
        bet_class         => 'higher_lower_bet',
        bet_type          => 'CALL',
        short_code        => $buy_multiple_shortcode,
        relative_barrier  => 'S0P',
        quantity          => 1,
        };

    my $fmb = BOM::Database::Helper::FinancialMarketBet->new({
        bet_data     => $bet_data,
        account_data => [map { +{client_loginid => $_->client_loginid, currency_code => $_->currency_code} } @$acc],
        limits       => undef,
        transaction_data => {staff_loginid => 'CL001'},
        db               => db,
    });
    my $res = $fmb->batch_buy_bet;
    # note explain [$res];
    return $res;
}

sub sell_by_shortcode {
    my ($shortcode, $acc) = @_;

    my $now = Date::Utility->new->plus_time_interval('1s');

    my $fmb = BOM::Database::Helper::FinancialMarketBet->new({
            bet_data => +{
                'sell_price' => '18',
                'sell_time'  => $now->db_timestamp,
                'id'         => undef,
                'quantity'   => 1,
            },
            account_data     => [map           { +{client_loginid => $_->client_loginid, currency_code => $_->currency_code} } @$acc],
            transaction_data => {staff_loginid => 'CL001'},
            db               => db,
        });
    my $res = $fmb->sell_by_shortcode($shortcode);

    return $res;
}

sub sell_one_bet {
    my ($acc, $args) = @_;

    my $fmb = BOM::Database::Helper::FinancialMarketBet->new({
            bet_data     => $args,
            account_data => {
                client_loginid => $acc->client_loginid,
                currency_code  => $acc->currency_code
            },
            db => db,
        });
    my ($bet, $txn) = $fmb->sell_bet;
    # note explain [$bet, $txn];
    return ($txn->{id}, $bet->{id}, $txn->{balance_after});
}

my $cl;
my $acc_usd;
my $acc_aud;

####################################################################
# real tests begin here
####################################################################

my $bal;
lives_ok {
    $cl = create_client;

    top_up $cl, 'USD', 15000;
    isnt + ($acc_usd = $cl->account), undef, 'got USD account';

    is + ($bal = $acc_usd->balance + 0), 15000, 'USD balance is 15000 got: ' . $bal;
}
'client funded';

lives_ok {
    my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd;
    $bal -= 20;
    is $balance_after + 0, $bal, 'correct balance_after';
}
'bought USD bet';

lives_ok {
    my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd;
    $bal -= 20;
    is $balance_after + 0, $bal, 'correct balance_after';
}
'bought 2nd USD bet';

dies_ok {
    my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
        +{
        limits => {
            max_open_bets => 2,
        },
        };
}
'exception thrown';
is_deeply $@,
    [
    BI002 => 'ERROR:  maximum self-exclusion number of open contracts exceeded',
    ],
    'max_open_bets reached';

# bought 2 bets before, sum turnover = 20 + 20, which exceeds max_turnover
dies_ok {
    my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
        +{
        limits => {
            max_turnover => 39,
        },
        };
}
'exception thrown';
is_deeply $@,
    [
    BI001 => 'ERROR:  maximum self-exclusion turnover limit exceeded',
    ],
    'max_turnover reached';

lives_ok {
    my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
        +{
        limits => {
            max_turnover => 100,
        },
        };
    $bal -= 20;
    is $balance_after + 0, $bal, 'correct balance_after';
    sell_one_bet $acc_usd,
        {
        id         => $fmbid,
        sell_price => 0,
        sell_time  => Date::Utility->new->plus_time_interval('1s')->db_timestamp,
        quantity   => 1,
        };
}
'bought and sold one more bet with slightly increased max_turnover';

# at this point we have 2 open contracts: USD 20 + USD 20.
# we have 1 lost contract for USD 20.
# As for max_losses test, we need to sum up
#   a) all open bets as losses
#   b) current realized losses
#   c) current contract
#
# which is: 40 (open) + 20 (realized) + 10000 (current) = 10060

dies_ok {
    my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
        +{
        buy_price => 10000,
        limits    => {
            max_losses    => 10059,
            max_open_bets => 3,
        },
        };
}
'exception thrown';
is_deeply $@,
    [
    BI012 => 'ERROR:  maximum self-exclusion limit on daily losses reached',
    ],
    'max_losses reached';

my $buy_price;
lives_ok {
    $buy_price = 10000;
    my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
        +{
        buy_price => $buy_price,
        limits    => {
            max_losses    => 10100,
            max_open_bets => 3,
        },
        };
    $bal -= $buy_price;
    is $balance_after + 0, $bal, 'correct balance_after';
}
'bought one more USD bet with slightly increased max_losses' or diag Dumper($@);

dies_ok {
    my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
        +{
        limits => {
            max_open_bets => 3,
        },
        };
}
'exception thrown';
is_deeply $@,
    [
    BI002 => 'ERROR:  maximum self-exclusion number of open contracts exceeded',
    ],
    'to be sure the previous bet was the last possible';

dies_ok {
    my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
        +{
        buy_price => $bal + 0.01,
        };
}
'exception thrown';
is_deeply $@,
    [
    BI003 => 'ERROR:  insufficient balance, need: 0.01, #open_bets: 0, pot_payout: 0',
    ],
    'insufficient balance';

my $sell_price;

subtest 'more validation', sub {
    my @usd_bets;

    lives_ok {
        $cl = create_client;

        top_up $cl, 'USD', 10000;
        isnt + ($acc_usd = $cl->account), undef, 'got USD account';
        is + ($bal = $acc_usd->balance + 0), 10000, 'USD balance is 10000 got: ' . $bal;
    }
    'setup new client';

    dies_ok {
        my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
            +{
            limits => {
                max_balance => 10000 - 0.01,
            },
            };
    }
    'cannot buy due to max_balance';
    is_deeply $@,
        [
        BI008 => 'ERROR:  client balance upper limit exceeded',
        ],
        'client balance upper limit exceeded';

    lives_ok {
        my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
            +{
            limits => {
                max_balance => 10000,
            },
            };

        $bal -= 20;
        push @usd_bets, $fmbid;
        is $balance_after + 0, $bal, 'correct balance_after';
    }
    'can still buy when balance is exactly at max_balance';

    lives_ok {
        my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd;
        $bal -= 20;
        push @usd_bets, $fmbid;
        is $balance_after + 0, $bal, 'correct balance_after';

        $txnid = sell_one_bet $acc_usd,
            +{
            id         => $fmbid,
            sell_price => 0,
            sell_time  => Date::Utility->new->plus_time_interval('1s')->db_timestamp,
            quantity   => 1,
            };
    }
    'buy & sell a bet';

    dies_ok {
        my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
            +{
            limits => {
                max_payout_open_bets => 400 - 0.01,
            },
            };
    }
    'cannot buy due to max_payout_open_bets';
    is_deeply $@,
        [
        BI009 => 'ERROR:  maximum net payout for open positions reached',
        ],
        'maximum net payout for open positions reached';

    lives_ok {
        my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
            +{
            limits => {
                max_payout_open_bets => 400,
            },
            };
        $bal -= 20;
        push @usd_bets, $fmbid;
        is $balance_after + 0, $bal, 'correct balance_after';
    }
    'can buy when summary open payout is exactly at max_payout_open_bets';

    dies_ok {
        my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
            +{
            limits => {
                max_payout_open_bets => 400 - 0.01,
            },
            };
    }
    'cannot buy due to max_payout_open_bets -- just to be sure';
    is_deeply $@,
        [
        BI009 => 'ERROR:  maximum net payout for open positions reached',
        ],
        'maximum net payout for open positions reached';

    # the USD account has 3 bets here, 2 of which are unsold. Let's sell them all.
    my $total_bets  = 3;
    my $unsold_bets = 2;
    my $sold_bets   = $total_bets - $unsold_bets;
    lives_ok {
        my @bets_to_sell =
            map { {id => $_, quantity => 1, sell_price => 30, sell_time => Date::Utility->new->plus_time_interval('1s')->db_timestamp,} } @usd_bets;

        my @qvs = (
            BOM::Database::Model::DataCollection::QuantsBetVariables->new({
                    data_object_params => {theo => 0.02},
                })) x @bets_to_sell;

        my $fmb = BOM::Database::Helper::FinancialMarketBet->new({
                bet_data             => \@bets_to_sell,
                quants_bet_variables => \@qvs,
                account_data         => {
                    client_loginid => $acc_usd->client_loginid,
                    currency_code  => $acc_usd->currency_code
                },
                db => db,
            });

        my $res = $fmb->batch_sell_bet;

        # note explain $res;
        $bal += $unsold_bets * 30;
        is 0 + @$res, $unsold_bets, "sold $unsold_bets out of $total_bets bets ($sold_bets was already sold)";
        is $res->[0]->{txn}->{balance_after} + 0, $bal, 'balance_after';
    }
    "batch-sell $unsold_bets bets";
};

SKIP: {
    my @gmtime = gmtime;
    skip 'at least one minute must be left before mignight', 5
        if $gmtime[1] > 58 and $gmtime[2] == 23;

    subtest 'specific turnover validation', sub {
        lives_ok {
            $cl = create_client;

            top_up $cl, 'USD', 10000;
            isnt + ($acc_usd = $cl->account), undef, 'got USD account';
            is + ($bal = $acc_usd->balance + 0), 10000, 'USD balance is 10000 got: ' . $bal;
        }
        'setup new client';

        my @bets_to_sell;
        lives_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd;
            $bal -= 20;
            push @bets_to_sell, [$acc_usd, $fmbid];
            is $balance_after + 0, $bal, 'correct balance_after';

            ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                tick_count => 19,
                };
            $bal -= 20;
            push @bets_to_sell, [$acc_usd, $fmbid];
            is $balance_after + 0, $bal, 'correct balance_after';

            ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                underlying_symbol => 'R_50',
                };
            $bal -= 20;
            push @bets_to_sell, [$acc_usd, $fmbid];
            is $balance_after + 0, $bal, 'correct balance_after';

            ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                bet_type => 'CLUB',
                };
            $bal -= 20;
            push @bets_to_sell, [$acc_usd, $fmbid];
            is $balance_after + 0, $bal, 'correct balance_after';
        }
        'buy a few bets';

        lives_ok {
            while (@bets_to_sell) {
                my ($acc, $fmbid) = @{shift @bets_to_sell};
                my $txnid = sell_one_bet $acc,
                    +{
                    id         => $fmbid,
                    sell_price => 0,
                    sell_time  => Date::Utility->new->plus_time_interval('1s')->db_timestamp,
                    quantity   => 1,
                    };
            }
        }
        'and sell them for 0';

        # We have a turnover of USD 80
        # And since all those bets are losses we have a net loss of USD 80.
        # Also, there are no open bets. So, the loss limit is
        #       80 + 20 (current contract)
        dies_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd, +{
                limits => {
                    max_turnover             => 100 - 0.01,
                    max_losses               => 100 - 0.01,
                    specific_turnover_limits => [{    # fails
                            bet_type => [qw/CALL PUT DUMMY CLUB/],
                            symbols  => [qw/frxUSDJPY frxUSDGBP R_50/],
                            limit    => 100 - 0.01,
                            name     => 'test1',
                        },
                        {    # passes
                            bet_type => [qw/CALL PUT DUMMY CLUB/],
                            symbols  => [qw/frxUSDJPY frxUSDGBP R_50/],
                            limit    => 100,
                            name     => 'test2',
                        },
                        {    # fails (leave out the CLUB bet above)
                            bet_type => [qw/CALL PUT DUMMY/],
                            limit    => 80 - 0.01,
                            name     => 'test3',
                        },
                        {    # passes (leave out the CLUB bet above)
                            bet_type => [qw/CALL PUT DUMMY/],
                            limit    => 80,
                            name     => 'test4',
                        },
                        {    # fails (count only the one bet w/ tick_count, USD 20 + USD 20 for the bet to be bought => limit=40)
                            tick_expiry => 1,
                            limit       => 40 - 0.01,
                            name        => 'test5',
                        },
                        {    # passes  (count only the one bet w/ tick_count, USD 20 + USD 20 for the bet to be bought => limit=40)
                            tick_expiry => 1,
                            limit       => 40,
                            name        => 'test6',
                        },
                        {    # fails (count only the one bet w/ sym=R_50, USD 20 + USD 20 for the bet to be bought => limit=40)
                            symbols => [qw/hugo R_50/],
                            limit   => 40 - 0.01,
                            name    => 'test7',
                        },
                        {    # passes  (count only the one bet w/ sym=R_50, USD 20 + USD 20 for the bet to be bought => limit=40)
                            symbols => [qw/hugo R_50/],
                            limit   => 40,
                            name    => 'test8',
                        },
                    ],
                },
            };
        }
        'max_turnover validation failed';
        is_deeply $@,
            [
            BI001 => 'ERROR:  maximum self-exclusion turnover limit exceeded',
            ],
            'max_turnover exception';

        dies_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd, +{
                limits => {
                    max_turnover             => 100,
                    max_losses               => 100 - 0.01,
                    specific_turnover_limits => [{    # fails
                            bet_type => [qw/CALL PUT DUMMY CLUB/],
                            symbols  => [qw/frxUSDJPY frxUSDGBP R_50/],
                            limit    => 100 - 0.01,
                            name     => 'test1',
                        },
                        {    # passes
                            bet_type => [qw/CALL PUT DUMMY CLUB/],
                            symbols  => [qw/frxUSDJPY frxUSDGBP R_50/],
                            limit    => 100,
                            name     => 'test2',
                        },
                        {    # fails (leave out the CLUB bet above)
                            bet_type => [qw/CALL PUT DUMMY/],
                            limit    => 80 - 0.01,
                            name     => 'test3',
                        },
                        {    # passes (leave out the CLUB bet above)
                            bet_type => [qw/CALL PUT DUMMY/],
                            limit    => 80,
                            name     => 'test4',
                        },
                        {    # fails (count only the one bet w/ tick_count, USD 20 + USD 20 for the bet to be bought => limit=40)
                            tick_expiry => 1,
                            limit       => 40 - 0.01,
                            name        => 'test5',
                        },
                        {    # passes  (count only the one bet w/ tick_count, USD 20 + USD 20 for the bet to be bought => limit=40)
                            tick_expiry => 1,
                            limit       => 40,
                            name        => 'test6',
                        },
                        {    # fails (count only the one bet w/ sym=R_50, USD 20 + USD 20 for the bet to be bought => limit=40)
                            symbols => [qw/hugo R_50/],
                            limit   => 40 - 0.01,
                            name    => 'test7',
                        },
                        {    # passes  (count only the one bet w/ sym=R_50, USD 20 + USD 20 for the bet to be bought => limit=40)
                            symbols => [qw/hugo R_50/],
                            limit   => 40,
                            name    => 'test8',
                        },
                    ],
                },
            };
        }
        'max_losses validation failed';
        is_deeply $@,
            [
            BI012 => 'ERROR:  maximum self-exclusion limit on daily losses reached',
            ],
            'max_losses exception';

        dies_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd, +{
                limits => {
                    max_turnover             => 100,
                    max_losses               => 100,
                    specific_turnover_limits => [{    # fails
                            bet_type => [qw/CALL PUT DUMMY CLUB/],
                            symbols  => [qw/frxUSDJPY frxUSDGBP R_50/],
                            limit    => 100 - 0.01,
                            name     => 'test1',
                        },
                        {    # passes
                            bet_type => [qw/CALL PUT DUMMY CLUB/],
                            symbols  => [qw/frxUSDJPY frxUSDGBP R_50/],
                            limit    => 100,
                            name     => 'test2',
                        },
                        {    # fails (leave out the CLUB bet above)
                            bet_type => [qw/CALL PUT DUMMY/],
                            limit    => 80 - 0.01,
                            name     => 'test3',
                        },
                        {    # passes (leave out the CLUB bet above)
                            bet_type => [qw/CALL PUT DUMMY/],
                            limit    => 80,
                            name     => 'test4',
                        },
                        {    # fails (count only the one bet w/ tick_count, USD 20 + USD 20 for the bet to be bought => limit=40)
                            tick_expiry => 1,
                            limit       => 40 - 0.01,
                            name        => 'test5',
                        },
                        {    # passes  (count only the one bet w/ tick_count, USD 20 + USD 20 for the bet to be bought => limit=40)
                            tick_expiry => 1,
                            limit       => 40,
                            name        => 'test6',
                        },
                        {    # fails (count only the one bet w/ sym=R_50, USD 20 + USD 20 for the bet to be bought => limit=40)
                            symbols => [qw/hugo R_50/],
                            limit   => 40 - 0.01,
                            name    => 'test7',
                        },
                        {    # passes  (count only the one bet w/ sym=R_50, USD 20 + USD 20 for the bet to be bought => limit=40)
                            symbols => [qw/hugo R_50/],
                            limit   => 40,
                            name    => 'test8',
                        },
                    ],
                },
            };
        }
        'specific turnover validation failed';
        is_deeply $@,
            [
            BI011 => 'ERROR:  specific turnover limit reached: test1, test3, test5, test7',
            ],
            'specific turnover limit reached: test1, test3, test5, test7';

        dies_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd, +{
                expiry_daily => 1,
                limits       => {
                    max_turnover             => 100,
                    max_losses               => 100,
                    specific_turnover_limits => [{    # fails
                            bet_type => [qw/CALL PUT DUMMY CLUB/],
                            symbols  => [qw/frxUSDJPY frxUSDGBP R_50/],
                            limit    => 20 - 0.01,
                            daily    => 1,
                            name     => 'test1',
                        },
                        {    # passes
                            bet_type => [qw/CALL PUT DUMMY CLUB/],
                            symbols  => [qw/frxUSDJPY frxUSDGBP R_50/],
                            limit    => 20,
                            daily    => 1,
                            name     => 'test2',
                        },
                    ],
                },
            };
        }
        'specific turnover validation failed';
        is_deeply $@,
            [
            BI011 => 'ERROR:  specific turnover limit reached: test1',
            ],
            'specific turnover limit reached: test1';

        dies_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd, +{
                limits => {
                    max_turnover             => 100,
                    max_losses               => 100,
                    specific_turnover_limits => [{    # passes
                            bet_type => [qw/CALL PUT DUMMY CLUB/],
                            symbols  => [qw/frxUSDJPY frxUSDGBP R_50/],
                            limit    => 100 - 0.01,
                            daily    => 1,
                            name     => 'test1',
                        },
                        {    # fails
                            bet_type => [qw/CALL PUT DUMMY CLUB/],
                            symbols  => [qw/frxUSDJPY frxUSDGBP R_50/],
                            limit    => 100 - 0.01,
                            daily    => 0,
                            name     => 'test2',
                        },
                        {    # passes
                            bet_type => [qw/CALL PUT DUMMY CLUB/],
                            symbols  => [qw/frxUSDJPY frxUSDGBP R_50/],
                            limit    => 100,
                            daily    => 0,
                            name     => 'test1',
                        },
                    ],
                },
            };
        }
        'specific turnover validation failed';
        is_deeply $@,
            [
            BI011 => 'ERROR:  specific turnover limit reached: test2',
            ],
            'specific turnover limit reached: test2';

        lives_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd, +{
                limits => {
                    max_turnover             => 100,
                    max_losses               => 100,
                    specific_turnover_limits => [{    # passes
                            bet_type => [qw/CALL PUT DUMMY CLUB/],
                            symbols  => [qw/frxUSDJPY frxUSDGBP R_50/],
                            limit    => 100,
                            name     => 'test2',
                        },
                        {    # passes (leave out the CLUB bet above)
                            bet_type => [qw/CALL PUT DUMMY/],
                            limit    => 80,
                            name     => 'test4',
                        },
                        {    # passes  (count only the one bet w/ tick_count, USD 20 + USD 20 for the bet to be bought => limit=40)
                            tick_expiry => 1,
                            limit       => 40,
                            name        => 'test6',
                        },
                        {    # passes  (count only the one bet w/ sym=R_50, USD 20 + USD 20 for the bet to be bought => limit=40)
                            symbols => [qw/hugo R_50/],
                            limit   => 40,
                            name    => 'test8',
                        },
                    ],
                },
            };
            $bal -= 20;
            is $balance_after + 0, $bal, 'correct balance_after';
        }
        'specific turnover validation succeeded';
    };

    subtest '7day limits', sub {
        lives_ok {
            $cl = create_client;

            top_up $cl, 'USD', 10000;
            isnt + ($acc_usd = $cl->account), undef, 'got USD account';
            is + ($bal = $acc_usd->balance + 0), 10000, 'USD balance is 10000 got: ' . $bal;
        }
        'setup new client';

        my $today        = Date::Utility::today;
        my $_6daysbefore = $today->minus_time_interval('6d');

        note "today = " . $today->db_timestamp . ", _6daysbefore = " . $_6daysbefore->db_timestamp;

        my @bets_to_sell;
        lives_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                purchase_time => $_6daysbefore->minus_time_interval('1s')->db_timestamp,
                };
            $bal -= 20;
            push @bets_to_sell, [$acc_usd, $fmbid];
            is $balance_after + 0, $bal, 'correct balance_after';

            ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                purchase_time => $_6daysbefore->minus_time_interval('1s')->db_timestamp,
                };
            $bal -= 20;
            push @bets_to_sell, [$acc_usd, $fmbid];
            is $balance_after + 0, $bal, 'correct balance_after';

            ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                purchase_time => $_6daysbefore->db_timestamp,
                };
            $bal -= 20;
            push @bets_to_sell, [$acc_usd, $fmbid];
            is $balance_after + 0, $bal, 'correct balance_after';

            ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                purchase_time => $_6daysbefore->db_timestamp,
                };
            $bal -= 20;
            push @bets_to_sell, [$acc_usd, $fmbid];
            is $balance_after + 0, $bal, 'correct balance_after';

            ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                purchase_time => $today->db_timestamp,
                };
            $bal -= 20;
            push @bets_to_sell, [$acc_usd, $fmbid];
            is $balance_after + 0, $bal, 'correct balance_after';

            ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                purchase_time => $today->db_timestamp,
                };
            $bal -= 20;
            push @bets_to_sell, [$acc_usd, $fmbid];
            is $balance_after + 0, $bal, 'correct balance_after';
        }
        'buy a few bets';

        lives_ok {
            while (@bets_to_sell) {
                my ($acc, $fmbid) = @{shift @bets_to_sell};
                my $txnid = sell_one_bet $acc,
                    +{
                    id         => $fmbid,
                    sell_price => 0,
                    sell_time  => Date::Utility->new->plus_time_interval('1s')->db_timestamp,
                    quantity   => 1,
                    };
            }
        }
        'and sell them for 0';

        # Here we have 6 bought and sold bets. Two of them
        # were bought before the time interval considered by the 7day limits. In total, we
        # have a worth of USD 80 turnover and losses within the 7day interval.
        # There are no open bets. So, the loss limit is:
        #
        #     80 (realized loss) + 20 (current contract)

        dies_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                limits => {
                    max_7day_turnover => 100 - 0.01,
                    max_7day_losses   => 100 - 0.01,
                },
                };
        }
        '7day turnover validation failed';
        is_deeply $@,
            [
            BI013 => 'ERROR:  maximum self-exclusion 7 day turnover limit exceeded',
            ],
            'maximum self-exclusion 7 day turnover limit exceeded';

        dies_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                limits => {
                    max_7day_turnover => 100,
                    max_7day_losses   => 100 - 0.01,
                },
                };
        }
        '7day turnover validation failed';
        is_deeply $@,
            [
            BI014 => 'ERROR:  maximum self-exclusion 7 day limit on losses exceeded',
            ],
            'maximum self-exclusion 7 day limit on losses exceeded';

        lives_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                limits => {
                    max_7day_turnover => 100,
                    max_7day_losses   => 100,
                },
                };
            $bal -= 20;
            is $balance_after + 0, $bal, 'correct balance_after';
        }
        '7day turnover validation passed with slightly higher limits';

        # now we have one open bet for USD 20. So, we should raise the limits
        # accordingly to buy the next

        dies_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                limits => {
                    max_7day_turnover => 120 - 0.01,
                    max_7day_losses   => 120 - 0.01,
                },
                };
        }
        '7day turnover validation failed (with open bet)';
        is_deeply $@,
            [
            BI013 => 'ERROR:  maximum self-exclusion 7 day turnover limit exceeded',
            ],
            'maximum self-exclusion 7 day turnover limit exceeded (with open bet)';

        dies_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                limits => {
                    max_7day_turnover => 120,
                    max_7day_losses   => 120 - 0.01,
                },
                };
        }
        '7day turnover validation failed (with open bet)';
        is_deeply $@,
            [
            BI014 => 'ERROR:  maximum self-exclusion 7 day limit on losses exceeded',
            ],
            'maximum self-exclusion 7 day limit on losses exceeded (with open bet)';

        lives_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                limits => {
                    max_7day_turnover => 120,
                    max_7day_losses   => 120,
                },
                };
            $bal -= 20;
            is $balance_after + 0, $bal, 'correct balance_after';
        }
        '7day turnover validation passed with slightly higher limits (with open bet)';
    };

    subtest '30day limits', sub {
        lives_ok {
            $cl = create_client;

            top_up $cl, 'USD', 10000;
            isnt + ($acc_usd = $cl->account), undef, 'got USD account';
            is + ($bal = $acc_usd->balance + 0), 10000, 'USD balance is 10000 got: ' . $bal;
        }
        'setup new client';

        my $today         = Date::Utility::today;
        my $_29daysbefore = $today->minus_time_interval('29d');

        note "today = " . $today->db_timestamp . ", _29daysbefore = " . $_29daysbefore->db_timestamp;

        my @bets_to_sell;
        lives_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                purchase_time => $_29daysbefore->minus_time_interval('1s')->db_timestamp,
                };
            $bal -= 20;
            push @bets_to_sell, [$acc_usd, $fmbid];
            is $balance_after + 0, $bal, 'correct balance_after';

            ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                purchase_time => $_29daysbefore->minus_time_interval('1s')->db_timestamp,
                };
            $bal -= 20;
            push @bets_to_sell, [$acc_usd, $fmbid];
            is $balance_after + 0, $bal, 'correct balance_after';

            ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                purchase_time => $_29daysbefore->db_timestamp,
                };
            $bal -= 20;
            push @bets_to_sell, [$acc_usd, $fmbid];
            is $balance_after + 0, $bal, 'correct balance_after';

            ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                purchase_time => $_29daysbefore->db_timestamp,
                };
            $bal -= 20;
            push @bets_to_sell, [$acc_usd, $fmbid];
            is $balance_after + 0, $bal, 'correct balance_after';

            ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                purchase_time => $today->db_timestamp,
                };
            $bal -= 20;
            push @bets_to_sell, [$acc_usd, $fmbid];
            is $balance_after + 0, $bal, 'correct balance_after';

            ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                purchase_time => $today->db_timestamp,
                };
            $bal -= 20;
            push @bets_to_sell, [$acc_usd, $fmbid];
            is $balance_after + 0, $bal, 'correct balance_after';
        }
        'buy a few bets';

        lives_ok {
            while (@bets_to_sell) {
                my ($acc, $fmbid) = @{shift @bets_to_sell};
                my $txnid = sell_one_bet $acc,
                    +{
                    id         => $fmbid,
                    sell_price => 0,
                    sell_time  => Date::Utility->new->plus_time_interval('1s')->db_timestamp,
                    quantity   => 1,
                    };
            }
        }
        'and sell them for 0';

        # Here we have 6 bought and sold bets. Two of them
        # were bought before the time interval considered by the 30day limits. In total, we
        # have a worth of USD 120 turnover and losses within the 30day interval.
        # There are no open bets. So, the loss limit is:
        #
        #     80 (realized loss) + 20 (current contract)

        dies_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                limits => {
                    max_30day_turnover => 100 - 0.01,
                    max_30day_losses   => 100 - 0.01,
                },
                };
        }
        '30day turnover validation failed';
        is_deeply $@,
            [
            BI016 => 'ERROR:  maximum self-exclusion 30 day turnover limit exceeded',
            ],
            'maximum self-exclusion 30 day turnover limit exceeded';

        dies_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                limits => {
                    max_30day_turnover => 100,
                    max_30day_losses   => 100 - 0.01,
                },
                };
        }
        '30day turnover validation failed';
        is_deeply $@,
            [
            BI017 => 'ERROR:  maximum self-exclusion 30 day limit on losses exceeded',
            ],
            'maximum self-exclusion 30 day limit on losses exceeded';

        lives_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                limits => {
                    max_30day_turnover => 100,
                    max_30day_losses   => 100,
                },
                };
            $bal -= 20;
            is $balance_after + 0, $bal, 'correct balance_after';
        }
        '30day turnover validation passed with slightly higher limits';

        # now we have one open bet for USD 20. So, we should raise the limits
        # accordingly to buy the next

        dies_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                limits => {
                    max_30day_turnover => 120 - 0.01,
                    max_30day_losses   => 120 - 0.01,
                },
                };
        }
        '30day turnover validation failed (with open bet)';
        is_deeply $@,
            [
            BI016 => 'ERROR:  maximum self-exclusion 30 day turnover limit exceeded',
            ],
            'maximum self-exclusion 30 day turnover limit exceeded (with open bet)';

        dies_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                limits => {
                    max_30day_turnover => 120,
                    max_30day_losses   => 120 - 0.01,
                },
                };
        }
        '30day turnover validation failed (with open bet)';
        is_deeply $@,
            [
            BI017 => 'ERROR:  maximum self-exclusion 30 day limit on losses exceeded',
            ],
            'maximum self-exclusion 30 day limit on losses exceeded (with open bet)';

        lives_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                limits => {
                    max_30day_turnover => 120,
                    max_30day_losses   => 120,
                },
                };
            $bal -= 20;
            is $balance_after + 0, $bal, 'correct balance_after';
        }
        '30day turnover validation passed with slightly higher limits (with open bet)';
    };

    subtest 'max_profit', sub {
        lives_ok {
            $cl = create_client;

            top_up $cl, 'USD', 10000;
            isnt + ($acc_usd = $cl->account), undef, 'got USD account';
            is + ($bal = $acc_usd->balance + 0), 10000, 'USD balance is 10000 got: ' . $bal;
        }
        'setup new client';

        my $today = Date::Utility::today;

        note "today = " . $today->db_timestamp;

        my @bets_to_sell;
        lives_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                purchase_time => $today->minus_time_interval('1s')->db_timestamp,
                };
            $bal -= 20;
            push @bets_to_sell, [$acc_usd, $fmbid];
            is $balance_after + 0, $bal, 'correct balance_after';

            ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                purchase_time => $today->db_timestamp,
                };
            $bal -= 20;
            push @bets_to_sell, [$acc_usd, $fmbid];
            is $balance_after + 0, $bal, 'correct balance_after';

            ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                purchase_time => $today->plus_time_interval('1s')->db_timestamp,
                };
            $bal -= 20;
            push @bets_to_sell, [$acc_usd, $fmbid];
            is $balance_after + 0, $bal, 'correct balance_after';
        }
        'buy a few bets';

        lives_ok {
            while (@bets_to_sell) {
                my ($acc, $fmbid) = @{shift @bets_to_sell};
                my $txnid = sell_one_bet $acc,
                    +{
                    id         => $fmbid,
                    sell_price => 50,
                    sell_time  => Date::Utility->new->plus_time_interval('1s')->db_timestamp,
                    quantity   => 1,
                    };
                $bal += 50;
            }
        }
        'and sell them for 50';

        # here we have a realized profit for today of 60. We bought 3 bets each
        # for 20 and sold them for 50. So, each bet brought 30 profit. But the
        # first bet was bought as of yesterday.
        # buy_price is 20, payout 60. So, we have a potential profit of
        # 60 - 20 = 40.
        #
        # limit = realized_profit + potential_profit
        #       = 60 + 40 = 100

        dies_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                payout_price => 60,
                limits       => {
                    max_daily_profit => 100 - 0.01,
                },
                };
        }
        'max_profit';
        is_deeply $@,
            [
            BI018 => 'ERROR:  maximum daily profit limit exceeded',
            ],
            'maximum daily profit limit exceeded';

        lives_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                payout_price => 60,
                limits       => {
                    max_daily_profit => 100,
                },
                };
            $bal -= 20;
            is $balance_after + 0, $bal, 'correct balance_after';
        }
        'max_daily_profit passed with slightly higher limits';

        # here we have a realized profit for today of 60. We bought 3 bets each
        # for 20 and sold them for 50. So, each bet brought 30 profit. But the
        # first bet was bought as of yesterday.

        # Further, we have one open bet with buy_price 20 and payout 60. Hence,
        # a potential profit of 40.

        # For this bet,
        # buy_price is 30, payout 60. So, we have a potential profit of
        # 60 - 30 = 30.
        #
        # limit = realized_profit + potential_profit
        #       = 60 + 40 + 30 = 130

        dies_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                buy_price    => 30,
                payout_price => 60,
                limits       => {
                    max_daily_profit => 130 - 0.01,
                },
                };
        }
        'max_profit';
        is_deeply $@,
            [
            BI018 => 'ERROR:  maximum daily profit limit exceeded',
            ],
            'maximum daily profit limit exceeded (with open bet)';

        lives_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                buy_price    => 30,
                payout_price => 60,
                limits       => {
                    max_daily_profit => 130,
                },
                };
            $bal -= 30;
            is $balance_after + 0, $bal, 'correct balance_after';
        }
        'max_daily_profit passed with slightly higher limits (with open bet)';

        # now let's repeat the same with 2 open bets to make sure aggregation works

        # We have two open bets with buy_price 20 and payout 60 and buy_price 30
        # and payout 60. Hence, a potential profit of 40 + 30 = 70.

        # For this bet,
        # buy_price is 30, payout 60. So, we have a potential profit of
        # 60 - 30 = 30.
        #
        # limit = realized_profit + potential_profit
        #       = 60 + 70 + 30 = 160

        dies_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                buy_price    => 30,
                payout_price => 60,
                limits       => {
                    max_daily_profit => 160 - 0.01,
                },
                };
        }
        'max_profit';
        is_deeply $@,
            [
            BI018 => 'ERROR:  maximum daily profit limit exceeded',
            ],
            'maximum daily profit limit exceeded (with 2 open bets)';

        lives_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                buy_price    => 30,
                payout_price => 60,
                limits       => {
                    max_daily_profit => 160,
                },
                };
            $bal -= 30;
            is $balance_after + 0, $bal, 'correct balance_after';
        }
        'max_daily_profit passed with slightly higher limits (with 2 open bets)';
    };
}

subtest 'batch_buy', sub {
    use DBD::Pg;
    use YAML::XS;

    my $config = YAML::XS::LoadFile('/etc/rmg/clientdb.yml');
    my $ip     = $config->{svg}->{write}->{ip};                 # create_client creates CR clients
    my $db     = $config->{svg}->{write}->{dbname};             # create_client creates CR clients
    my $pw     = $config->{password};
    my $port   = $ENV{DB_TEST_PORT} // 5432;

    my $listener = DBI->connect(
        "dbi:Pg:dbname=$db;host=$ip;port=$port;application_name=notify_pub",
        'write', $pw,
        {
            AutoCommit => 1,
            RaiseError => 1,
            PrintError => 0
        });

    my ($cl1, $cl2, $cl3, $cl4, $acc1, $acc2, $acc3, $acc4);
    lives_ok {
        $cl1 = create_client;
        $cl2 = create_client;
        $cl3 = create_client;
        $cl4 = create_client;

        top_up $cl1, 'USD', 5000;
        top_up $cl2, 'USD', 10;
        top_up $cl3, 'USD', 10000;
        top_up $cl4, 'AUD', 10000;

        isnt + ($acc1 = $cl1->account), undef, 'got 1st account';
        isnt + ($acc2 = $cl2->account), undef, 'got 2nd account';
        isnt + ($acc3 = $cl3->account), undef, 'got 3rd account';
        isnt + ($acc4 = $cl4->account), undef, 'got 4th account';
    }
    'setup clients';

    $listener->do("LISTEN transaction_watchers");
    my $buy_trx_ids = {};

    lives_ok {
        my $res = buy_multiple_bets [$acc1, $acc2, $acc3];
        # note explain $res;

        my %notifications;
        while (my $notify = $listener->pg_notifies) {
            # note "got notification: $notify->[-1]";
            my $n = {};
            @{$n}{
                qw/id account_id action_type referrer_type financial_market_bet_id payment_id amount balance_after transaction_time short_code currency_code purchase_time buy_price sell_time payment_remark/
                } =
                split ',', $notify->[-1];
            $notifications{$n->{id}} = $n;
        }
        # note explain \%notifications;

        my $acc     = $acc1;
        my $loginid = $acc->client_loginid;
        subtest 'testing result for ' . $loginid, sub {
            my $r = shift @$res;
            isnt $r, undef, 'got result hash';
            is $r->{loginid}, $loginid, 'found loginid';
            is $r->{e_code},        undef, 'e_code is undef';
            is $r->{e_description}, undef, 'e_description is undef';
            isnt $r->{fmb},         undef, 'got FMB';
            isnt $r->{txn},         undef, 'got TXN';

            my $fmb = $r->{fmb};
            is $fmb->{account_id}, $acc->id, 'fmb account id matches';

            my $txn = $r->{txn};
            $buy_trx_ids->{$txn->{id}} = 1;
            is $txn->{account_id}, $acc->id, 'txn account id matches';
            is $txn->{referrer_type}, 'financial_market_bet', 'txn referrer_type is financial_market_bet';
            is $txn->{financial_market_bet_id}, $fmb->{id}, 'txn fmb id matches';
            is $txn->{amount},        '-20.00',  'txn amount';
            is $txn->{balance_after}, '4980.00', 'txn balance_after';
            is $txn->{staff_loginid}, '#CL001',  'txn staff_loginid';

            my $note = $notifications{$txn->{id}};
            isnt $note, undef, 'found notification';
            is $note->{currency_code}, 'USD', "note{currency_code} eq USD";
            for my $name (qw/account_id action_type amount balance_after financial_market_bet_id transaction_time/) {
                is $note->{$name}, $txn->{$name}, "note{$name} eq txn{$name}";
            }
            for my $name (qw/buy_price purchase_time sell_time short_code/) {
                is $note->{$name}, $fmb->{$name}, "note{$name} eq fmb{$name}";
            }
        };

        $acc     = $acc2;
        $loginid = $acc->client_loginid;
        subtest 'testing result for ' . $loginid, sub {
            my $r = shift @$res;
            isnt $r, undef, 'got result hash';
            is $r->{loginid}, $loginid, 'found loginid';
            is $r->{e_code},          'BI003',                  'e_code is BI003';
            like $r->{e_description}, qr/insufficient balance/, 'e_description mentions insufficient balance';
            is $r->{fmb},             undef,                    'no FMB';
            is $r->{txn},             undef,                    'no TXN';
        };

        $acc     = $acc3;
        $loginid = $acc->client_loginid;
        subtest 'testing result for ' . $loginid, sub {
            my $r = shift @$res;
            isnt $r, undef, 'got result hash';
            is $r->{loginid}, $loginid, 'found loginid';
            is $r->{e_code},        undef, 'e_code is undef';
            is $r->{e_description}, undef, 'e_description is undef';
            isnt $r->{fmb},         undef, 'got FMB';
            isnt $r->{txn},         undef, 'got TXN';

            my $fmb = $r->{fmb};
            is $fmb->{account_id}, $acc->id, 'fmb account id matches';

            my $txn = $r->{txn};
            $buy_trx_ids->{$txn->{id}} = 1;
            is $txn->{account_id}, $acc->id, 'txn account id matches';
            is $txn->{referrer_type}, 'financial_market_bet', 'txn referrer_type is financial_market_bet';
            is $txn->{financial_market_bet_id}, $fmb->{id}, 'txn fmb id matches';
            is $txn->{amount},        '-20.00',  'txn amount';
            is $txn->{balance_after}, '9980.00', 'txn balance_after';
            is $txn->{staff_loginid}, '#CL001',  'txn staff_loginid';

            my $note = $notifications{$txn->{id}};
            isnt $note, undef, 'found notification';
            is $note->{currency_code}, 'USD', "note{currency_code} eq USD";
            for my $name (qw/account_id action_type amount balance_after financial_market_bet_id transaction_time/) {
                is $note->{$name}, $txn->{$name}, "note{$name} eq txn{$name}";
            }
            for my $name (qw/buy_price purchase_time sell_time short_code/) {
                is $note->{$name}, $fmb->{$name}, "note{$name} eq fmb{$name}";
            }
        };
    }
    'survived buy_multiple_bets';

    lives_ok {
        my $res = sell_by_shortcode($buy_multiple_shortcode, [$acc1, $acc2, $acc3]);
        # note explain $res;
        is ref $res, 'ARRAY';
        my $r = shift @$res;
        is ref $r, 'HASH';
        isnt $r->{fmb}, undef, 'got FMB';
        isnt $r->{txn}, undef, 'got TXN';
        ok $buy_trx_ids->{$r->{buy_tr_id}}, 'got buy transaction id';
        is $r->{txn}{financial_market_bet_id}, $r->{fmb}{id}, 'txn fmb id matches';
        is $r->{txn}{amount}, '18.00', 'txn amount';
        ok $r->{loginid}, 'got login id';

        $r = shift @$res;
        is ref $r, 'HASH';
        ok $r->{fmb},           'got FMB';
        ok $r->{txn},           'got TXN';
        is $r->{e_code},        'BI050', 'got error code';
        is $r->{e_description}, 'Contract not found', 'got error description';
        ok $r->{loginid},       'got login id';

        $r = shift @$res;
        is ref $r, 'HASH';
        isnt $r->{fmb}, undef, 'got FMB';
        isnt $r->{txn}, undef, 'got TXN';
        ok $buy_trx_ids->{$r->{buy_tr_id}}, 'got buy transaction id';
        is $r->{txn}{financial_market_bet_id}, $r->{fmb}{id}, 'txn fmb id matches';
        is $r->{txn}{amount}, '18.00', 'txn amount';
        ok $r->{loginid}, 'got login id';

    }
    'sell_by_shortcode';

    dies_ok {
        my $res = buy_multiple_bets [$acc1, $acc4, $acc3];
    }
    'buy_multiple_bets with differing currencies dies';
    # note "exception is $@";
    like $@, qr/^invalid currency/i, 'invalid currency';
};

done_testing;
