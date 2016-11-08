use strict;
use warnings;
use Test::Most (tests => 30);
use Test::MockTime qw( set_absolute_time restore_time );
use Test::Exception;

use BOM::Database::DataMapper::Transaction;
use BOM::Database::DataMapper::Account;
use BOM::Database::Model::Constants;
use BOM::Database::Model::Account;
use BOM::Database::Model::FinancialMarketBet;
use BOM::Database::Model::FinancialMarketBet::Factory;
use BOM::Database::Helper::FinancialMarketBet;
use Date::Utility;
use BOM::Test::Data::Utility::UnitTestDatabase qw( :init );

my $txn_data_mapper;

lives_ok {
    $txn_data_mapper = BOM::Database::DataMapper::Transaction->new({
        client_loginid => 'CR0005',
        currency_code  => 'USD',
    });

}
'Expect to initialize the object';

cmp_ok($txn_data_mapper->get_turnover_of_account, '==', 267.2, 'turnover of account');

my ($client, $account, $connection_builder);
lives_ok {
    $connection_builder = BOM::Database::ClientDB->new({
        broker_code => 'CR',
    });

    $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $account = $client->set_default_account('USD');

    $client->payment_free_gift(
        currency => 'USD',
        amount   => 5000,
        remark   => 'free gift',
    );
}
'expecting to create the required account models to buy / sell bet';

# perform bet buy / sell before start to test today's buy / sell turnover
my @bet_infos;
push @bet_infos,
    {
    bet_type          => 'FLASHU',
    bet_class         => 'higher_lower_bet',
    underlying_symbol => 'frxUSDJPY',
    buy_price         => 20,
    sell_price        => 40
    };
push @bet_infos,
    {
    bet_type          => 'FLASHD',
    bet_class         => 'higher_lower_bet',
    underlying_symbol => 'frxGBPJPY',
    buy_price         => 5.50,
    sell_price        => 0
    };
push @bet_infos,
    {
    bet_type          => 'CALL',
    bet_class         => 'higher_lower_bet',
    underlying_symbol => 'frxUSDJPY',
    buy_price         => 8,
    sell_price        => 0
    };

foreach my $bet_info (@bet_infos) {
    lives_ok {
        my $now        = Date::Utility->new;
        my $start_time = $now->datetime_yyyymmdd_hhmmss;
        my $end        = Date::Utility->new($now->epoch + 3600 * 2);
        my $end_time   = $end->datetime_yyyymmdd_hhmmss;

        my $financial_market_bet_helper = BOM::Database::Helper::FinancialMarketBet->new({
                account_data => {
                    client_loginid => $account->client_loginid,
                    currency_code  => $account->currency_code,
                },
                bet_data => {
                    underlying_symbol => $bet_info->{underlying_symbol},
                    payout_price      => 200,
                    buy_price         => $bet_info->{buy_price},
                    remark            => 'Test Remark',
                    purchase_time     => $start_time,
                    start_time        => $start_time,
                    expiry_time       => $end_time,
                    settlement_time   => $end_time,
                    is_expired        => 0,
                    is_sold           => 0,
                    bet_class         => $bet_info->{bet_class},
                    bet_type          => $bet_info->{bet_type},
                },
                db => $connection_builder->db,
            });
        my ($fmb, $txn) = $financial_market_bet_helper->buy_bet;
        is $fmb->{bet_class}, $bet_info->{bet_class}, 'buy fmb object';
        is $txn->{amount} + 0, -$bet_info->{buy_price}, 'buy txn object';

        my $financial_market_bet = BOM::Database::Model::FinancialMarketBet->new({
                data_object_params => {financial_market_bet_id => $fmb->{id}},
                db                 => $connection_builder->db,
            },
        );
        $financial_market_bet->load;
        is $financial_market_bet->id, $fmb->{id}, 'loaded FMB object';

        $financial_market_bet_helper->bet_data({
            id         => $financial_market_bet->id,
            sell_price => $bet_info->{sell_price},
            sell_time  => Date::Utility->new($now->epoch + 10)->db_timestamp,
        });
        ($fmb, $txn) = $financial_market_bet_helper->sell_bet;
        is $fmb->{id}, $financial_market_bet->id, 'sell fmb object';
        is $txn->{amount} + 0, $bet_info->{sell_price}, 'sell txn object';
    }
    'Buy a FLASHU bet and sell it';
}

my $bets;
lives_ok {
    $txn_data_mapper = BOM::Database::DataMapper::Transaction->new({broker_code => 'CR'});

    $bets = $txn_data_mapper->get_bet_transactions_for_broker({
        broker_code => 'CR',
        action_type => 'buy',
        start       => '2009-04-01',
        end         => '2009-04-30',
    });
}
'create mapper & get bets for CR';
cmp_ok(scalar(keys %{$bets}), '==', 5, 'check all buy bets count for CR');

