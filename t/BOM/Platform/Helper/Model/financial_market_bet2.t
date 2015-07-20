#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 31;
use Test::NoWarnings ();    # no END block test
use Test::Exception;
use BOM::Database::Helper::FinancialMarketBet;
use BOM::Platform::Client;
use BOM::Database::ClientDB;
use BOM::System::Password;
use BOM::Platform::Client::Utility;
use BOM::Database::Model::FinancialMarketBet::Factory;

sub db {
    return BOM::Database::ClientDB->new({
            broker_code => 'CR',
        })->db;
}

sub create_client {
    return BOM::Platform::Client->register_and_return_new_client({
        broker_code      => 'CR',
        client_password  => BOM::System::Password::hashpw('12345678'),
        salutation       => 'Mr',
        last_name        => 'Doe',
        first_name       => 'John' . time . '.' . int(rand 1000000000),
        email            => 'john.doe' . time . '.' . int(rand 1000000000) . '@test.domain.nowhere',
        residence        => 'in',
        address_line_1   => '298b md rd',
        address_line_2   => '',
        address_city     => 'Place',
        address_postcode => '65432',
        address_state    => 'st',
        phone            => '+9145257468',
        secret_question  => 'What the f***?',
        secret_answer    => BOM::Platform::Client::Utility::encrypt_secret_answer('is that'),
        date_of_birth    => '1945-08-06',
    });
}

sub top_up {
    my ($c, $cur, $amount) = @_;

    my $fdp = $c->is_first_deposit_pending;
    my @acc = $c->account;
    if (@acc) {
        @acc = grep { $_->currency_code eq $cur } @acc;
        @acc = $c->add_account({
                currency_code => $cur,
                is_default    => 0
            }) unless @acc;
    } else {
        @acc = $c->add_account({
            currency_code => $cur,
            is_default    => 1
        });
    }

    my $acc = $acc[0];
    unless (defined $acc->id) {
        $acc->save;
        note 'Created account ' . $acc->id . ' for ' . $c->loginid . ' segment ' . $cur;
    }

    my ($pm) = $acc->add_payment({
        amount               => $amount,
        payment_gateway_code => "legacy_payment",
        payment_type_code    => "ewallet",
        status               => "OK",
        staff_loginid        => "test",
        remark               => __FILE__ . ':' . __LINE__,
    });
    $pm->legacy_payment({legacy_type => "ewallet"});
    my ($trx) = $pm->add_transaction({
        account_id    => $acc->id,
        amount        => $amount,
        staff_loginid => "test",
        remark        => __FILE__ . ':' . __LINE__,
        referrer_type => "payment",
        action_type   => ($amount > 0 ? "deposit" : "withdrawal"),
        quantity      => 1,
    });
    $acc->save(cascade => 1);
    $trx->load;    # to re-read (get balance_after)

    BOM::Platform::Client::IDAuthentication->new(client => $c)->run_authentication
        if $fdp;

    note $c->loginid . "'s balance is now $cur " . $trx->balance_after . "\n";
}

