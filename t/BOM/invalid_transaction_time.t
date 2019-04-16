use warnings;
use strict;

use Test::Most;
use Date::Utility;
use Test::MockModule;

use BOM::User;
use BOM::Transaction;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Test::Helper::Client qw(create_client);

my $fmb_mock = Test::MockModule->new('BOM::Database::Helper::FinancialMarketBet');

my $client    = create_client();
my $account   = $client->account('USD');
my $db        = $client->db->dbic;
my $database  = $client->db->database =~ s/costarica-write/cr/r;
my $now       = Date::Utility->new;
my $past_10s  = $now->minus_time_interval('10s');
my $past_11s  = $now->minus_time_interval('11s');
my $future_3d = $now->plus_time_interval('3d');
my $future_4d = $now->plus_time_interval('4d');

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => 'USD',
        recorded_date => Date::Utility->new,
    });

my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch,
    underlying => 'R_100',
    quote      => 100,
});

subtest 'Enable the tx time trigger for testing' => sub {
    ## Enable the trigger for testing
    _enable_trigger();
    is $?, 0, 'Disabled the trigger successfully';
    BAIL_OUT('Cannot disable the validate_transaction_time_trg') if $?;
};

subtest 'Top up account with money' => sub {
    _disable_trigger();

    my $top_up_q = <<'SQL';
SELECT set_config('binary.session_details', '', true);
INSERT INTO transaction.transaction
    (account_id, referrer_type, action_type, amount, quantity, transaction_time)
VALUES
    (?, ?, ?, ?, ?, ?);
SELECT * FROM transaction.transaction ORDER BY id DESC LIMIT 1;
SQL

    my $result = $db->run(
        fixup => sub {
            $_->selectrow_hashref($top_up_q, undef, $account->id, 'financial_market_bet', 'deposit', 1000, 1, $now->db_timestamp);
        });

    is(Date::Utility->new($result->{transaction_time})->db_timestamp, $now->db_timestamp, 'Adding a tx in the present works');
};

subtest 'Adding a tx 11s older than now should fail' => sub {
    _enable_trigger();

    my $txn = _create_tx($past_11s->db_timestamp);

    my $error_match = qr/Transaction time is too old/;

    my $error;
    warning_like { $error = $txn->buy; } $error_match, 'Sends warning when tx is too old';

    like($error, $error_match, 'sends error when tx is too old');
};

subtest 'Adding a tx 4 days newer than now should fail' => sub {
    _enable_trigger();

    my $txn = _create_tx($future_4d->db_timestamp);

    my $error_match = qr/Transaction time is too new/;

    my $error;
    warning_like { $error = $txn->buy; } $error_match, 'Sends warning when tx is too new';

    like($error, $error_match, 'sends error when tx is too new');
};

## Has to be the last test, o.w. the above will fail
subtest 'Adding a tx between 10s older to 3 days newer should work' => sub {
    _enable_trigger();

    is(_create_tx($past_10s->db_timestamp)->buy, undef, '10s older does not return any error');

    is(_create_tx($future_3d->db_timestamp)->buy, undef, '3 days newer does not return any error');
};

END {
    # Disable the trigger to avoid affecting other tests
    _disable_trigger();
}

sub _disable_trigger {
    note qx{
    sudo -u postgres psql $database -c "
ALTER TABLE transaction.transaction DISABLE TRIGGER validate_transaction_time_trg;"
    };
}

sub _enable_trigger {
    note qx{
    sudo -u postgres psql $database -c "
ALTER TABLE transaction.transaction ENABLE TRIGGER validate_transaction_time_trg;"
    };
}

sub _create_tx {
    my $tx_time = shift;
    $fmb_mock->mock(
        'transaction_data',
        sub {
            return {
                transaction_time => $tx_time,
            };
        });

    my $contract = produce_contract({
        underlying   => 'R_100',
        bet_type     => 'CALL',
        currency     => 'USD',
        payout       => 1,
        duration     => '15m',
        current_tick => $tick,
        barrier      => 'S0P',
    });

    my $txn = BOM::Transaction->new({
        client        => $client,
        contract      => $contract,
        price         => 514.00,
        payout        => $contract->payout,
        amount_type   => 'payout',
        source        => 19,
        purchase_date => $contract->date_start,
    });

    return $txn;
}

done_testing();
1;
