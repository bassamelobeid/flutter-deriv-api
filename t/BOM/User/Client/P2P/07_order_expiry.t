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

BOM::Test::Helper::P2P::bypass_sendbird();

my @test_cases = (
    #Buy orders:
    {
        test_name          => 'Buy order expire at pending state',
        type               => 'sell',
        amount             => 100,
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
        status => 'refunded',
    },
    {
        test_name          => 'Buy order expire at buyer-confirmed state',
        type               => 'sell',
        amount             => 100,
        error              => undef,
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
        status => 'timed-out',
    },
    # Sell orders
    {
        test_name          => 'Sell order expire at pending state',
        type               => 'buy',
        amount             => 100,
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
        status => 'refunded',
    },
    {
        test_name          => 'Sell order expire at buyer-confirmed state',
        type               => 'buy',
        amount             => 100,
        error              => undef,
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
        status => 'timed-out',
    },
);

for my $status (qw(timed-out refunded blocked)) {
    for my $type (qw(sell buy)) {
        push @test_cases,
            {
            test_name          => "Order expiration at $status status for $type order",
            type               => $type,
            amount             => 100,
            error              => undef,
            init_status        => $status,
            client_balance     => $type eq 'sell' ? 0 : 100,
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

for my $status (qw(completed cancelled)) {
    for my $type (qw(sell buy)) {
        push @test_cases,
            {
            test_name          => "Order expiration at $status status for $type order",
            type               => $type,
            amount             => 100,
            error              => undef,
            init_status        => $status,
            client_balance     => $type eq 'sell' ? 0 : 100,
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

for my $test_case (@test_cases) {
    subtest $test_case->{test_name} => sub {
        my $amount = $test_case->{amount};

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

        my $err = exception {
            $client->p2p_expire_order(
                id     => $order->{id},
                source => 5,
                staff  => 'AUTOEXPIRY',
            );
        };
        is($err->{error_code}, $test_case->{error}, 'Got expected error behavior');

        cmp_ok($escrow->account->balance,     '==', $test_case->{escrow}{after},     'Escrow balance is correct');
        cmp_ok($advertiser->account->balance, '==', $test_case->{advertiser}{after}, 'advertiser balance is correct');
        cmp_ok($client->account->balance,     '==', $test_case->{client}{after},     'Client balance is correct');

        my $order_data = $client->p2p_order_info(id => $order->{id}) // die;

        is($order_data->{status}, $test_case->{status}, 'Status for new order is correct');
        cmp_ok($order_data->{amount}, '==', $amount, 'Amount for new order is correct');
        is($order_data->{advert_details}{type}, $test_case->{type}, 'Description for new order is correct');

        BOM::Test::Helper::P2P::reset_escrow();
    };
}

done_testing();
