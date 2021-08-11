use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::Deep;

use BOM::Test::Helper::P2P;
use BOM::RPC::v3::P2P;
use BOM::Config::Runtime;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);

my @emitted;
my $mock_emitter = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_emitter->mock('emit' => sub { push @emitted, [@_]; });

BOM::Test::Helper::P2P::bypass_sendbird();
my $escrow = BOM::Test::Helper::P2P::create_escrow();

my $app_config = BOM::Config::Runtime->instance->app_config;
$app_config->system->suspend->p2p(0);
$app_config->payments->p2p->enabled(1);
$app_config->payments->p2p->available(1);
$app_config->payments->p2p->available_for_countries([]);
$app_config->payments->p2p->available_for_currencies(['usd']);

my $call_args;

subtest 'p2p order create and confirm' => sub {
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        amount => 100,
        type   => 'sell'
    );
    my $client = BOM::Test::Helper::P2P::create_advertiser(balance => 100);

    @emitted   = ();
    $call_args = {
        client => $client,
        args   => {
            advert_id => $advert->{id},
            amount    => 10,
        },
    };
    my $order = BOM::RPC::v3::P2P::p2p_order_create($call_args);

    cmp_deeply(
        \@emitted,
        bag([
                'p2p_order_created',
                {
                    client_loginid => $client->loginid,
                    order_id       => $order->{id},
                },
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
                    advertiser_id => $client->p2p_advertiser_info->{id},
                }]
        ),
        'expected events for order create'
    );

    @emitted = ();
    $call_args->{args} = {
        id => $order->{id},
    };
    my $result = BOM::RPC::v3::P2P::p2p_order_confirm($call_args);
    cmp_deeply(
        $result,
        {
            id     => $order->{id},
            status => 'buyer-confirmed'
        },
        'order is successfully confirmed'
    );

    cmp_deeply(
        \@emitted,
        [[
                'p2p_order_updated',
                {
                    client_loginid => $client->loginid,
                    order_id       => $order->{id},
                    order_event    => 'confirmed',
                },
            ],

        ],
        'expected event for order confirmation'
    );

    @emitted             = ();
    $call_args->{client} = $advertiser;
    $call_args->{args}   = {
        id => $order->{id},
    };
    $result = BOM::RPC::v3::P2P::p2p_order_confirm($call_args);
    cmp_deeply(
        $result,
        {
            id     => $order->{id},
            status => 'completed'
        },
        'order is successfully completed'
    );

    cmp_deeply(
        \@emitted,
        bag([
                'p2p_order_updated',
                {
                    client_loginid => $advertiser->loginid,
                    order_id       => $order->{id},
                    order_event    => 'confirmed',
                },
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
                    advertiser_id => $advertiser->p2p_advertiser_info->{id},
                }]
        ),
        'expected event for order completion'
    );
};

subtest 'p2p order create and cancel' => sub {
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        amount => 100,
        type   => 'sell'
    );
    my $client = BOM::Test::Helper::P2P::create_advertiser(balance => 100);

    @emitted   = ();
    $call_args = {
        client => $client,
        args   => {
            advert_id => $advert->{id},
            amount    => 10,
        },
    };
    my $order = BOM::RPC::v3::P2P::p2p_order_create($call_args);

    cmp_deeply(
        \@emitted,
        bag([
                'p2p_order_created',
                {
                    client_loginid => $client->loginid,
                    order_id       => $order->{id},
                },
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
                    advertiser_id => $client->p2p_advertiser_info->{id},
                }]
        ),
        'expected events for order create'
    );

    @emitted = ();
    $call_args->{args} = {
        id => $order->{id},
    };
    my $result = BOM::RPC::v3::P2P::p2p_order_cancel($call_args);
    cmp_deeply(
        $result,
        {
            id     => $order->{id},
            status => 'cancelled'
        },
        'order is successfully cancelled'
    );

    cmp_deeply(
        \@emitted,
        bag([
                'p2p_order_updated',
                {
                    client_loginid => $client->loginid,
                    order_id       => $order->{id},
                    order_event    => 'cancelled',
                },

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
                    advertiser_id => $client->p2p_advertiser_info->{id},
                }]
        ),
        'expected events emitted for cancellation'
    );

};

subtest 'Order dispute (type buy)' => sub {
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(type => 'sell');
    my ($client,     $order)  = BOM::Test::Helper::P2P::create_order(advert_id => $advert->{id});

    my $client_token     = BOM::Platform::Token::API->new->create_token($client->loginid,     'test token');
    my $advertiser_token = BOM::Platform::Token::API->new->create_token($advertiser->loginid, 'test token2');
    BOM::Test::Helper::P2P::set_order_disputable($client, $order->{id});

    my $params;
    $params->{client} = $client;
    $params->{args}   = {
        id             => $order->{id},
        dispute_reason => 'seller_not_released',
    };

    @emitted = ();
    my $result = BOM::RPC::v3::P2P::p2p_order_dispute($params);

    cmp_deeply(
        \@emitted,
        [[
                'p2p_order_updated',
                {
                    client_loginid => $client->loginid,
                    order_id       => $order->{id},
                    order_event    => 'dispute',
                },
            ],
        ],
        'expected event for dispute'
    );
};

done_testing()
