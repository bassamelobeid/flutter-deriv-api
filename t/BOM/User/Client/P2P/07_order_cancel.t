use strict;
use warnings;

use Test::More;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Helper::Client;
use BOM::Test::Helper::P2P;
use BOM::Config::Runtime;
use Test::Fatal;
use Test::MockModule;
use Test::Deep;

BOM::Test::Helper::P2P::bypass_sendbird();

my @emitted_events;
my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_events->mock('emit' => sub { push @emitted_events, [@_] });

my @test_cases = (
    #Buy orders client cancellation
    {
        test_name          => 'Client cancellation at pending state for buy order',
        type               => 'sell',
        amount             => 100,
        who_cancel         => 'client',
        error              => undef,
        init_status        => 'pending',
        client_balance     => 0,
        advertiser_balance => 100,
        escrow             => {
            before => 100,
            after  => 0
        },
        client => {
            before => 0,
            after  => 0
        },
        advertiser => {
            before => 0,
            after  => 100
        },
        status => 'cancelled',
    },
    {
        test_name          => 'Client cancellation at buyer-confirmed status for buy order',
        type               => 'sell',
        amount             => 100,
        who_cancel         => 'client',
        error              => 'PermissionDenied',
        init_status        => 'buyer-confirmed',
        client_balance     => 0,
        advertiser_balance => 100,
        escrow             => {
            before => 100,
            after  => 100
        },
        client => {
            before => 0,
            after  => 0
        },
        advertiser => {
            before => 0,
            after  => 0
        },
        status => 'buyer-confirmed',
    },
    #Buy orders advertiser cancellation:
    {
        test_name          => 'advertiser cancellation at pending status for buy order',
        type               => 'sell',
        amount             => 100,
        who_cancel         => 'advertiser',
        error              => 'PermissionDenied',
        init_status        => 'pending',
        client_balance     => 0,
        advertiser_balance => 100,
        escrow             => {
            before => 100,
            after  => 100
        },
        client => {
            before => 0,
            after  => 0
        },
        advertiser => {
            before => 0,
            after  => 0
        },
        status => 'pending',
    },
    {
        test_name          => 'advertiser cancellation at buyer-confirmed status for buy order',
        type               => 'sell',
        amount             => 100,
        who_cancel         => 'advertiser',
        error              => 'PermissionDenied',
        init_status        => 'buyer-confirmed',
        client_balance     => 0,
        advertiser_balance => 100,
        escrow             => {
            before => 100,
            after  => 100
        },
        client => {
            before => 0,
            after  => 0
        },
        advertiser => {
            before => 0,
            after  => 0
        },
        status => 'buyer-confirmed',
    },
    #Sell orders client cancellation:
    {
        test_name          => 'Client cancellation at pending state for sell order',
        type               => 'buy',
        amount             => 100,
        who_cancel         => 'client',
        error              => 'PermissionDenied',
        init_status        => 'pending',
        client_balance     => 100,
        advertiser_balance => 0,
        escrow             => {
            before => 100,
            after  => 100
        },
        client => {
            before => 0,
            after  => 0
        },
        advertiser => {
            before => 0,
            after  => 0
        },
        status => 'pending',
    },
    {
        test_name          => 'Client cancellation at buyer-confirmed status for sell order',
        type               => 'buy',
        amount             => 100,
        who_cancel         => 'client',
        error              => 'PermissionDenied',
        init_status        => 'buyer-confirmed',
        client_balance     => 100,
        advertiser_balance => 0,
        escrow             => {
            before => 100,
            after  => 100
        },
        client => {
            before => 0,
            after  => 0
        },
        advertiser => {
            before => 0,
            after  => 0
        },
        status => 'buyer-confirmed',
    },
    #Sell orders advertiser cancellation:
    {
        test_name          => 'advertiser cancellation at pending status for sell order',
        type               => 'buy',
        amount             => 100,
        who_cancel         => 'advertiser',
        error              => undef,
        init_status        => 'pending',
        client_balance     => 100,
        advertiser_balance => 0,
        escrow             => {
            before => 100,
            after  => 0
        },
        client => {
            before => 0,
            after  => 100
        },
        advertiser => {
            before => 0,
            after  => 0
        },
        status => 'cancelled',
    },
    {
        test_name          => 'advertiser cancellation at buyer-confirmed status for sell order',
        type               => 'buy',
        amount             => 100,
        who_cancel         => 'advertiser',
        error              => 'PermissionDenied',
        init_status        => 'buyer-confirmed',
        client_balance     => 100,
        advertiser_balance => 0,
        escrow             => {
            before => 100,
            after  => 100
        },
        client => {
            before => 0,
            after  => 0
        },
        advertiser => {
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
        for my $who_cancel (qw(client advertiser)) {
            push @test_cases,
                {
                test_name          => "$who_cancel cancellation at $status status for $type order",
                type               => $type,
                amount             => 100,
                who_cancel         => $who_cancel,
                error              => 'OrderAlreadyCancelled',
                init_status        => $status,
                client_balance     => $type eq 'sell' ? 0   : 100,
                advertiser_balance => $type eq 'sell' ? 100 : 0,
                escrow             => {
                    before => 100,
                    after  => 100
                },
                client => {
                    before => 0,
                    after  => 0
                },
                advertiser => {
                    before => 0,
                    after  => 0
                },
                status => $status,
                };
        }
    }

}

for my $status (qw(completed timed-out blocked refunded)) {
    for my $type (qw(sell buy)) {
        for my $who_cancel (qw(client advertiser)) {
            push @test_cases,
                {
                test_name          => "$who_cancel cancellation at $status status for $type order",
                type               => $type,
                amount             => 100,
                who_cancel         => $who_cancel,
                error              => 'PermissionDenied',
                init_status        => $status,
                client_balance     => $type eq 'sell' ? 0   : 100,
                advertiser_balance => $type eq 'sell' ? 100 : 0,
                escrow             => {
                    before => 100,
                    after  => 100
                },
                client => {
                    before => 0,
                    after  => 0
                },
                advertiser => {
                    before => 0,
                    after  => 0
                },
                status => $status,
                };
        }
    }

}

# cancellation on expired orders

for my $status (qw(pending buyer-confirmed completed cancelled timed-out blocked refunded)) {
    for my $type (qw(sell buy)) {
        for my $who_cancel (qw(client advertiser)) {
            push @test_cases,
                {
                test_name          => "$who_cancel cancellation at $status status for expired $type order",
                type               => $type,
                expire             => 1,
                amount             => 100,
                who_cancel         => $who_cancel,
                error              => 'OrderNoEditExpired',
                init_status        => $status,
                client_balance     => $type eq 'sell' ? 0   : 100,
                advertiser_balance => $type eq 'sell' ? 100 : 0,
                escrow             => {
                    before => 100,
                    after  => 100
                },
                client => {
                    before => 0,
                    after  => 0
                },
                advertiser => {
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
        my ($advertiser, $advert_info) = BOM::Test::Helper::P2P::create_advert(
            amount  => $amount,
            type    => $test_case->{type},
            balance => $test_case->{advertiser_balance},
        );
        my ($client, $order) = BOM::Test::Helper::P2P::create_order(
            advert_id => $advert_info->{id},
            amount    => $amount,
            balance   => $test_case->{client_balance},
        );

        cmp_ok($escrow->account->balance,     '==', $test_case->{escrow}{before},     'Escrow balance is correct');
        cmp_ok($advertiser->account->balance, '==', $test_case->{advertiser}{before}, 'advertiser balance is correct');
        cmp_ok($client->account->balance,     '==', $test_case->{client}{before},     'Client balance is correct');

        BOM::Test::Helper::P2P::set_order_status($client, $order->{id}, $test_case->{init_status});
        BOM::Test::Helper::P2P::expire_order($client, $order->{id}) if $test_case->{expire};

        @emitted_events = ();
        my $loginid;
        my $err = exception {
            if ($test_case->{who_cancel} eq 'client') {
                $client->p2p_order_cancel(id => $order->{id});
                $loginid = $client->loginid;
            } elsif ($test_case->{who_cancel} eq 'advertiser') {
                $advertiser->p2p_order_cancel(id => $order->{id});
                $loginid = $advertiser->loginid;
            } else {
                die 'Invalid who_cancel value: ' . $test_case->{who_cancel};
            }
        };
        is($err->{error_code}, $test_case->{error}, 'Got expected error behavior (' . ($test_case->{error} // 'none') . ')');

        cmp_ok($escrow->account->balance,     '==', $test_case->{escrow}{after},     'Escrow balance is correct');
        cmp_ok($advertiser->account->balance, '==', $test_case->{advertiser}{after}, 'advertiser balance is correct');
        cmp_ok($client->account->balance,     '==', $test_case->{client}{after},     'Client balance is correct');

        my $order_data = $client->p2p_order_info(id => $order->{id});

        is($order_data->{status}, $test_case->{status}, 'Status for new order is correct');
        cmp_ok($order_data->{amount}, '==', $amount, 'Amount for new order is correct');
        is($order_data->{advert_details}{type}, $test_case->{type}, 'advert type is correct');

        if ($test_case->{error}) {
            ok !@emitted_events, 'no events emitted';
        } else {
            cmp_deeply(
                \@emitted_events,
                bag([
                        'p2p_order_updated',
                        {
                            client_loginid => $loginid,
                            order_id       => $order->{id},
                            order_event    => 'cancelled',
                        }
                    ],
                    [
                        'p2p_advertiser_updated',
                        {
                            client_loginid => $client->loginid,
                        }
                    ],
                    [
                        'p2p_advertiser_updated',
                        {
                            client_loginid => $advertiser->loginid,
                        }
                    ],
                    [
                        'p2p_adverts_updated',
                        {
                            advertiser_id => $test_case->{type} eq 'sell'
                            ? $client->p2p_advertiser_info->{id}
                            : $advertiser->p2p_advertiser_info->{id},
                        }
                    ],
                ),
                'expected events emitted'
            );
        }

        BOM::Test::Helper::P2P::reset_escrow();
    };
}

done_testing();
