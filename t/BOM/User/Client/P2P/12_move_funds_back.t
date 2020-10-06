use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Fatal;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client;
use BOM::Test::Helper::P2P;
use BOM::Config::Runtime;

BOM::Config::Runtime->instance->app_config->payments->p2p->escrow([]);
BOM::Test::Helper::P2P::bypass_sendbird();
my $days_needed = BOM::Config::Runtime->instance->app_config->payments->p2p->refund_timeout;

my %last_event;
my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_events->mock(
    'emit',
    sub {
        my ($type, $data) = @_;
        %last_event = (
            type => $type,
            data => $data
        );
    });

subtest 'Move funds back (order type buy)' => sub {
    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my $amount = 100;

    my ($advertiser, $advert_info) = BOM::Test::Helper::P2P::create_advert(
        amount  => $amount,
        type    => 'sell',
        balance => 1000,
    );

    my ($client, $order) = BOM::Test::Helper::P2P::create_order(
        advert_id => $advert_info->{id},
        amount    => $amount,
        balance   => 500,
    );

    my $balances = {
        client     => $client->account->balance,
        advertiser => $advertiser->account->balance,
        escrow     => $escrow->account->balance,
    };

    BOM::Test::Helper::P2P::ready_to_refund($client, $order->{id});
    my $result = $client->p2p_timeout_refund(
        id     => $order->{id},
        source => 5,
        staff  => 'AUTOEXPIRY',
    );

    cmp_deeply(
        \%last_event,
        {
            type => 'p2p_order_updated',
            data => {
                client_loginid => $client->loginid,
                order_id       => $result->{id},
                order_event    => 'timeout_refund'
            }
        },
        'p2p_order_updated event emitted'
    );

    is $result->{status}, 'refunded', 'The order has been refunded';
    cmp_ok($client->account->balance,     '==', $balances->{client},               'The client balance is not involved in this refund');
    cmp_ok($advertiser->account->balance, '==', $balances->{advertiser} + $amount, 'The advertiser got refunded it seems');
    cmp_ok($escrow->account->balance,     '==', $balances->{escrow} - $amount,     'Escrow balance is correct');

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Move funds back (order type sell)' => sub {
    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my $amount = 100;

    my ($advertiser, $advert_info) = BOM::Test::Helper::P2P::create_advert(
        amount  => $amount,
        type    => 'buy',
        balance => 1000,
    );

    my ($client, $order) = BOM::Test::Helper::P2P::create_order(
        advert_id => $advert_info->{id},
        amount    => $amount,
        balance   => 500,
    );

    my $balances = {
        client     => $client->account->balance,
        advertiser => $advertiser->account->balance,
        escrow     => $escrow->account->balance,
    };

    BOM::Test::Helper::P2P::ready_to_refund($client, $order->{id});
    my $result = $client->p2p_timeout_refund(
        id     => $order->{id},
        source => 5,
        staff  => 'AUTOEXPIRY',
    );

    is $result->{status}, 'refunded', 'The order has been refunded';
    cmp_ok($client->account->balance,     '==', $balances->{client} + $amount, 'The client got refunded it seems');
    cmp_ok($advertiser->account->balance, '==', $balances->{advertiser},       'The advertiser balance is not involved in this refund');
    cmp_ok($escrow->account->balance,     '==', $balances->{escrow} - $amount, 'Escrow balance is correct');

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Different ways to fail the refund' => sub {
    my $escrow = BOM::Test::Helper::P2P::create_escrow();
    my $amount = 100;

    my ($advertiser, $advert_info) = BOM::Test::Helper::P2P::create_advert(
        amount  => $amount,
        type    => 'buy',
        balance => 1000,
    );

    my ($client, $order) = BOM::Test::Helper::P2P::create_order(
        advert_id => $advert_info->{id},
        amount    => $amount,
        balance   => 500,
    );

    # Order not found due to negative id
    my $exception = exception {
        $client->p2p_timeout_refund(
            id     => $order->{id} * -1,
            source => 5,
            staff  => 'AUTOEXPIRY',
        );
    };

    like $exception, qr/P2P Order not found/, 'Order not found';

    # Cannot move funds back due to invalid status
    BOM::Test::Helper::P2P::set_order_status($client, $order->{id}, 'pending');
    $exception = exception {
        $client->p2p_timeout_refund(
            id     => $order->{id},
            source => 5,
            staff  => 'AUTOEXPIRY',
        );
    };

    like $exception, qr/Cannot refund P2P order/, 'Cannot move funds, invalid status';

    # Cannot move funds back due to NN days threshold
    BOM::Test::Helper::P2P::ready_to_refund($client, $order->{id}, $days_needed - 1);
    $exception = exception {
        $client->p2p_timeout_refund(
            id     => $order->{id},
            source => 5,
            staff  => 'AUTOEXPIRY',
        );
    };

    like $exception, qr/P2P Order is not ready to refund/, sprintf('Cannot move funds, %s days are needed', $days_needed);

    # Escrow not found
    my $mock = Test::MockModule->new('BOM::User::Client');
    $mock->mock(
        'p2p_escrow',
        sub {
            return 0;
        });

    BOM::Test::Helper::P2P::ready_to_refund($client, $order->{id});
    $exception = exception {
        $client->p2p_timeout_refund(
            id     => $order->{id},
            source => 5,
            staff  => 'AUTOEXPIRY',
        );
    };

    like $exception, qr/Escrow not found/, 'Escrow not found';

    $mock->unmock_all;
    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Boundary' => sub {
    for my $days ($days_needed - 1, $days_needed, $days_needed + 1) {
        subtest sprintf('%d days', $days) => sub {
            my $escrow = BOM::Test::Helper::P2P::create_escrow();
            my $amount = 100;

            my ($advertiser, $advert_info) = BOM::Test::Helper::P2P::create_advert(
                amount  => $amount,
                type    => 'buy',
                balance => 1000,
            );

            my ($client, $order) = BOM::Test::Helper::P2P::create_order(
                advert_id => $advert_info->{id},
                amount    => $amount,
                balance   => 500,
            );

            BOM::Test::Helper::P2P::ready_to_refund($client, $order->{id}, $days);
            my $exception = exception {
                $client->p2p_timeout_refund(
                    id     => $order->{id},
                    source => 5,
                    staff  => 'AUTOEXPIRY',
                );
            };

            like $exception, qr/P2P Order is not ready to refund/, 'Exception thrown for not ready to refund P2P order' if $days < $days_needed;
            ok !$exception, 'No exception for ready to refund P2P order' if $days >= $days_needed;
        }
    }
};

done_testing();
