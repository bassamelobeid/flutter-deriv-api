#!/etc/rmg/bin/perl

use strict;
use warnings;
use Test::MockTime qw/:all/;
use Test::MockModule;
use Test::More;
use Test::Warnings;
use Test::Exception;

use Date::Utility;
use BOM::Transaction;
use BOM::Product::ContractFactory              qw( produce_contract );
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Helper::Client                  qw(create_client top_up);

use BOM::MarketData qw(create_underlying);

my $now = Date::Utility->new;

my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch,
    underlying => 'R_50',
});

my $underlying = create_underlying('R_50');

sub db {
    return BOM::Database::ClientDB->new({
            broker_code => 'CR',
        })->db;
}

sub get_token_trace_from_db {
    my $txnid = shift;

    my $stmt = <<'SQL';
SELECT encode(t.token_hash, $$base64$$)
  FROM transaction.token_trace t
 WHERE t.transaction_id=$1
SQL

    my $db = db;
    $stmt = $db->dbh->prepare($stmt);
    $stmt->execute($txnid);

    my $res = $stmt->fetchrow_arrayref;
    $stmt->finish;

    return $res;
}

my ($cl, $cl1, $cl2);
my $contract = produce_contract({
    underlying   => $underlying,
    bet_type     => 'CALL',
    currency     => 'USD',
    payout       => 1000,
    duration     => '15m',
    current_tick => $tick,
    barrier      => 'S0P',
});

####################################################################
# real tests begin here
####################################################################

lives_ok {
    $cl = create_client;
    top_up $cl, 'USD', 5000;

    is $cl->account->balance + 0, 5000, 'USD balance is 5000';

    $cl1 = create_client;
    top_up $cl1, 'USD', 10000;

    is $cl1->account->balance + 0, 10000, 'cl1: USD balance is 10000';

    $cl2 = create_client;
    top_up $cl2, 'USD', 10000;

    is $cl2->account->balance + 0, 10000, 'cl2: USD balance is 10000';
}
'clients created and funded';

subtest 'buy a bet', sub {
    plan tests => 5;
    lives_ok {
        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 511.47,
            payout        => $contract->payout,
            amount_type   => 'payout',
            source        => 19,
            purchase_date => $contract->date_start,
        });
        is $txn->buy(skip_validation => 1), undef, 'no error';

        is get_token_trace_from_db($txn->transaction_id), undef, 'no token hash in DB';

        $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 511.47,
            payout        => $contract->payout,
            amount_type   => 'payout',
            source        => 19,
            purchase_date => $contract->date_start,
            session_token => 'abcdefghijklmnopqrstuvwxyz1234567890',
        });
        is $txn->buy(skip_validation => 1), undef, 'no error';

        isnt get_token_trace_from_db($txn->transaction_id), undef, 'found token hash in DB';
    }
    'survived';
};

subtest 'buy multiple', sub {
    plan tests => 7;
    lives_ok {
        my $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 511.47,
            payout        => $contract->payout,
            amount_type   => 'payout',
            source        => 19,
            purchase_date => $contract->date_start,
            multiple      => [map { +{loginid => $_->loginid} } $cl1, $cl2],
        });
        is $txn->batch_buy(skip_validation => 1), undef, 'no error';

        for my $m (@{$txn->multiple}) {
            is get_token_trace_from_db($m->{txn}->{id}), undef, 'no token hash in DB';
        }

        $txn = BOM::Transaction->new({
            client        => $cl,
            contract      => $contract,
            price         => 511.47,
            payout        => $contract->payout,
            amount_type   => 'payout',
            source        => 19,
            purchase_date => $contract->date_start,
            multiple      => [map { +{loginid => $_->loginid} } $cl1, $cl2],
            session_token => 'abcdefghijklmnopqrstuvwxyz1234567890',
        });
        is $txn->batch_buy(skip_validation => 1), undef, 'no error';

        for my $m (@{$txn->multiple}) {
            isnt get_token_trace_from_db($m->{txn}->{id}), undef, 'found token hash in DB';
        }
    }
    'survived';
};

done_testing;
