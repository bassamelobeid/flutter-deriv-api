#!/etc/rmg/bin/perl

use strict;
use warnings;
use Test::More tests => 6;
use Test::Exception;
use Test::Warnings;

use BOM::User::Client;
use BOM::User::Client::PaymentAgent;

use BOM::Database::Model::Account;
use BOM::Database::Model::DataCollection::QuantsBetVariables;
use BOM::Database::Helper::FinancialMarketBet;
use BOM::Database::ClientDB;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use YAML::XS;

use IO::Select;

my $connection_builder;
my ($acc1, $acc2, $acc3, $acc4);

$connection_builder = BOM::Database::ClientDB->new({
    broker_code => 'CR',
});

sub create_account {
    my ($accid) = @_;
    my $acc = BOM::Database::Model::Account->new({
            'data_object_params' => {
                'client_loginid' => $accid,
                'currency_code'  => 'USD'
            },
            db => $connection_builder->db
        });
    $acc->load();

    return $acc;
}

$acc1 = create_account 'CR0021';
$acc2 = create_account 'CR0027';
$acc3 = create_account 'CR0028';
$acc4 = create_account 'CR0008';

# for payments tests
my $pa        = BOM::User::Client::PaymentAgent->new({loginid => 'CR0020'});
my $pa_client = $pa->client;
my $client    = BOM::User::Client->new({loginid => 'CR0021'});

# for notify listening
my $config = YAML::XS::LoadFile('/etc/rmg/clientdb.yml');
my $ip     = $config->{costarica}->{write}->{ip};           # create_client creates CR clients
my $db     = $config->{costarica}->{write}->{dbname};       # create_client creates CR clients
my $pw     = $config->{password};

my $listener = DBI->connect(
    "dbi:Pg:dbname=$db@{[$ENV{DB_POSTFIX}//'']};host=$ip;port=5432;application_name=notify_pub",
    'write', $pw,
    {
        AutoCommit => 1,
        RaiseError => 1,
        PrintError => 0
    });

$listener->do("LISTEN transaction_watchers");

sub db {
    return BOM::Database::ClientDB->new({
            broker_code => 'CR',
        })->db;
}

sub test_notify {
    my @tests = @_;

    my $sel = IO::Select->new;
    $sel->add($listener->{pg_socket});
    $sel->can_read(10);

    my %notifications;
    while (my $notify = $listener->pg_notifies) {
        my $n = {};
        @{$n}{
            qw/id account_id action_type referrer_type financial_market_bet_id payment_id amount balance_after transaction_time short_code currency_code purchase_time buy_price sell_time payment_remark/
            } =
            split ',', $notify->[-1];
        $notifications{$n->{id}} = $n;
    }

    foreach my $test (@tests) {
        my $loginid = $test->{acc}->client_loginid;
        subtest 'testing result for ' . $loginid . ' transaction ' . $test->{txn}->{id}, sub {
            my $note = $notifications{$test->{txn}->{id}};
            isnt $note, undef, 'found notification';
            is $note->{currency_code}, 'USD', "note{currency_code} eq USD";
            for my $name (qw/account_id action_type amount balance_after financial_market_bet_id transaction_time/) {
                is $note->{$name}, $test->{txn}->{$name}, "note{$name} eq txn{$name}";
            }
            for my $name (qw/buy_price purchase_time sell_time short_code/) {
                is $note->{$name}, $test->{fmb}->{$name}, "note{$name} eq fmb{$name}";
            }
            }
    }
}

sub test_payment_notify {
    my @tests = @_;

    my $sel = IO::Select->new;
    $sel->add($listener->{pg_socket});
    $sel->can_read(10);

    my %notifications;
    while (my $notify = $listener->pg_notifies) {
        my $n = {};
        @{$n}{
            qw/id account_id action_type referrer_type financial_market_bet_id payment_id amount balance_after transaction_time short_code currency_code purchase_time buy_price sell_time payment_remark/
            } =
            split ',', $notify->[-1];
        $notifications{$n->{id}} = $n;
    }

    foreach my $test (@tests) {
        subtest 'testing ' . $test->{testtype} . ' result for ' . $test->{txn}->{id}, sub {
            my $note = $notifications{$test->{txn}->{id}};
            isnt $note, undef, 'found notification';
            #is $note->{currency_code}, 'USD', "note{currency_code} eq USD";
            # transaction_time is different !!!
            for my $name (qw/account_id action_type amount balance_after payment_id/) {
                is $note->{$name}, $test->{txn}->{$name}, "note{$name} eq txn{$name}";
            }
            is $note->{payment_remark}, $test->{remark}, 'payment_remark';
            }
    }
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
    return ($txn, $bet);
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
        bet_type          => 'CALL',
        short_code        => ('CALL_R_50_200_' . $now->epoch . '_' . $now->plus_time_interval('15s')->epoch . '_S0P_0'),
        relative_barrier  => 'S0P',
        quantity          => 1,
    };

    my $fmb = BOM::Database::Helper::FinancialMarketBet->new({
        bet_data     => $bet_data,
        account_data => [map { +{client_loginid => $_->client_loginid, currency_code => $_->currency_code} } @$acc],
        limits       => undef,
        db           => db,
    });
    my $res = $fmb->batch_buy_bet;
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
    return ($txn, $bet);
}

subtest 'survived notify buy_one_bet', sub {
    my ($txn, $fmb) = buy_one_bet $acc1;

    test_notify({
        acc => $acc1,
        fmb => $fmb,
        txn => $txn
    });
};

