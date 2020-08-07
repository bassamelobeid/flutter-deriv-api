use strict;
use warnings;

use Test::More;
use Test::MockModule;

use BOM::Test::Helper::P2P;
use BOM::RPC::v3::P2P;
use BOM::Config::Runtime;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);

my @emit_args;
my $mock_emitter = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_emitter->mock(
    'emit' => sub {
        @emit_args = @_;
    });

BOM::Test::Helper::P2P::bypass_sendbird();
my $escrow = BOM::Test::Helper::P2P::create_escrow();

my $app_config = BOM::Config::Runtime->instance->app_config;
$app_config->system->suspend->p2p(0);
$app_config->payments->p2p->enabled(1);
$app_config->payments->p2p->available(1);
$app_config->payments->p2p->available_for_countries(['id']);
$app_config->payments->p2p->available_for_currencies(['usd']);

my $call_args;

subtest 'p2p order create and confirm' => sub {
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        amount => 100,
        type   => 'sell'
    );
    my $client = BOM::Test::Helper::P2P::create_advertiser(balance => 100);

    undef @emit_args;

    $call_args = {
        client => $client,
        args   => {
            advert_id => $advert->{id},
            amount    => 10,
        },
    };
    my $order = BOM::RPC::v3::P2P::p2p_order_create($call_args);
    is scalar @emit_args, 2, 'emitter is called';
    is $emit_args[0], 'p2p_order_created', 'emitted event name is correct';

    is_deeply $emit_args[1],
        {
        client_loginid => $client->loginid,
        order_id       => $order->{id}
        },
        'order-created event args are correct';

    undef @emit_args;
    $call_args->{args} = {
        id => $order->{id},
    };
    my $result = BOM::RPC::v3::P2P::p2p_order_confirm($call_args);
    is_deeply $result,
        {
        id     => $order->{id},
        status => 'buyer-confirmed'
        },
        'order is successfully confirmed';
    is scalar @emit_args, 2, 'emitter is called';
    is $emit_args[0], 'p2p_order_updated', 'emitted event name is correct';

    is_deeply $emit_args[1],
        {
        client_loginid => $client->loginid,
        order_id       => $order->{id},
        order_event    => 'confirmed',
        },
        'buyer confirmation event args are correct';

    undef @emit_args;
    $call_args->{client} = $advertiser;
    $call_args->{args}   = {
        id => $order->{id},
    };
    $result = BOM::RPC::v3::P2P::p2p_order_confirm($call_args);
    is_deeply $result,
        {
        id     => $order->{id},
        status => 'completed'
        },
        'order is successfully completed';
    is scalar @emit_args, 2, 'emitter is called';
    is $emit_args[0], 'p2p_order_updated', 'emitted event name is correct';

    is_deeply $emit_args[1],
        {
        client_loginid => $advertiser->loginid,
        order_id       => $order->{id},
        order_event    => 'confirmed',
        },
        'buyer confirmation event args are correct';
};

subtest 'p2p order create and cancel' => sub {
    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
        amount => 100,
        type   => 'sell'
    );
    my $client = BOM::Test::Helper::P2P::create_advertiser(balance => 100);

    undef @emit_args;

    $call_args = {
        client => $client,
        args   => {
            advert_id => $advert->{id},
            amount    => 10,
        },
    };
    my $order = BOM::RPC::v3::P2P::p2p_order_create($call_args);
    is scalar @emit_args, 2, 'emitter is called';
    is $emit_args[0], 'p2p_order_created', 'emitted event name is correct';

    is_deeply $emit_args[1],
        {
        client_loginid => $client->loginid,
        order_id       => $order->{id}
        },
        'order-created event args are correct';

    undef @emit_args;
    $call_args->{args} = {
        id => $order->{id},
    };
    my $result = BOM::RPC::v3::P2P::p2p_order_cancel($call_args);
    is_deeply $result,
        {
        id     => $order->{id},
        status => 'cancelled'
        },
        'order is successfully cancelled';
    is scalar @emit_args, 2, 'emitter is called';
    is $emit_args[0], 'p2p_order_updated', 'emitted event name is correct';

    is_deeply $emit_args[1],
        {
        client_loginid => $client->loginid,
        order_id       => $order->{id},
        order_event    => 'cancelled',
        },
        'cancellation event args are correct';
};

done_testing()
