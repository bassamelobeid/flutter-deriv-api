use strict;
use warnings;

use Test::More;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::Client;
use BOM::Test::Helper::P2P;
use BOM::Config::Runtime;
use Test::Fatal;
use Data::Dumper;

my @test_cases = (
    #Buy orders:
    {
        test_name      => 'Buy order expire at pending state',
        type           => 'buy',
        amount         => 100,
        error          => undef,
        init_status    => 'pending',
        client_balance => 0,
        agent_balance  => 100,
        escrow         => {
            before => 100,
            after  => 0
        },
        client => {
            before => 0,
            after  => 0
        },
        agent => {
            before => 0,
            after  => 100
        },
        status => 'timed-out',
    },
    {
        test_name      => 'Buy order expire at buyer-confirmed state',
        type           => 'buy',
        amount         => 100,
        error          => undef,
        init_status    => 'buyer-confirmed',
        client_balance => 0,
        agent_balance  => 100,
        escrow         => {
            before => 100,
            after  => 0
        },
        client => {
            before => 0,
            after  => 0
        },
        agent => {
            before => 0,
            after  => 100
        },
        status => 'timed-out',
    },
    # Sell orders
    {
        test_name      => 'Sell order expire at pending state',
        type           => 'sell',
        amount         => 100,
        error          => undef,
        init_status    => 'pending',
        client_balance => 100,
        agent_balance  => 0,
        escrow         => {
            before => 100,
            after  => 0
        },
        client => {
            before => 0,
            after  => 100
        },
        agent => {
            before => 0,
            after  => 0
        },
        status => 'timed-out',
    },
    {
        test_name      => 'Sell order expire at buyer-confirmed state',
        type           => 'sell',
        amount         => 100,
        error          => undef,
        init_status    => 'buyer-confirmed',
        client_balance => 100,
        agent_balance  => 0,
        escrow         => {
            before => 100,
            after  => 0
        },
        client => {
            before => 0,
            after  => 100
        },
        agent => {
            before => 0,
            after  => 0
        },
        status => 'timed-out',
    },
);

for my $status (qw(timed-out)) {
    for my $type (qw(sell buy)) {
        push @test_cases,
            {
            test_name      => "Order expiration at $status status for $type order",
            type           => $type,
            amount         => 100,
            error          => undef,
            init_status    => $status,
            client_balance => $type eq 'buy' ? 0 : 100,
            agent_balance  => $type eq 'buy' ? 100 : 0,
            escrow         => {
                before => 100,
                after  => 100
            },
            client => {
                before => 0,
                after  => 0
            },
            agent => {
                before => 0,
                after  => 0
            },
            status => $status,
            };
    }
}

for my $status (qw(completed cancelled)) {
    for my $type (qw(sell buy)) {
        push @test_cases,
            {
            test_name      => "Order expiration at $status status for $type order",
            type           => $type,
            amount         => 100,
            error          => undef,
            init_status    => $status,
            client_balance => $type eq 'buy' ? 0 : 100,
            agent_balance  => $type eq 'buy' ? 100 : 0,
            escrow         => {
                before => 100,
                after  => 100
            },
            client => {
                before => 0,
                after  => 0
            },
            agent => {
                before => 0,
                after  => 0
            },
            status => $status,
            };
    }

}

for my $test_case (@test_cases) {
    subtest $test_case->{test_name} => sub {
        my $amount = $test_case->{amount};
        my $source = 1;

        my $escrow = BOM::Test::Helper::P2P::create_escrow();
        my ($agent, $offer) = BOM::Test::Helper::P2P::create_offer(
            amount  => $amount,
            type    => $test_case->{type},
            balance => $test_case->{agent_balance},
        );
        my ($client, $order) = BOM::Test::Helper::P2P::create_order(
            offer_id => $offer->{offer_id},
            amount   => $amount,
            balance  => $test_case->{client_balance},
        );

        cmp_ok($escrow->account->balance, '==', $test_case->{escrow}{before}, 'Escrow balance is correct');
        cmp_ok($agent->account->balance,  '==', $test_case->{agent}{before},  'Agent balance is correct');
        cmp_ok($client->account->balance, '==', $test_case->{client}{before}, 'Client balance is correct');

        BOM::Test::Helper::P2P::set_order_status($client, $order->{order_id}, $test_case->{init_status});

        my $err = exception {
            $client->p2p_expire_order(
                id     => $order->{order_id},
                source => 5,
                staff  => 'AUTOEXPIRY',
            );
        };

        chomp($err) if $err;

        is($err, $test_case->{error}, 'Got expected error behavior');

        cmp_ok($escrow->account->balance, '==', $test_case->{escrow}{after}, 'Escrow balance is correct');
        cmp_ok($agent->account->balance,  '==', $test_case->{agent}{after},  'Agent balance is correct');
        cmp_ok($client->account->balance, '==', $test_case->{client}{after}, 'Client balance is correct');

        my $order_data = $client->p2p_order($order->{order_id}) // die;

        is($order_data->{status}, $test_case->{status}, 'Status for new order is correct');
        cmp_ok($order_data->{order_amount}, '==', $amount, 'Amount for new order is correct');
        is($order_data->{client_loginid}, $client->loginid,   'Client for new order is correct');
        is($order_data->{agent_loginid},  $agent->loginid,    'Agent for new order is correct');
        is($order_data->{offer_type},     $test_case->{type}, 'Description for new order is correct');

        BOM::Test::Helper::P2P::reset_escrow();
    };
}

done_testing();
