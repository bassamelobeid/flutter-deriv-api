#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 29;
use Test::NoWarnings ();    # no END block test
use Test::Exception;
use BOM::Database::Helper::FinancialMarketBet;
use BOM::Platform::Client;
use BOM::Database::ClientDB;
use BOM::System::Password;
use BOM::Platform::Client::Utility;
use BOM::Database::Model::FinancialMarketBet::Factory;
Crypt::NamedKeys->keyfile('/etc/rmg/aes_keys.yml');

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

    return if (@acc && $acc[0]->currency_code ne $cur);

    if (not @acc) {
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
    my ($bet, $txn) = $fmb->buy_bet;
    # note explain [$bet, $txn];
    return ($txn->{id}, $bet->{id}, $txn->{balance_after});
}

sub buy_multiple_bets {
    my ($acc) = @_;

    my $now      = Date::Utility->new;
    my $bet_data = +{
        underlying_symbol => 'frxUSDJPY',
        payout_price      => 200,
        buy_price         => 20,
        remark            => 'Test Remark',
        purchase_time     => $now->db_timestamp,
        start_time        => $now->db_timestamp,
        expiry_time       => $now->plus_time_interval('15s')->db_timestamp,
        settlement_time   => $now->plus_time_interval('15s')->db_timestamp,
        is_expired        => 1,
        is_sold           => 0,
        bet_class         => 'higher_lower_bet',
        bet_type          => 'FLASHU',
        short_code        => ('FLASHU_R_50_200_' . $now->epoch . '_' . $now->plus_time_interval('15s')->epoch . '_S0P_0'),
        relative_barrier  => 'S0P',
    };

    my $fmb = BOM::Database::Helper::FinancialMarketBet->new({
        bet_data     => $bet_data,
        account_data => [map { +{client_loginid => $_->client_loginid, currency_code => $_->currency_code} } @$acc],
        limits       => undef,
        db           => db,
    });
    my $res = $fmb->batch_buy_bet;
    # note explain [$res];
    return $res;
}

