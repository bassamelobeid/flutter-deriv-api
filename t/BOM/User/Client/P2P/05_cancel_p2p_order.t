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
    #Buy orders client cancellation:
    {
        test_name      => 'Client cancellation at pending state for buy order',
        type           => 'buy',
        amount         => 100,
        who_cancel     => 'client',
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
        status => 'cancelled',
    },
    {
        test_name      => 'Client cancellation at buyer-confirmed status for buy order',
        type           => 'buy',
        amount         => 100,
        who_cancel     => 'client',
        error          => 'PermissionDenied',
        init_status    => 'buyer-confirmed',
        client_balance => 0,
        agent_balance  => 100,
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
        status => 'buyer-confirmed',
    },
    #Buy orders agent cancellation:
    {
        test_name      => 'Agent cancellation at pending status for buy order',
        type           => 'buy',
        amount         => 100,
        who_cancel     => 'agent',
        error          => 'PermissionDenied',
        init_status    => 'pending',
        client_balance => 0,
        agent_balance  => 100,
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
        status => 'pending',
    },
    {
        test_name      => 'Agent cancellation at buyer-confirmed status for buy order',
        type           => 'buy',
        amount         => 100,
        who_cancel     => 'agent',
        error          => 'PermissionDenied',
        init_status    => 'buyer-confirmed',
        client_balance => 0,
        agent_balance  => 100,
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
        status => 'buyer-confirmed',
    },
    #Sell orders client cancellation:
    {
        test_name      => 'Client cancellation at pending state for sell order',
        type           => 'sell',
        amount         => 100,
        who_cancel     => 'client',
        error          => 'PermissionDenied',
        init_status    => 'pending',
        client_balance => 100,
        agent_balance  => 0,
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
        status => 'pending',
    },
    {
        test_name      => 'Client cancellation at buyer-confirmed status for sell order',
        type           => 'sell',
        amount         => 100,
        who_cancel     => 'client',
        error          => 'PermissionDenied',
        init_status    => 'buyer-confirmed',
        client_balance => 100,
        agent_balance  => 0,
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
        status => 'buyer-confirmed',
    },
    #Sell orders agent cancellation:
    {
        test_name      => 'Agent cancellation at pending status for sell order',
        type           => 'sell',
        amount         => 100,
        who_cancel     => 'agent',
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
        status => 'cancelled',
    },
    {
        test_name      => 'Agent cancellation at buyer-confirmed status for sell order',
        type           => 'sell',
        amount         => 100,
        who_cancel     => 'agent',
        error          => 'PermissionDenied',
        init_status    => 'buyer-confirmed',
        client_balance => 100,
        agent_balance  => 0,
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
        status => 'buyer-confirmed',
    },

);

#Adds for test for all states to be sure,
#that there won't be any funds movents at this calls
for my $status (qw(cancelled)) {
    for my $type (qw(sell buy)) {
        for my $who_cancel (qw(client agent)) {
            push @test_cases,
                {
                test_name      => "$who_cancel cancellation at $status status for $type order",
                type           => $type,
                amount         => 100,
                who_cancel     => $who_cancel,
                error          => 'OrderAlreadyCancelled',
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

}

for my $status (qw(completed timed-out)) {
    for my $type (qw(sell buy)) {
        for my $who_cancel (qw(client agent)) {
            push @test_cases,
                {
                test_name      => "$who_cancel cancellation at $status status for $type order",
                type           => $type,
                amount         => 100,
                who_cancel     => $who_cancel,
                error          => 'PermissionDenied',
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

}

# cancellation on expired orders

for my $status (qw(pending buyer-confirmed completed cancelled timed-out)) {
    for my $type (qw(sell buy)) {
        for my $who_cancel (qw(client agent)) {
            push @test_cases,
                {
                test_name      => "$who_cancel cancellation at $status status for expired $type order",
                type           => $type,
                expire         => 1,
                amount         => 100,
                who_cancel     => $who_cancel,
                error          => 'OrderNoEditExpired',
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
        BOM::Test::Helper::P2P::expire_order($client, $order->{order_id}) if $test_case->{expire};

        my $err = exception {
            if ($test_case->{who_cancel} eq 'client') {
                $client->p2p_order_cancel(id => $order->{order_id});
            } elsif ($test_case->{who_cancel} eq 'agent') {
                $agent->p2p_order_cancel(id => $order->{order_id});
            } else {
                die 'Invalid who_cancel value: ' . $test_case->{who_cancel};
            }
        };
        chomp($err) if $err;

        is($err, $test_case->{error}, 'Got expected error behavior (' . ($test_case->{error} // 'none') . ')');

        cmp_ok($escrow->account->balance, '==', $test_case->{escrow}{after}, 'Escrow balance is correct');
        cmp_ok($agent->account->balance,  '==', $test_case->{agent}{after},  'Agent balance is correct');
        cmp_ok($client->account->balance, '==', $test_case->{client}{after}, 'Client balance is correct');

        my $order_data = $client->p2p_order($order->{order_id});

        is($order_data->{status}, $test_case->{status}, 'Status for new order is correct');
        cmp_ok($order_data->{order_amount}, '==', $amount, 'Amount for new order is correct');
        is($order_data->{client_loginid}, $client->loginid,   'Client for new order is correct');
        is($order_data->{agent_loginid},  $agent->loginid,    'Agent for new order is correct');
        is($order_data->{offer_type},     $test_case->{type}, 'Offer type is correct');

        BOM::Test::Helper::P2P::reset_escrow();
    };
}

done_testing();