subtest 'survived notify buy_multiple_bets', sub {
    my $res = buy_multiple_bets [$acc1, $acc3, $acc4];

    test_notify({
            acc => $acc1,
            fmb => $res->[0]->{fmb},
            txn => $res->[0]->{txn}
        },
        {
            acc => $acc2,
            fmb => $res->[1]->{fmb},
            txn => $res->[1]->{txn}
        },
        {
            acc => $acc3,
            fmb => $res->[2]->{fmb},
            txn => $res->[2]->{txn}});
};

subtest 'survived notify sell_one_bet', sub {
    my ($txnb, $fmbb) = buy_one_bet $acc1;

    my ($txns, $fmbs) = sell_one_bet $acc1,
        {
        id         => $fmbb->{id},
        sell_price => 0,
        sell_time  => Date::Utility->new->plus_time_interval('1s')->db_timestamp,
        quantity   => 1,
        };

    test_notify({
        acc => $acc1,
        fmb => $fmbs,
        txn => $txns
    });
};

subtest 'survived notify batch_sell_bet', sub {
    my @usd_bets;

    my ($txn1, $fmb1) = buy_one_bet $acc2;
    push @usd_bets, $fmb1->{id};

    my ($txn2, $fmb2) = buy_one_bet $acc2;
    push @usd_bets, $fmb2->{id};

    my $txnid = sell_one_bet $acc2,
        +{
        id         => $fmb2->{id},
        sell_price => 0,
        sell_time  => Date::Utility->new->plus_time_interval('1s')->db_timestamp,
        quantity   => 1,
        };

    my ($txn3, $fmb3) = buy_one_bet $acc2;
    push @usd_bets, $fmb3->{id};

    my ($txn4, $fmb4) = buy_one_bet $acc2;
    push @usd_bets, $fmb4->{id};

    my ($txn5, $fmb5) = buy_one_bet $acc2;
    push @usd_bets, $fmb5->{id};

    my ($txn6, $fmb6) = buy_one_bet $acc2;
    push @usd_bets, $fmb6->{id};

    # the USD account has 6 bets here, 5 of which are unsold. Let's sell them all.
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
                    client_loginid => $acc2->client_loginid,
                    currency_code  => $acc2->currency_code
                },
                db => db,
            });

        my $res = $fmb->batch_sell_bet;

        is 0 + @$res, 5, 'sold 5 out of 6 bets (1 was already sold)';

        test_notify({
                acc => $acc2,
                fmb => @$res[0]->{fmb},
                txn => @$res[0]->{txn}
            },
            {
                acc => $acc2,
                fmb => @$res[1]->{fmb},
                txn => @$res[1]->{txn}
            },
            {
                acc => $acc2,
                fmb => @$res[2]->{fmb},
                txn => @$res[2]->{txn}
            },
            {
                acc => $acc2,
                fmb => @$res[3]->{fmb},
                txn => @$res[3]->{txn}
            },
            {
                acc => $acc2,
                fmb => @$res[4]->{fmb},
                txn => @$res[4]->{txn}});

    }
    'batch-sell 5 bets';
};

subtest 'survived notify payments', sub {
    $client->set_default_account('USD');
    my $txn = $client->payment_legacy_payment(
        currency     => 'USD',
        amount       => '1000',
        payment_type => 'adjustment',
        remark       => 'play money'
    );
    test_payment_notify({
        txn      => $txn,
        remark   => 'play money',
        testtype => 'payment_legacy_payment'
    });

    # need to set default account before making payment
    $pa_client->set_default_account('USD');
    my $txnid = $client->payment_account_transfer(
        amount   => 20.02,
        currency => 'USD',
        toClient => $pa_client,
        remark   => 'reference: #USD20.02#F72117379D1DD7B5#',
        fmRemark => 'from reference: #USD20.02#F72117379D1DD7B5#',
        toRemark => 'to reference: #USD20.02#F72117379D1DD7B5#',
        fees     => 0,
    );
    $txn = BOM::Database::Model::Transaction->new({
        'data_object_params' => {'id' => $txnid->{transaction_id}},
        db                   => $connection_builder->db
    });
    $txn->load();
    test_payment_notify({
        txn      => $txn->{transaction_record},
        remark   => 'from reference: #USD20.02#F72117379D1DD7B5#',
        testtype => 'payment_account_transfer'
    });

    $txnid = $client->payment_account_transfer(
        amount            => 20.02,
        currency          => 'USD',
        toClient          => $pa_client,
        remark            => 'reference: #USD20.02#F72117379D1DD7B5#',
        fmRemark          => 'from reference: #USD20.02#F72117379D1DD7B5#',
        toRemark          => 'to reference: #USD20.02#F72117379D1DD7B5#',
        fees              => 0,
        inter_db_transfer => 1,
    );
    $txn = BOM::Database::Model::Transaction->new({
        'data_object_params' => {'id' => $txnid->{transaction_id}},
        db                   => $connection_builder->db
    });
    $txn->load();
    test_payment_notify({
        txn      => $txn->{transaction_record},
        remark   => 'from reference: #USD20.02#F72117379D1DD7B5#',
        testtype => 'payment_account_transfer inter_db'
    });

    $txn = $client->payment_doughflow(
        currency     => 'USD',
        amount       => 1,
        remark       => 'here is money',
        payment_type => 'external_cashier',
    );
    test_payment_notify({
        txn      => $txn,
        remark   => 'here is money',
        testtype => 'payment_doughflow'
    });
};