sub free_gift {
    my ($c, $cur, $amount) = @_;

    my $fdp = $c->is_first_deposit_pending;
    my @acc = $c->account;
    if (@acc) {
        @acc = grep { $_->currency_code eq $cur } @acc;
        @acc = $c->add_account({
                currency_code => $cur,
                is_default    => 0
            }) unless @acc;
    } else {
        @acc = $c->add_account({
            currency_code => $cur,
            is_default    => 1
        });
    }

    my $acc = $acc[0];
    unless (defined $acc->id) {
        $acc->save;
        note 'Created account ' . $acc->id . ' for ' . $c->loginid . ' segment ' . $cur;
    }

    my ($pm) = $acc->add_payment({
        amount               => $amount,
        payment_gateway_code => "free_gift",
        payment_type_code    => "free_gift",
        status               => "OK",
        staff_loginid        => "test",
        remark               => __FILE__ . ':' . __LINE__,
    });
    $pm->free_gift({reason => "test"});
    my ($trx) = $pm->add_transaction({
        account_id    => $acc->id,
        amount        => $amount,
        staff_loginid => "test",
        remark        => __FILE__ . ':' . __LINE__,
        referrer_type => "payment",
        action_type   => ($amount > 0 ? "deposit" : "withdrawal"),
        quantity      => 1,
    });
    $acc->save(cascade => 1);
    $trx->load;    # to re-read (get balance_after)

    BOM::Platform::Client::IDAuthentication->new(client => $c)->run_authentication
        if $fdp;

    note $c->loginid . "'s balance is now $cur " . $trx->balance_after . "\n";
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
        is_expired        => 1,
        is_sold           => 0,
        bet_class         => 'higher_lower_bet',
        bet_type          => 'FLASHU',
        short_code        => ('FLASHU_R_50_' . $payout_price . '_' . $now->epoch . '_' . $now->plus_time_interval($duration)->epoch . '_S0P_0'),
        relative_barrier  => 'S0P',
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
    use Data::Dumper;
    diag "FMB: " . Dumper($fmb);
    my ($bet, $txn) = $fmb->buy_bet;
    # note explain [$bet, $txn];
    return ($txn->{id}, $bet->{id}, $txn->{balance_after});
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

lives_ok {
    # need to date the timestamps back at least for 1 second because
    # Date::Utility->new->epoch rounds down fractions of seconds.
    # Hence, "now()" might come after purchase_time.
    db->dbh->do(<<'SQL');
INSERT INTO data_collection.exchange_rate (source_currency, target_currency, date, rate)
VALUES ('USD', 'USD', now()-'1s'::INTERVAL, 1),
       ('AUD', 'USD', now()-'1s'::INTERVAL, 2),
       ('GBP', 'USD', now()-'1s'::INTERVAL, 4),
       ('EUR', 'USD', now()-'1s'::INTERVAL, 8)
SQL

    my $stmt = db->dbh->prepare(<<'SQL');
SELECT t.cur, t.val * exch.rate
FROM (VALUES ('USD', 80),
             ('AUD', 40),
             ('GBP', 20),
             ('EUR', 10)) t(cur, val)
CROSS JOIN data_collection.exchangeToUSD_rate(t.cur) exch(rate)
ORDER BY t.cur
SQL

    $stmt->execute;
    my $res = $stmt->fetchall_arrayref;

    note explain $res;
    is_deeply $res, [[AUD => '80.0000'], [EUR => '80.0000'], [GBP => '80.0000'], [USD => '80.0000'],], 'got correct exchange rates';
}
'setup exchange rates';

lives_ok {
    $cl = create_client;

    top_up $cl, 'USD', 10000;
    top_up $cl, 'AUD', 10000;
    top_up $cl, 'USD', 5000;

    isnt + ($acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';
    isnt + ($acc_aud = $cl->find_account(query => [currency_code => 'AUD'])->[0]), undef, 'got AUD account';

    my $bal;
    is + ($bal = $acc_usd->balance + 0), 15000, 'USD balance is 15000 got: ' . $bal;
    is + ($bal = $acc_aud->balance + 0), 10000, 'AUD balance is 10000 got: ' . $bal;
}
'client with 2 segments created and funded';

lives_ok {
    my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd;
    is $balance_after + 0, 15000 - 20, 'correct balance_after';
}
'bought USD bet';

lives_ok {
    my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_aud;
    is $balance_after + 0, 10000 - 20, 'correct balance_after';
}
'bought AUD bet';

dies_ok {
    my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_aud,
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

# We have 2 accounts, AUD and USD, with 1 bet for 20 each. Since AUD=>USD rate is 2,
# the net value is 60 USD.

# We are buying and AUD 20 (= USD 40) bet. So, with max_turnover=100 it should succeed.
# Anything less should fail.

dies_ok {
    my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_aud, +{
        limits => {
            max_turnover => 99.9999,    # unit is USD
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
    my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_aud, +{
        limits => {
            max_turnover => 1000,    # in USD
        },
    };
    is $balance_after + 0, 10000 - 40, 'correct balance_after';
    sell_one_bet $acc_aud,
        {
        id         => $fmbid,
        sell_price => 0,
        sell_time  => Date::Utility->new->plus_time_interval('1s')->db_timestamp
        };
}
'bought and sold one more AUD bet with slightly increased max_turnover';

# at this point we have 2 open contracts: USD 20 and AUD 20. Since our AUDUSD rate
# is 2 this amounts to USD 60. Also, we have one lost contract for AUD 20 which is
# USD 40. As for the max_losses test, we need to sum up all open bets as losses
# plus the currently realized losses plus the current contract which is
#
#  40 (realized) + 60 (open) + 10000 (current) = 10100

dies_ok {
    my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
        +{
        buy_price => 10000,
        limits    => {
            max_losses    => 10099.99,
            max_open_bets => 3,
        },
        };
    is $balance_after + 0, 15000 - 10020, 'correct balance_after';
}
'exception thrown';
is_deeply $@,
    [
    BI012 => 'ERROR:  maximum self-exclusion limit on daily losses reached',
    ],
    'max_losses reached';

lives_ok {
    my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
        +{
        buy_price => 10000,
        limits    => {
            max_losses    => 10100,
            max_open_bets => 3,
        },
        };
    is $balance_after + 0, 15000 - 10020, 'correct balance_after';
}
'bought one more USD bet with slightly increased max_open_bets';

dies_ok {
    my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_aud,
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
        buy_price => 15000 - 10020 + 0.01,
        };
}
'exception thrown';
is_deeply $@,
    [
    BI003 => 'ERROR:  insufficient balance, need: 0.0100, #open_bets: 0, pot_payout: 0',
    ],
    'insufficient balance';

SKIP: {
    my @gmtime = gmtime;
    skip 'at least one minute must be left before mignight', 1
        if $gmtime[1] > 58 and $gmtime[2] == 23;

    subtest 'intraday_forex_iv_action limits', sub {
        my @bets_to_sell;

        lives_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd, +{
                relative_barrier => 'test',
                # 24h should actually be enough. But from time and again leap
                # seconds are inserted. So, in principle a day can have 24h + 1sec.
                duration => (24 * 3600 + 1) . 's',
            };
            is $balance_after + 0, 15000 - 10040, 'correct balance_after';
        }
        'This bet should not be taken into account in the intraday_forex_iv_action tests due to duration > 1day';

        lives_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                relative_barrier => 'test',
                limits           => {
                    intraday_forex_iv_action => {
                        turnover => 20,
                    },
                },
                };
            is $balance_after + 0, 15000 - 10060, 'correct balance_after';
            push @bets_to_sell, $fmbid;
        }
        'bought USD bet with relative_barrier=test';

        dies_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                buy_price        => '0.01',
                relative_barrier => 'test',
                limits           => {
                    intraday_forex_iv_action => {
                        turnover => 20,
                    },
                },
                };
        }
        'cannot buy one more due to intraday_forex_iv_action.turnover';
        is_deeply $@,
            [
            BI004 => 'ERROR:  maximum intraday forex turnover limit reached',
            ],
            'maximum intraday forex turnover limit reached';

        # there is currently one open bet with relative_barrier<>S0P
        # it has buy_price=20 and payout_price=200
        # let's buy one more with potential profit of 20
        # then the net potential profit is 200
        lives_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                relative_barrier => 'test',
                buy_price        => 20,
                payout_price     => 40,
                limits           => {
                    intraday_forex_iv_action => {
                        potential_profit => 200,
                        turnover         => 40,
                    },
                },
                };
            is $balance_after + 0, 15000 - 10080, 'correct balance_after';
            push @bets_to_sell, $fmbid;
        }
        'now we have potential_profit=200';

        dies_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                relative_barrier => 'test',
                buy_price        => 20,
                payout_price     => 20.01,
                limits           => {
                    intraday_forex_iv_action => {
                        potential_profit => 200,
                        turnover         => 60,
                    },
                },
                };
        }
        'cannot buy one more due to intraday_forex_iv_action.potential_profit';
        is_deeply $@,
            [
            BI005 => 'ERROR:  maximum intraday forex potential profit limit reached',
            ],
            'maximum intraday forex potential profit limit reached';

        # now we need to sell some bets
        lives_ok {
            my $txnid = sell_one_bet $acc_usd,
                +{
                id         => shift(@bets_to_sell),
                sell_price => 200,
                sell_time  => Date::Utility->new->plus_time_interval('1s')->db_timestamp,
                };
        }
        '1st bet sold';

        # here we have a realized profit of 180. Let's see if that's true.
        dies_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                relative_barrier => 'test',
                buy_price        => 20,
                limits           => {
                    intraday_forex_iv_action => {
                        realized_profit => 179.99,
                    },
                },
                };
        }
        'cannot buy one more due to intraday_forex_iv_action.realized_profit';
        is_deeply $@,
            [
            BI006 => 'ERROR:  maximum intraday forex realized profit limit reached',
            ],
            'maximum intraday forex realized profit limit reached';

        # try the same bet with a slightly higher limit
        lives_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                relative_barrier => 'test',
                limits           => {
                    intraday_forex_iv_action => {
                        realized_profit => 180,
                    },
                },
                };
            is $balance_after + 0, 15000 - 10100 + 200, 'correct balance_after';
            push @bets_to_sell, $fmbid;
        }
        'successfully bought USD bet with sightly higher intraday_forex_iv_action.realized_profit limit';
    };
}