sub buy_one_spread_bet {
    my ($acc, $args) = @_;

    my $now            = Date::Utility->new;
    my $buy_price      = delete $args->{buy_price} // 20;
    my $limits         = delete $args->{limits};
    my $duration       = delete $args->{duration} // '15s';
    my $app            = delete $args->{amount_per_point} // 2;
    my $stop_type      = delete $args->{stop_type} // 'point';
    my $stop_loss      = delete $args->{stop_loss} // 10;
    my $stop_profit    = delete $args->{stop_profit} // 10;
    my $spread         = delete $args->{spread} // 2;
    my $spread_divisor = delete $args->{spread_divisor} // 1;
    my $purchase_time  = delete $args->{purchase_time} // $now->db_timestamp;

    my $bet_data = +{
        underlying_symbol => 'R_100',
        buy_price         => $buy_price,
        remark            => 'Test Remark',
        purchase_time     => $purchase_time,
        start_time        => $purchase_time,
        is_expired        => 0,
        is_sold           => 0,
        bet_class         => 'spread_bet',
        bet_type          => 'SPREADU',
        short_code        => ('SPREADU_R_100_' . $app . '_' . $now->epoch . '_' . $stop_loss . '_' . $stop_profit . '_' . $stop_type),
        amount_per_point  => $app,
        stop_type         => $stop_type,
        stop_profit       => $stop_profit,
        stop_loss         => $stop_loss,
        spread_divisor    => $spread_divisor,
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
    isnt + ($acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';

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
    my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd, +{
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
    my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd, +{
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
        sell_time  => Date::Utility->new->plus_time_interval('1s')->db_timestamp
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
    BI003 => 'ERROR:  insufficient balance, need: 0.0100, #open_bets: 0, pot_payout: 0',
    ],
    'insufficient balance';

my $sell_price;
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
            $bal -= 20;
            is $balance_after + 0, $bal, 'correct balance_after';
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
            $bal -= 20;
            is $balance_after + 0, $bal, 'correct balance_after';
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

        $buy_price = 20;
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
            $bal -= $buy_price;
            is $balance_after + 0, $bal, 'correct balance_after';
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
        $sell_price = 200;
        lives_ok {
            my $txnid = sell_one_bet $acc_usd,
                +{
                id         => shift(@bets_to_sell),
                sell_price => $sell_price,
                sell_time  => Date::Utility->new->plus_time_interval('1s')->db_timestamp,
                };
        }
        '1st bet sold';

        $bal += $sell_price;
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
            $bal -= 20;
            is $balance_after + 0, $bal, 'correct balance_after';
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
        isnt + ($acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';
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
        $bal -= 20;
        push @usd_bets, $fmbid;
        is $balance_after + 0, $bal, 'correct balance_after';
    }
    'can buy when summary open payout is exactly at max_payout_open_bets';

    lives_ok {
        my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd,
            +{
            limits => {
                max_payout_per_symbol_and_bet_type => 600,
            },
            };
        $bal -= 20;
        push @usd_bets, $fmbid;
        is $balance_after + 0, $bal, 'correct balance_after';
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
        $bal -= 20;
        push @usd_bets, $fmbid;
        is $balance_after + 0, $bal, 'correct balance_after';
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
        $bal -= 20;
        push @usd_bets, $fmbid;
        is $balance_after + 0, $bal, 'correct balance_after';
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

    # the USD account has 6 bets here, 5 of which are unsold. Let's sell them all.
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
        $bal += 5*30;
        is 0 + @$res, 5, 'sold 5 out of 6 bets (1 was already sold)';
        is $res->[0]->{txn}->{balance_after} + 0, $bal, 'balance_after';
    }
    'batch-sell 5 bets';
};

SKIP: {
    my @gmtime = gmtime;
    skip 'at least one minute must be left before mignight', 2
        if $gmtime[1] > 58 and $gmtime[2] == 23;

    subtest 'specific turnover validation', sub {
        lives_ok {
            $cl = create_client;

            top_up $cl, 'USD', 10000;
            isnt + ($acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';
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
                underlying_symbol => 'fritz',
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
                            bet_type => [map { {n => $_} } qw/FLASHU FLASHD DUMMY CLUB/],
                            symbols  => [map { {n => $_} } qw/frxUSDJPY frxUSDGBP fritz/],
                            limit    => 100 - 0.01,
                            name     => 'test1',
                        },
                        {    # passes
                            bet_type => [map { {n => $_} } qw/FLASHU FLASHD DUMMY CLUB/],
                            symbols  => [map { {n => $_} } qw/frxUSDJPY frxUSDGBP fritz/],
                            limit    => 100,
                            name     => 'test2',
                        },
                        {    # fails (leave out the CLUB bet above)
                            bet_type => [map { {n => $_} } qw/FLASHU FLASHD DUMMY/],
                            limit    => 80 - 0.01,
                            name     => 'test3',
                        },
                        {    # passes (leave out the CLUB bet above)
                            bet_type => [map { {n => $_} } qw/FLASHU FLASHD DUMMY/],
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
                        {    # fails (count only the one bet w/ sym=fritz, USD 20 + USD 20 for the bet to be bought => limit=40)
                            symbols => [map { {n => $_} } qw/hugo fritz/],
                            limit   => 40 - 0.01,
                            name    => 'test7',
                        },
                        {    # passes  (count only the one bet w/ sym=fritz, USD 20 + USD 20 for the bet to be bought => limit=40)
                            symbols => [map { {n => $_} } qw/hugo fritz/],
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
                            bet_type => [map { {n => $_} } qw/FLASHU FLASHD DUMMY CLUB/],
                            symbols  => [map { {n => $_} } qw/frxUSDJPY frxUSDGBP fritz/],
                            limit    => 100 - 0.01,
                            name     => 'test1',
                        },
                        {    # passes
                            bet_type => [map { {n => $_} } qw/FLASHU FLASHD DUMMY CLUB/],
                            symbols  => [map { {n => $_} } qw/frxUSDJPY frxUSDGBP fritz/],
                            limit    => 100,
                            name     => 'test2',
                        },
                        {    # fails (leave out the CLUB bet above)
                            bet_type => [map { {n => $_} } qw/FLASHU FLASHD DUMMY/],
                            limit    => 80 - 0.01,
                            name     => 'test3',
                        },
                        {    # passes (leave out the CLUB bet above)
                            bet_type => [map { {n => $_} } qw/FLASHU FLASHD DUMMY/],
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
                        {    # fails (count only the one bet w/ sym=fritz, USD 20 + USD 20 for the bet to be bought => limit=40)
                            symbols => [map { {n => $_} } qw/hugo fritz/],
                            limit   => 40 - 0.01,
                            name    => 'test7',
                        },
                        {    # passes  (count only the one bet w/ sym=fritz, USD 20 + USD 20 for the bet to be bought => limit=40)
                            symbols => [map { {n => $_} } qw/hugo fritz/],
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
                            bet_type => [map { {n => $_} } qw/FLASHU FLASHD DUMMY CLUB/],
                            symbols  => [map { {n => $_} } qw/frxUSDJPY frxUSDGBP fritz/],
                            limit    => 100 - 0.01,
                            name     => 'test1',
                        },
                        {    # passes
                            bet_type => [map { {n => $_} } qw/FLASHU FLASHD DUMMY CLUB/],
                            symbols  => [map { {n => $_} } qw/frxUSDJPY frxUSDGBP fritz/],
                            limit    => 100,
                            name     => 'test2',
                        },
                        {    # fails (leave out the CLUB bet above)
                            bet_type => [map { {n => $_} } qw/FLASHU FLASHD DUMMY/],
                            limit    => 80 - 0.01,
                            name     => 'test3',
                        },
                        {    # passes (leave out the CLUB bet above)
                            bet_type => [map { {n => $_} } qw/FLASHU FLASHD DUMMY/],
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
                        {    # fails (count only the one bet w/ sym=fritz, USD 20 + USD 20 for the bet to be bought => limit=40)
                            symbols => [map { {n => $_} } qw/hugo fritz/],
                            limit   => 40 - 0.01,
                            name    => 'test7',
                        },
                        {    # passes  (count only the one bet w/ sym=fritz, USD 20 + USD 20 for the bet to be bought => limit=40)
                            symbols => [map { {n => $_} } qw/hugo fritz/],
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

        lives_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd, +{
                limits => {
                    max_turnover             => 100,
                    max_losses               => 100,
                    specific_turnover_limits => [{    # passes
                            bet_type => [map { {n => $_} } qw/FLASHU FLASHD DUMMY CLUB/],
                            symbols  => [map { {n => $_} } qw/frxUSDJPY frxUSDGBP fritz/],
                            limit    => 100,
                            name     => 'test2',
                        },
                        {    # passes (leave out the CLUB bet above)
                            bet_type => [map { {n => $_} } qw/FLASHU FLASHD DUMMY/],
                            limit    => 80,
                            name     => 'test4',
                        },
                        {    # passes  (count only the one bet w/ tick_count, USD 20 + USD 20 for the bet to be bought => limit=40)
                            tick_expiry => 1,
                            limit       => 40,
                            name        => 'test6',
                        },
                        {    # passes  (count only the one bet w/ sym=fritz, USD 20 + USD 20 for the bet to be bought => limit=40)
                            symbols => [map { {n => $_} } qw/hugo fritz/],
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

    subtest 'spread limits', sub {
        lives_ok {
            $cl = create_client;

            top_up $cl, 'USD', 10000;
            isnt + ($acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';
            is + ($bal = $acc_usd->balance + 0), 10000, 'USD balance is 10000 got: ' . $bal;

#            top_up $cl, 'AUD', 10000;
#            isnt + ($acc_aud = $cl->find_account(query => [currency_code => 'AUD'])->[0]), undef, 'got AUD account';
#            is + ($bal = $acc_aud->balance + 0), 10000, 'AUD balance is 10000 got: ' . $bal;
        }
        'setup new client';

        # can buy spread bet worth potential profit of USD 80 yesterday
        lives_ok {
            my $yest = Date::Utility->new->minus_time_interval('1d')->truncate_to_day;
            my ($txnid, $fmbid, $balance_after) = buy_one_spread_bet $acc_usd,
                +{
                limits           => {spread_bet_profit_limit => 80},
                amount_per_point => 8,
                purchase_time    => $yest->db_timestamp
                };
            $bal -= 20;
            is $balance_after + 0, $bal, 'correct balance_after';

            $sell_price = 100;
            $txnid = sell_one_bet $acc_usd,
                +{
                id         => $fmbid,
                sell_price => $sell_price,
                sell_time  => $yest->plus_time_interval('1s')->db_timestamp,
                };
            $bal += $sell_price;
        }
        'bought and sold a spread bet with USD 80 profit';

        my @bets_to_sell;
        lives_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_spread_bet $acc_usd;
            $bal -= 20;
            is $balance_after + 0, $bal, 'correct balance_after';
            push @bets_to_sell, [$acc_usd, $fmbid];

            ($txnid, $fmbid, $balance_after) = buy_one_spread_bet $acc_usd;
            $bal -= 20;
            is $balance_after + 0, $bal, 'correct balance_after';
        }
        'buy spread bets';

        # I bought 2 spread contracts with a potential profit of USD 20 and USD 20 (USD 40 in total).
        # dies if you try to buy a contract with potential payout of USD 20.01
        dies_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_spread_bet $acc_usd,
                +{
                limits           => {spread_bet_profit_limit => 60},
                amount_per_point => 2.001
                };
        }
        'cannot buy bet woth USD 20.01';
        is_deeply $@,
            [
            BI015 => 'ERROR:  daily profit limit on spread bets exceeded',
            ],
            'daily profit limit on spread bets exceeded';

        # can still buy a contract worth USD 20 when limit is set to USD 60.
        lives_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_spread_bet $acc_usd, +{limits => {spread_bet_profit_limit => 60}};
            $bal -= 20;
            is $balance_after + 0, $bal, 'correct balance_after';
        }
        'can still buy bet worth USD 20';

        # sell one spread bet and make profit of USD 10
        lives_ok {
            my ($acc, $fmbid) = @{shift @bets_to_sell};
            my $txnid = sell_one_bet $acc,
                +{
                id         => $fmbid,
                sell_price => 30,
                sell_time  => Date::Utility->new->plus_time_interval('1s')->db_timestamp,
                };
        }
        'and sell one bet in USD account for profit of USD 10';
        $bal += 30;

        # Current status:
        # USD account: USD 10 profit and potential profit of USD 40 in 2 open contracts
        # total: USD 50

        # dies if try to buy a contract with potential payout of USD 10.01
        dies_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_spread_bet $acc_usd,
                +{
                limits           => {spread_bet_profit_limit => 60},
                amount_per_point => 1.001
                };
        }
        'cannot buy bet woth USD 10.01';
        is_deeply $@,
            [
            BI015 => 'ERROR:  daily profit limit on spread bets exceeded',
            ],
            'daily profit limit on spread bets exceeded';

        lives_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_spread_bet $acc_usd,
                +{
                limits           => {spread_bet_profit_limit => 60},
                amount_per_point => 1
                };
            $bal -= 20;
            is $balance_after + 0, $bal, 'correct balance_after';
        }
        'can still buy bet worth USD 10';

        # can buy other bet even though we have hit the spread daily limit
        lives_ok {
            my ($txnid, $fmbid, $balance_after) = buy_one_bet $acc_usd, +{limits => {spread_bet_profit_limit => 60}};
            $bal -= 20;
            is $balance_after + 0, $bal, 'correct balance_after';
        }
        'can still buy bet worth USD 20';
    };

    subtest '7day limits', sub {
        lives_ok {
            $cl = create_client;

            top_up $cl, 'USD', 10000;
            isnt + ($acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';
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
            isnt + ($acc_usd = $cl->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got USD account';
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
}

subtest 'batch_buy', sub {
    use DBD::Pg;
    use YAML::XS;

    my $config = YAML::XS::LoadFile('/etc/rmg/clientdb.yml');
    my $ip     = $config->{costarica}->{write}->{ip};           # create_client creates CR clients
    my $pw     = $config->{password};

    my $listener = DBI->connect(
        "dbi:Pg:dbname=regentmarkets;host=$ip;port=5432;application_name=notify_pub",
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

        isnt + ($acc1 = $cl1->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got 1st account';
        isnt + ($acc2 = $cl2->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got 2nd account';
        isnt + ($acc3 = $cl3->find_account(query => [currency_code => 'USD'])->[0]), undef, 'got 3rd account';
        isnt + ($acc4 = $cl4->find_account(query => [currency_code => 'AUD'])->[0]), undef, 'got 4th account';
    }
    'setup clients';

    $listener->do("LISTEN transaction_watchers");

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
            my $r = $res->{$loginid};
            isnt $r, undef, 'got result hash';
            is $r->{loginid}, $loginid, 'found loginid';
            is $r->{e_code},        undef, 'e_code is undef';
            is $r->{e_description}, undef, 'e_description is undef';
            isnt $r->{fmb},         undef, 'got FMB';
            isnt $r->{txn},         undef, 'got TXN';

            my $fmb = $r->{fmb};
            is $fmb->{account_id}, $acc->id, 'fmb account id matches';

            my $txn = $r->{txn};
            is $txn->{account_id}, $acc->id, 'txn account id matches';
            is $txn->{referrer_type}, 'financial_market_bet', 'txn referrer_type is financial_market_bet';
            is $txn->{financial_market_bet_id}, $fmb->{id}, 'txn fmb id matches';
            is $txn->{amount},        '-20.0000',  'txn amount';
            is $txn->{balance_after}, '4980.0000', 'txn balance_after';

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
            my $r = $res->{$loginid};
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
            my $r = $res->{$loginid};
            isnt $r, undef, 'got result hash';
            is $r->{loginid}, $loginid, 'found loginid';
            is $r->{e_code},        undef, 'e_code is undef';
            is $r->{e_description}, undef, 'e_description is undef';
            isnt $r->{fmb},         undef, 'got FMB';
            isnt $r->{txn},         undef, 'got TXN';

            my $fmb = $r->{fmb};
            is $fmb->{account_id}, $acc->id, 'fmb account id matches';

            my $txn = $r->{txn};
            is $txn->{account_id}, $acc->id, 'txn account id matches';
            is $txn->{referrer_type}, 'financial_market_bet', 'txn referrer_type is financial_market_bet';
            is $txn->{financial_market_bet_id}, $fmb->{id}, 'txn fmb id matches';
            is $txn->{amount},        '-20.0000',  'txn amount';
            is $txn->{balance_after}, '9980.0000', 'txn balance_after';

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

    dies_ok {
        my $res = buy_multiple_bets [$acc1, $acc4, $acc3];
    }
    'buy_multiple_bets with differing currencies dies';
    # note "exception is $@";
    like $@, qr/^invalid currency/i, 'invalid currency';
};

Test::NoWarnings::had_no_warnings;

done_testing;