lives_ok {
    $txn_data_mapper = BOM::Database::DataMapper::Transaction->new({broker_code => 'CR'});

    $bets = $txn_data_mapper->get_bet_transactions_for_broker({
        broker_code => 'CR',
        action_type => 'sell',
        start       => '2009-11-01',
        end         => '2009-11-30',
    });
}
'create mapper & get bets for CR';
is(scalar(keys %{$bets}), 33, 'check all sell bets count for CR');

subtest get_daily_summary_report => sub {
    plan tests => 3;

    my $client_ref = BOM::Database::DataMapper::Transaction->new({
            broker_code => 'CR',
        }
        )->get_daily_summary_report({
            currency_code     => 'USD',
            broker_code       => 'CR',
            start_of_next_day => '2011-1-1',
        });

    is_deeply(
        $client_ref->{'CR0012'},
        {
            'deposits'    => '0',
            'withdrawals' => '0',
            'loginid'     => 'CR0012',
            'balance_at'  => '0.0000',
            'account_id'  => '200419'
        });
    is_deeply(
        $client_ref->{'CR0026'},
        {
            'deposits'    => '300.0000',
            'withdrawals' => '0',
            'loginid'     => 'CR0026',
            'balance_at'  => '274.3400',
            'account_id'  => '200319'
        });
    is_deeply(
        $client_ref->{'CR0021'},
        {
            'deposits'    => '600.0000',
            'withdrawals' => '0',
            'loginid'     => 'CR0021',
            'balance_at'  => '1505.0000',
            'account_id'  => '200359'
        });
};

subtest get_open_bets_at_end_of => sub {
    plan tests => 3;

    my $client_ref = BOM::Database::DataMapper::Transaction->new({
            broker_code => 'CR',
        }
        )->get_accounts_with_open_bets_at_end_of({
            currency_code     => 'USD',
            broker_code       => 'CR',
            start_of_next_day => '2011-1-1',
        });

    my $account_id = 200499;
    is_deeply([sort { $a <=> $b } keys %{$client_ref->{$account_id}}], [201319, 201359]);

    $account_id = 200459;
    is_deeply([sort { $a <=> $b } keys %{$client_ref->{$account_id}}], [201159, 201179, 201219, 201239, 201279]);

    $account_id = 200359;
    is_deeply([sort { $a <=> $b } keys %{$client_ref->{$account_id}}], [201679, 201699, 201719, 201739, 201759, 201779, 201799, 201819]);
};

subtest 'get_transactions' => sub {
    my $txn_data_mapper = BOM::Database::DataMapper::Transaction->new({
        client_loginid => 'CR0021',
        currency_code  => 'USD'
    });

    subtest 'no params' => sub {
        my $transactions = $txn_data_mapper->get_transactions();
        is scalar @$transactions, 50, 'Got 50 transactions';
        is $transactions->[0]->{transaction_time}, '2005-09-21 06:46:00', 'Last transaction first';
    };

    subtest 'with limit' => sub {
        my $transactions = $txn_data_mapper->get_transactions({limit => 10});
        is scalar @$transactions, 10, 'Got 10 transactions';
        is $transactions->[0]->{transaction_time}, '2005-09-21 06:46:00', 'Last transaction first';
    };

    subtest 'before - 2005-09-21 06:21:00' => sub {
        my $transactions = $txn_data_mapper->get_transactions({before => '2005-09-21 06:21:00'});
        is scalar @$transactions, 16, 'Got 16 transactions';
        is $transactions->[0]->{transaction_time}, '2005-09-21 06:20:00', 'Last transaction first, Excludes 2005-09-21 06:21:00';
    };

    subtest 'after - 2005-09-21 06:40:00' => sub {
        my $transactions = $txn_data_mapper->get_transactions({after => '2005-09-21 06:40:00'});
        is scalar @$transactions, 24, 'Got 30 transactions';
        is $transactions->[0]->{transaction_time},  '2005-09-21 06:46:00', 'Last transaction first';
        is $transactions->[-1]->{transaction_time}, '2005-09-21 06:41:00', 'Excludes transaction at 2005-09-21 06:40:00';
    };

    subtest 'after - 2005-09-21 06:40:00, list from transaction from after_time to now' => sub {
        my $transactions = $txn_data_mapper->get_transactions({
            after => '2005-09-21 06:40:00',
            limit => 10
        });
        is scalar @$transactions, 10, 'Got 10 transactions';
        is $transactions->[0]->{transaction_time},  '2005-09-21 06:42:00', 'Last transaction first';
        is $transactions->[-1]->{transaction_time}, '2005-09-21 06:41:00', 'Excludes transaction at 2005-09-21 06:40:00';
    };

    subtest 'before 2005-09-21 06:40:00 and after 2005-09-21 06:30:00' => sub {
        my $transactions = $txn_data_mapper->get_transactions({
            before => '2005-09-21 06:40:00',
            after  => '2005-09-21 06:30:00'
        });
        is scalar @$transactions, 18, 'Got 18 transactions';
        is $transactions->[0]->{transaction_time},  '2005-09-21 06:39:00', 'Last transaction first';
        is $transactions->[-1]->{transaction_time}, '2005-09-21 06:32:00', 'Excludes transaction at 2005-09-21 06:30:00';
    };

    subtest 'before 2005-09-21 06:40:00, after 2005-09-21 06:30:00 and limit 10' => sub {
        my $transactions = $txn_data_mapper->get_transactions({
            before => '2005-09-21 06:40:00',
            after  => '2005-09-21 06:30:00',
            limit  => 10
        });
        is scalar @$transactions, 10, 'Got 10 transactions';
        is $transactions->[0]->{transaction_time},  '2005-09-21 06:39:00', 'Last transaction first';
        is $transactions->[-1]->{transaction_time}, '2005-09-21 06:37:00', 'Lists from before_time to after_time';
    };
};

