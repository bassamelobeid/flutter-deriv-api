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
    #Sell orders client confirmation:
    {
        test_name          => 'Client confirmation at pending state for buy order',
        type               => 'sell',
        amount             => 100,
        who_confirm        => 'client',
        error              => undef,
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
        status => 'buyer-confirmed',
    },
    {
        test_name          => 'Client confirmation at buyer-confirmed status for buy order',
        type               => 'sell',
        amount             => 100,
        who_confirm        => 'client',
        error              => 'OrderAlreadyConfirmed',
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
    #Sell orders advertiser confirmation:
    {
        test_name          => 'advertiser confirmation at pending status for buy order',
        type               => 'sell',
        amount             => 100,
        who_confirm        => 'advertiser',
        error              => 'InvalidStateForConfirmation',
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
        test_name          => 'advertiser confirmation at buyer-confirmed status for buy order',
        type               => 'sell',
        amount             => 100,
        who_confirm        => 'advertiser',
        error              => undef,
        init_status        => 'buyer-confirmed',
        client_balance     => 0,
        advertiser_balance => 100,
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
        status => 'completed',
    },
    #Buy orders client confirmation:
    {
        test_name          => 'Client confirmation at pending state for sell order',
        type               => 'buy',
        amount             => 100,
        who_confirm        => 'client',
        error              => 'InvalidStateForConfirmation',
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
        test_name          => 'Client confirmation at buyer-confirmed status for sell order',
        type               => 'buy',
        amount             => 100,
        who_confirm        => 'client',
        error              => undef,
        init_status        => 'buyer-confirmed',
        client_balance     => 100,
        advertiser_balance => 0,
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
        status => 'completed',
    },
    #Buy orders advertiser confirmation:
    {
        test_name          => 'advertiser confirmation at pending status for sell order',
        type               => 'buy',
        amount             => 100,
        who_confirm        => 'advertiser',
        error              => undef,
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
        status => 'buyer-confirmed',
    },
    {
        test_name          => 'advertiser confirmation at buyer-confirmed status for sell order',
        type               => 'buy',
        amount             => 100,
        who_confirm        => 'advertiser',
        error              => 'OrderAlreadyConfirmed',
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
for my $status (qw(completed)) {
    for my $type (qw(sell buy)) {
        for my $who_confirm (qw(client advertiser)) {
            push @test_cases,
                {
                test_name          => "$who_confirm confirmation at $status status for $type order",
                type               => $type,
                amount             => 100,
                who_confirm        => $who_confirm,
                error              => 'OrderAlreadyConfirmed',
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

}

for my $status (qw(cancelled timed-out refunded)) {
    for my $type (qw(sell buy)) {
        for my $who_confirm (qw(client advertiser)) {
            push @test_cases,
                {
                test_name          => "$who_confirm confirmation at $status status for $type order",
                type               => $type,
                amount             => 100,
                who_confirm        => $who_confirm,
                error              => 'InvalidStateForConfirmation',
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

}

# confirmation on expired orders

for my $status (qw(pending buyer-confirmed completed cancelled timed-out refunded)) {
    for my $type (qw(sell buy)) {
        for my $who_confirm (qw(client advertiser)) {
            push @test_cases,
                {
                test_name          => "$who_confirm confirmation at $status status for expired $type order",
                type               => $type,
                expire             => 1,
                amount             => 100,
                who_confirm        => $who_confirm,
                error              => 'OrderNoEditExpired',
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

}

for my $test_case (@test_cases) {
    #next unless $test_case->{test_name} eq 'Client confirmation at pending state for buy order';
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

        my $resp;
        my $err = exception {
            if ($test_case->{who_confirm} eq 'client') {
                $resp = $client->p2p_order_confirm(id => $order->{id});
            } elsif ($test_case->{who_confirm} eq 'advertiser') {
                $resp = $advertiser->p2p_order_confirm(id => $order->{id});
            } else {
                die 'Invalid who_confirm value: ' . $test_case->{who_confirm};
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

        BOM::Test::Helper::P2P::reset_escrow();
    };
}

subtest 'Advertiser confirms pending buy order' => sub {
    BOM::Config::Runtime->instance->app_config->payments->p2p->limits->maximum_advert(100);
    BOM::Test::Helper::P2P::create_escrow();

    my $ad_amount = 100;
    my ($advertiser, $advert_info) = BOM::Test::Helper::P2P::create_advert(
        amount           => $ad_amount,
        max_order_amount => $ad_amount,
        type             => 'sell'
    );

    my $client = BOM::Test::Helper::Client::create_client();

    my $order = $client->p2p_order_create(
        advert_id => $advert_info->{id},
        amount    => $advert_info->{amount},
    );

    my $err = exception {
        $advertiser->p2p_order_confirm(id => $order->{id})
    };

    is $err->{error_code}, 'InvalidStateForConfirmation', 'InvalidStateForConfirmation';

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Client confirms not pending (cancelled) buy order' => sub {
    BOM::Config::Runtime->instance->app_config->payments->p2p->limits->maximum_advert(100);
    BOM::Test::Helper::P2P::create_escrow();

    my $ad_amount = 100;
    my ($advertiser, $advert_info) = BOM::Test::Helper::P2P::create_advert(
        amount           => $ad_amount,
        max_order_amount => $ad_amount,
        type             => 'sell'
    );

    my $client = BOM::Test::Helper::Client::create_client();

    my $order = $client->p2p_order_create(
        advert_id => $advert_info->{id},
        amount    => $advert_info->{amount},
    );

    ok $client->p2p_order_cancel(id => $order->{id}), 'Client cancels the order';

    my $err = exception {
        $client->p2p_order_confirm(id => $order->{id})
    };

    is $err->{error_code}, 'InvalidStateForConfirmation', 'InvalidStateForConfirmation';

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Client confirms pending sell order' => sub {
    BOM::Config::Runtime->instance->app_config->payments->p2p->limits->maximum_advert(100);
    BOM::Test::Helper::P2P::create_escrow();

    my $ad_amount = 100;
    my ($advertiser, $advert_info) = BOM::Test::Helper::P2P::create_advert(
        amount           => $ad_amount,
        max_order_amount => $ad_amount,
        type             => 'buy'
    );

    my $client = BOM::Test::Helper::Client::create_client();
    $client->account('USD');
    BOM::Test::Helper::Client::top_up($client, $client->currency, $ad_amount);

    ok my $order = $client->p2p_order_create(
        advert_id    => $advert_info->{id},
        amount       => $advert_info->{amount},
        contact_info => 'contact info',
        payment_info => 'payment info',
    );

    my $err = exception {
        $client->p2p_order_confirm(id => $order->{id})
    };

    is $err->{error_code}, 'InvalidStateForConfirmation', 'InvalidStateForConfirmation';

    BOM::Test::Helper::P2P::reset_escrow();
};

subtest 'Advertiser confirms not pending (cancelled) sell order' => sub {
    BOM::Config::Runtime->instance->app_config->payments->p2p->limits->maximum_advert(100);
    BOM::Test::Helper::P2P::create_escrow();

    my $ad_amount = 100;
    my ($advertiser, $advert_info) = BOM::Test::Helper::P2P::create_advert(
        amount           => $ad_amount,
        max_order_amount => $ad_amount,
        type             => 'buy'
    );

    my $client = BOM::Test::Helper::Client::create_client();

    $client->account('USD');
    BOM::Test::Helper::Client::top_up($client, $client->currency, $ad_amount);

    my $order = $client->p2p_order_create(
        advert_id    => $advert_info->{id},
        amount       => $advert_info->{amount},
        contact_info => 'contact info',
        payment_info => 'payment info',
    );

    ok $advertiser->p2p_order_cancel(id => $order->{id});

    my $err = exception {
        $advertiser->p2p_order_confirm(id => $order->{id})
    };

    is $err->{error_code}, 'InvalidStateForConfirmation', 'InvalidStateForConfirmation';

    BOM::Test::Helper::P2P::reset_escrow();
};

done_testing();
