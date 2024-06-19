#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;

use BOM::Test::Data::Utility::UnitTestDatabase   qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase   qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis      qw(initialize_realtime_ticks_db);
use BOM::Test::Helper::Client                    qw(create_client top_up);

use Test::MockModule;

# the stack checking code is run only if rand()<0.01.
# this should ensure it is always run.
my $rand;

BEGIN {
    *CORE::GLOBAL::rand = sub { $rand->() };
}

use BOM::Transaction;
use Date::Utility;
use BOM::Product::ContractFactory qw(produce_contract);

my $datadog_mock = Test::MockModule->new('DataDog::DogStatsd');
my @datadog_actions;
for my $mock (qw(increment decrement timing gauge count)) {
    $datadog_mock->mock($mock => sub { shift; push @datadog_actions => {action_name => $mock, data => \@_} });
}

my $client = create_client('CR');
top_up $client, 'USD', 5000;
my $underlying_symbol = 'R_50';

my $now = Date::Utility->new;

BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100.01, $now->epoch - 1, $underlying_symbol],
    [100, $now->epoch, $underlying_symbol]);

my $contract_args = {
    bet_type     => 'CALL',
    underlying   => $underlying_symbol,
    barrier      => 'S0P',
    date_start   => $now,
    date_pricing => $now,
    duration     => '15m',
    currency     => 'USD',
    payout       => 100,
};

my $contract = produce_contract($contract_args);

subtest 'datadog-stackdepth' => sub {
    plan tests => 8;

    my $txn = BOM::Transaction->new({
        client        => $client,
        contract      => $contract,
        price         => $contract->ask_price,
        purchase_date => $now,
        amount_type   => 'payout',
    });
    @datadog_actions = ();
    $rand            = sub { 0.0099 };
    is $txn->buy(skip_validation => 1), undef, "no error in transaction buy";

    # note explain @datadog_actions;
    ok 1 == grep({ $_->{action_name} eq 'gauge' and $_->{data}->[0] eq 'transaction.buy.stack_depth' } @datadog_actions),
        'stack_depth DD message found if rand()<0.01';

    $txn = BOM::Transaction->new({
        client        => $client,
        contract      => $contract,
        price         => $contract->ask_price,
        purchase_date => $now,
        amount_type   => 'payout',
    });
    @datadog_actions = ();
    $rand            = sub { 0.01 };
    is $txn->buy(skip_validation => 1), undef, "no error in transaction buy";

    # note explain @datadog_actions;
    ok 0 == grep({ $_->{action_name} eq 'gauge' and $_->{data}->[0] eq 'transaction.buy.stack_depth' } @datadog_actions),
        'stack_depth DD message not found if rand()>=0.01';

    $txn = BOM::Transaction->new({
        client        => $client,
        contract      => $contract,
        price         => $contract->ask_price,
        purchase_date => $now,
        amount_type   => 'payout',
    });
    @datadog_actions = ();
    $rand            = sub { 0.0099 };

    my $rec;
    $rec = sub {
        if ($_[0] > 0) {
            $rec->($_[0] - 1);
        } else {
            is $txn->buy(skip_validation => 1), undef, "no error in transaction buy";
        }
    };

    # here we exercise that no extra warnings or so are generated if the
    # stack trace file cannot be created
    -d "/var/lib/binary/BOM::Transaction" and system "rm -rf /var/lib/binary/BOM::Transaction";
    -d "/var/lib/binary/BOM::Transaction" and BAIL_OUT "Can't remove /var/lib/binary/BOM::Transaction";

    $rec->(70);
    # note explain @datadog_actions;
    cmp_ok + (grep { $_->{action_name} eq 'gauge' and $_->{data}->[0] eq 'transaction.buy.stack_depth' } @datadog_actions)[0]->{data}->[1], '>', 70,
        'stack_depth > 70';

    # now the same again but with a stack trace file
    $txn = BOM::Transaction->new({
        client        => $client,
        contract      => $contract,
        price         => $contract->ask_price,
        purchase_date => $now,
        amount_type   => 'payout',
    });
    mkdir "/var/lib/binary/BOM::Transaction" or BAIL_OUT "Can't create /var/lib/binary/BOM::Transaction";
    $rec->(70);
    ok -f -s ("/var/lib/binary/BOM::Transaction/" . ($$ % 1000) . '.stacktrace'), 'stacktrace file exists';

    # clean up
    system "rm -rf /var/lib/binary/BOM::Transaction";
};

done_testing();