subtest 'get_payments' => sub {
    my $txn_data_mapper = BOM::Database::DataMapper::Transaction->new({
        client_loginid => 'MX1001',
        currency_code  => 'GBP'
    });

    subtest 'all' => sub {
        my $transactions = $txn_data_mapper->get_payments();
        is scalar @$transactions, 6, 'Got all 6 transactions';
        is $transactions->[0]->{transaction_time}, '2011-03-09 08:00:00', 'Last payment first';
    };

    subtest 'limit' => sub {
        my $transactions = $txn_data_mapper->get_payments({limit => 2});
        is scalar @$transactions, 2, 'Got 2 transactions';
        is $transactions->[0]->{transaction_time}, '2011-03-09 08:00:00', 'Last payment first';
    };

    subtest 'before - 2011-03-09 07:22:00' => sub {
        my $transactions = $txn_data_mapper->get_payments({before => '2011-03-09 07:22:00'});
        is scalar @$transactions, 2, 'Got 2 transactions';
        is $transactions->[0]->{transaction_time}, '2011-03-09 06:22:00', 'Last payment first';
    };

    subtest 'after - 2011-03-09 07:24:00' => sub {
        my $transactions = $txn_data_mapper->get_payments({after => '2011-03-09 07:24:00'});
        is scalar @$transactions, 1, 'Got 1 transactions';
        is $transactions->[0]->{transaction_time}, '2011-03-09 08:00:00', 'Does not include 2011-03-09 07:24:00';
    };

    subtest 'after - 2011-03-09 07:23:00, list from transaction from after_time to now' => sub {
        my $transactions = $txn_data_mapper->get_payments({
            after => '2011-03-09 07:23:00',
            limit => 1
        });
        is scalar @$transactions, 1, 'Got 1 transactions';
        is $transactions->[0]->{transaction_time}, '2011-03-09 07:24:00', 'Last transaction first';
    };

    subtest 'before - 2011-03-09 07:24:00 and after - 2011-03-09 06:22:00' => sub {
        my $transactions = $txn_data_mapper->get_payments({
            before => '2011-03-09 07:24:00',
            after  => '2011-03-09 06:22:00'
        });
        is scalar @$transactions, 2, 'Got 2 transactions';
        is $transactions->[0]->{transaction_time}, '2011-03-09 07:23:00', 'Last payment first';
        is $transactions->[1]->{transaction_time}, '2011-03-09 07:22:00', 'Does not include 2011-03-09 06:22:00';
    };
};

subtest 'get_profit_for_days' => sub {
    my $txn_data_mapper = BOM::Database::DataMapper::Transaction->new({
        client_loginid => 'CR0021',
        currency_code  => 'USD'
    });

    is($txn_data_mapper->get_profit_for_days(), '-95.0000', 'Lifetime Profit of CR0021 for all days');
    is(
        $txn_data_mapper->get_profit_for_days({
                before => '2005-09-21 06:40:00',
                after  => '2005-09-21 06:30:00'
            }
        ),
        '-133.0000',
        'Profit for CR0021 between 2005-09-21 06:30:00 and 2005-09-21 06:40:00'
    );
};