subtest 'more validation', sub {
    my @usd_bets;

    lives_ok {
        $cl = create_client;

        top_up $cl, 'USD', 10000;
        top_up $cl, 'AUD', 10000;

        isnt + ($acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';
        isnt + ($acc_aud = $cl->find_account(query => [currency_code => 'AUD'])->[0]), undef, 'got AUD account';

        my $bal;
        is + ($bal = $acc_usd->balance + 0), 10000, 'USD balance is 10000 got: ' . $bal;
        is + ($bal = $acc_aud->balance + 0), 10000, 'AUD balance is 10000 got: ' . $bal;
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
        push @usd_bets, $fmbid;
        is $balance_after + 0, 10000 - 20, 'correct balance_after';
    }
    'can still buy when balance is exactly at max_balance';

    lives_ok {
        note 'this verifies that closed bets or open bets in other segments do not affect this validation';
        my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_aud;
        is $balance_after + 0, 10000 - 20, 'correct balance_after';
        ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd;
        push @usd_bets, $fmbid;
        is $balance_after + 0, 10000 - 40, 'correct balance_after';
        $txnid = sell_one_bet $acc_usd,
            +{
            id         => $fmbid,
            sell_price => 0,
            sell_time  => Date::Utility->new->plus_time_interval('1s')->db_timestamp,
            };
    }
    'buy a bet in the other account + buy and sell one in the current';

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

    dies_ok {
        my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
            +{
            limits => {
                max_payout_per_symbol_and_bet_type => 400 - 0.01,
            },
            };
    }
    'cannot buy due to max_payout_per_symbol_and_bet_type';
    is_deeply $@,
        [
        BI007 => 'ERROR:  maximum summary payout for open bets per symbol and bet_type reached',
        ],
        'maximum summary payout for open bets per symbol and bet_type reached';

    lives_ok {
        my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
            +{
            limits => {
                max_payout_open_bets => 400,
            },
            };
        push @usd_bets, $fmbid;
        is $balance_after + 0, 10000 - 60, 'correct balance_after';
    }
    'can buy when summary open payout is exactly at max_payout_open_bets';

    lives_ok {
        my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
            +{
            limits => {
                max_payout_per_symbol_and_bet_type => 600,
            },
            };
        push @usd_bets, $fmbid;
        is $balance_after + 0, 10000 - 80, 'correct balance_after';
    }
    'can buy when summary open payout is exactly at max_payout_per_symbol_and_bet_type';

    lives_ok {
        my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
            +{
            underlying_symbol => 'frxUSDAUD',
            limits            => {
                max_payout_per_symbol_and_bet_type => 800 - 0.01,
            },
            };
        push @usd_bets, $fmbid;
        is $balance_after + 0, 10000 - 100, 'correct balance_after';
    }
    'can buy for different symbol';

    lives_ok {
        my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
            +{
            bet_type => 'FLASHD',
            limits   => {
                max_payout_per_symbol_and_bet_type => 1000 - 0.01,
            },
            };
        push @usd_bets, $fmbid;
        is $balance_after + 0, 10000 - 120, 'correct balance_after';
    }
    'can buy for different bet_type';

    dies_ok {
        my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
            +{
            limits => {
                max_payout_open_bets => 1200 - 0.01,
            },
            };
    }
    'cannot buy due to max_payout_open_bets -- just to be sure';
    is_deeply $@,
        [
        BI009 => 'ERROR:  maximum net payout for open positions reached',
        ],
        'maximum net payout for open positions reached';

    # the USD account has 6 bets here, 5 of which are unsold. Let's sell them
    # all.
    lives_ok {
        my @bets_to_sell =
            map { {id => $_, sell_price => 30, sell_time => Date::Utility->new->plus_time_interval('1s')->db_timestamp,} } @usd_bets;

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

        is 0 + @$res, 5, 'sold 5 out of 6 bets (1 was already sold)';
        is $res->[0]->{txn}->{balance_after} + 0, 10000 - 120 + 5 * 30, 'balance_after';
    }
    'batch-sell 5 bets';
};

subtest 'free_gift', sub {
    lives_ok {
        $cl = create_client;

        free_gift $cl, 'USD', 10000;

        isnt + ($acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';

        my $bal;
        is + ($bal = $acc_usd->balance + 0), 10000, 'USD balance is 10000 got: ' . $bal;
    }
    'setup new client';

    dies_ok {
        my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
            +{
            limits => {
                max_balance_without_real_deposit => 10000 - 0.01,
            },
            };
    }
    'cannot buy due to max_balance_without_real_deposit';
    is_deeply $@,
        [
        BI010 => 'ERROR:  maximum balance reached for betting without a real deposit',
        ],
        'maximum net payout for open positions reached';

    lives_ok {
        my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
            +{
            limits => {
                max_balance_without_real_deposit => 10000,
            },
            };
        is $balance_after + 0, 10000 - 20, 'correct balance_after';
    }
    'can buy when hitting max_balance_without_real_deposit exactly';

    dies_ok {
        my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
            +{
            limits => {
                max_balance_without_real_deposit => 10000 - 0.01 - 20,
            },
            };
    }
    'ensure the new limit';
    is_deeply $@,
        [
        BI010 => 'ERROR:  maximum balance reached for betting without a real deposit',
        ],
        'maximum net payout for open positions reached';

    lives_ok {
        top_up $cl, 'AUD', 10000;

        isnt + ($acc_aud = $cl->find_account(query => [currency_code => 'AUD'])->[0]), undef, 'got AUD account';

        my $bal;
        is + ($bal = $acc_aud->balance + 0), 10000, 'AUD balance is 10000 got: ' . $bal;
    }
    'real deposit to differen account should be enough';

    lives_ok {
        my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
            +{
            limits => {
                max_balance_without_real_deposit => 10000 - 0.01 - 20,
            },
            };
        is $balance_after + 0, 10000 - 40, 'correct balance_after';
    }
    'can buy after deposit into different account';
};

SKIP: {
    my @gmtime = gmtime;
    skip 'at least one minute must be left before mignight', 2
        if $gmtime[1] > 58 and $gmtime[2] == 23;

    subtest 'specific turnover validation', sub {
        lives_ok {
            $cl = create_client;

            top_up $cl, 'USD', 10000;
            top_up $cl, 'AUD', 10000;

            isnt + ($acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';
            isnt + ($acc_aud = $cl->find_account(query => [currency_code => 'AUD'])->[0]), undef, 'got AUD account';

            my $bal;
            is + ($bal = $acc_usd->balance + 0), 10000, 'USD balance is 10000 got: ' . $bal;
            is + ($bal = $acc_aud->balance + 0), 10000, 'AUD balance is 10000 got: ' . $bal;
        }
        'setup new client';

        my @bets_to_sell;
        lives_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd;
            push @bets_to_sell, [$acc_usd, $fmbid];
            is $balance_after + 0, 10000 - 20, 'correct balance_after';

            ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_aud,
                +{
                tick_count => 19,
                };
            push @bets_to_sell, [$acc_aud, $fmbid];
            is $balance_after + 0, 10000 - 20, 'correct balance_after';

            ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_aud,
                +{
                underlying_symbol => 'fritz',
                };
            push @bets_to_sell, [$acc_aud, $fmbid];
            is $balance_after + 0, 10000 - 40, 'correct balance_after';

            ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                bet_type => 'CLUB',
                };
            push @bets_to_sell, [$acc_usd, $fmbid];
            is $balance_after + 0, 10000 - 40, 'correct balance_after';
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
                    };
            }
        }
        'and sell them for 0';

        # NOTE: exchange rates have been set up as the very 1st test
        #       We have a turnover of USD 40 and AUD 40 = USD 80
        #       which amounts to a net turnover of USD 120.
        #       And since all those bets are losses we have a net loss of USD 120.
        #       Also, there are no open bets. So, the loss limit is
        #           120 + 20 (current contract)
        dies_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd, +{
                limits => {
                    max_turnover             => 140 - 0.01,
                    max_losses               => 140 - 0.01,
                    specific_turnover_limits => [{    # fails
                            bet_type => [map { {n => $_} } qw/FLASHU FLASHD DUMMY CLUB/],
                            symbols  => [map { {n => $_} } qw/frxUSDJPY frxUSDGBP fritz/],
                            limit    => 140 - 0.01,
                            name     => 'test1',
                        },
                        {    # passes
                            bet_type => [map { {n => $_} } qw/FLASHU FLASHD DUMMY CLUB/],
                            symbols  => [map { {n => $_} } qw/frxUSDJPY frxUSDGBP fritz/],
                            limit    => 140,
                            name     => 'test2',
                        },
                        {    # fails (leave out the CLUB bet above)
                            bet_type => [map { {n => $_} } qw/FLASHU FLASHD DUMMY/],
                            limit    => 120 - 0.01,
                            name     => 'test3',
                        },
                        {    # passes (leave out the CLUB bet above)
                            bet_type => [map { {n => $_} } qw/FLASHU FLASHD DUMMY/],
                            limit    => 120,
                            name     => 'test4',
                        },
                        {    # fails (count only the one bet w/ tick_count, (AUD 20 = USD 40) + USD 20 for the bet to be bought => limit=60)
                            tick_expiry => 1,
                            limit       => 60 - 0.01,
                            name        => 'test5',
                        },
                        {    # passes  (count only the one bet w/ tick_count, (AUD 20 = USD 40) + USD 20 for the bet to be bought => limit=60)
                            tick_expiry => 1,
                            limit       => 60,
                            name        => 'test6',
                        },
                        {    # fails (count only the one bet w/ sym=fritz, (AUD 20 = USD 40) + USD 20 for the bet to be bought => limit=60)
                            symbols => [map { {n => $_} } qw/hugo fritz/],
                            limit   => 60 - 0.01,
                            name    => 'test7',
                        },
                        {    # passes  (count only the one bet w/ sym=fritz, (AUD 20 = USD 40) + USD 20 for the bet to be bought => limit=60)
                            symbols => [map { {n => $_} } qw/hugo fritz/],
                            limit   => 60,
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
                    max_turnover             => 140,
                    max_losses               => 140 - 0.01,
                    specific_turnover_limits => [{    # fails
                            bet_type => [map { {n => $_} } qw/FLASHU FLASHD DUMMY CLUB/],
                            symbols  => [map { {n => $_} } qw/frxUSDJPY frxUSDGBP fritz/],
                            limit    => 140 - 0.01,
                            name     => 'test1',
                        },
                        {    # passes
                            bet_type => [map { {n => $_} } qw/FLASHU FLASHD DUMMY CLUB/],
                            symbols  => [map { {n => $_} } qw/frxUSDJPY frxUSDGBP fritz/],
                            limit    => 140,
                            name     => 'test2',
                        },
                        {    # fails (leave out the CLUB bet above)
                            bet_type => [map { {n => $_} } qw/FLASHU FLASHD DUMMY/],
                            limit    => 120 - 0.01,
                            name     => 'test3',
                        },
                        {    # passes (leave out the CLUB bet above)
                            bet_type => [map { {n => $_} } qw/FLASHU FLASHD DUMMY/],
                            limit    => 120,
                            name     => 'test4',
                        },
                        {    # fails (count only the one bet w/ tick_count, (AUD 20 = USD 40) + USD 20 for the bet to be bought => limit=60)
                            tick_expiry => 1,
                            limit       => 60 - 0.01,
                            name        => 'test5',
                        },
                        {    # passes  (count only the one bet w/ tick_count, (AUD 20 = USD 40) + USD 20 for the bet to be bought => limit=60)
                            tick_expiry => 1,
                            limit       => 60,
                            name        => 'test6',
                        },
                        {    # fails (count only the one bet w/ sym=fritz, (AUD 20 = USD 40) + USD 20 for the bet to be bought => limit=60)
                            symbols => [map { {n => $_} } qw/hugo fritz/],
                            limit   => 60 - 0.01,
                            name    => 'test7',
                        },
                        {    # passes  (count only the one bet w/ sym=fritz, (AUD 20 = USD 40) + USD 20 for the bet to be bought => limit=60)
                            symbols => [map { {n => $_} } qw/hugo fritz/],
                            limit   => 60,
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
                    max_turnover             => 140,
                    max_losses               => 140,
                    specific_turnover_limits => [{    # fails
                            bet_type => [map { {n => $_} } qw/FLASHU FLASHD DUMMY CLUB/],
                            symbols  => [map { {n => $_} } qw/frxUSDJPY frxUSDGBP fritz/],
                            limit    => 140 - 0.01,
                            name     => 'test1',
                        },
                        {    # passes
                            bet_type => [map { {n => $_} } qw/FLASHU FLASHD DUMMY CLUB/],
                            symbols  => [map { {n => $_} } qw/frxUSDJPY frxUSDGBP fritz/],
                            limit    => 140,
                            name     => 'test2',
                        },
                        {    # fails (leave out the CLUB bet above)
                            bet_type => [map { {n => $_} } qw/FLASHU FLASHD DUMMY/],
                            limit    => 120 - 0.01,
                            name     => 'test3',
                        },
                        {    # passes (leave out the CLUB bet above)
                            bet_type => [map { {n => $_} } qw/FLASHU FLASHD DUMMY/],
                            limit    => 120,
                            name     => 'test4',
                        },
                        {    # fails (count only the one bet w/ tick_count, (AUD 20 = USD 40) + USD 20 for the bet to be bought => limit=60)
                            tick_expiry => 1,
                            limit       => 60 - 0.01,
                            name        => 'test5',
                        },
                        {    # passes  (count only the one bet w/ tick_count, (AUD 20 = USD 40) + USD 20 for the bet to be bought => limit=60)
                            tick_expiry => 1,
                            limit       => 60,
                            name        => 'test6',
                        },
                        {    # fails (count only the one bet w/ sym=fritz, (AUD 20 = USD 40) + USD 20 for the bet to be bought => limit=60)
                            symbols => [map { {n => $_} } qw/hugo fritz/],
                            limit   => 60 - 0.01,
                            name    => 'test7',
                        },
                        {    # passes  (count only the one bet w/ sym=fritz, (AUD 20 = USD 40) + USD 20 for the bet to be bought => limit=60)
                            symbols => [map { {n => $_} } qw/hugo fritz/],
                            limit   => 60,
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

        lives_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd, +{
                limits => {
                    max_turnover             => 140,
                    max_losses               => 140,
                    specific_turnover_limits => [{    # passes
                            bet_type => [map { {n => $_} } qw/FLASHU FLASHD DUMMY CLUB/],
                            symbols  => [map { {n => $_} } qw/frxUSDJPY frxUSDGBP fritz/],
                            limit    => 140,
                            name     => 'test2',
                        },
                        {    # passes (leave out the CLUB bet above)
                            bet_type => [map { {n => $_} } qw/FLASHU FLASHD DUMMY/],
                            limit    => 120,
                            name     => 'test4',
                        },
                        {    # passes  (count only the one bet w/ tick_count, (AUD 20 = USD 40) + USD 20 for the bet to be bought => limit=60)
                            tick_expiry => 1,
                            limit       => 60,
                            name        => 'test6',
                        },
                        {    # passes  (count only the one bet w/ sym=fritz, (AUD 20 = USD 40) + USD 20 for the bet to be bought => limit=60)
                            symbols => [map { {n => $_} } qw/hugo fritz/],
                            limit   => 60,
                            name    => 'test8',
                        },
                    ],
                },
            };
            is $balance_after + 0, 10000 - 60, 'correct balance_after';
        }
        'specific turnover validation succeeded';
    };

    subtest '7day limits', sub {
        lives_ok {
            $cl = create_client;

            top_up $cl, 'USD', 10000;
            top_up $cl, 'AUD', 10000;

            isnt + ($acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';
            isnt + ($acc_aud = $cl->find_account(query => [currency_code => 'AUD'])->[0]), undef, 'got AUD account';

            my $bal;
            is + ($bal = $acc_usd->balance + 0), 10000, 'USD balance is 10000 got: ' . $bal;
            is + ($bal = $acc_aud->balance + 0), 10000, 'AUD balance is 10000 got: ' . $bal;
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
            push @bets_to_sell, [$acc_usd, $fmbid];
            is $balance_after + 0, 10000 - 20, 'correct balance_after';

            ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_aud,
                +{
                purchase_time => $_6daysbefore->minus_time_interval('1s')->db_timestamp,
                };
            push @bets_to_sell, [$acc_aud, $fmbid];
            is $balance_after + 0, 10000 - 20, 'correct balance_after';

            ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                purchase_time => $_6daysbefore->db_timestamp,
                };
            push @bets_to_sell, [$acc_usd, $fmbid];
            is $balance_after + 0, 10000 - 40, 'correct balance_after';

            ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_aud,
                +{
                purchase_time => $_6daysbefore->db_timestamp,
                };
            push @bets_to_sell, [$acc_aud, $fmbid];
            is $balance_after + 0, 10000 - 40, 'correct balance_after';

            ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                purchase_time => $today->db_timestamp,
                };
            push @bets_to_sell, [$acc_usd, $fmbid];
            is $balance_after + 0, 10000 - 60, 'correct balance_after';

            ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_aud,
                +{
                purchase_time => $today->db_timestamp,
                };
            push @bets_to_sell, [$acc_aud, $fmbid];
            is $balance_after + 0, 10000 - 60, 'correct balance_after';
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
                    };
            }
        }
        'and sell them for 0';

        # Here we have 6 bought and sold bets, 3 USD and 3 AUD. Two of them, 1 USD + 1 AUD,
        # where bought before the time interval considered by the 7day limits. In total, we
        # have a worth of USD 120 turnover and losses within the 7day interval.
        # There are no open bets. So, the loss limit is:
        #
        #     120 (realized loss) + 20 (current contract)

        dies_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                limits => {
                    max_7day_turnover => 140 - 0.01,
                    max_7day_losses   => 140 - 0.01,
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
                    max_7day_turnover => 140,
                    max_7day_losses   => 140 - 0.01,
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
                    max_7day_turnover => 140,
                    max_7day_losses   => 140,
                },
                };
            is $balance_after + 0, 10000 - 80, 'correct balance_after';
        }
        '7day turnover validation passed with slightly higher limits';


        # now we have one open bet for USD 20. So, we should raise the limits
        # accordingly to buy the next

        dies_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
                +{
                limits => {
                    max_7day_turnover => 160 - 0.01,
                    max_7day_losses   => 160 - 0.01,
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
                    max_7day_turnover => 160,
                    max_7day_losses   => 160 - 0.01,
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
                    max_7day_turnover => 160,
                    max_7day_losses   => 160,
                },
                };
            is $balance_after + 0, 10000 - 100, 'correct balance_after';
        }
        '7day turnover validation passed with slightly higher limits (with open bet)';
    };
}

Test::NoWarnings::had_no_warnings;

done_testing;
