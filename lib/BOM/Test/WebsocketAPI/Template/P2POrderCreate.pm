package BOM::Test::WebsocketAPI::Template::P2POrderCreate;

use strict;
use warnings;
no indirect;

use BOM::Test::WebsocketAPI::Template::DSL;

request p2p_order_create => sub {
    return p2p_order_create => {
        offer_id => $_->p2p_order->offer_id,
        amount   => $_->p2p_order->amount,
    };
    },
    qw(p2p_order);

rpc_request {
    return {
        brand                      => 'binary',
        language                   => 'EN',
        source_bypass_verification => 0,
        valid_source               => '1',
        country_code               => 'aq',
        args                       => {
            p2p_order_create => 1,
            offer_id         => $_->p2p_order->offer_id,
            amount           => $_->p2p_order->amount,
        },
        source  => '1',
        logging => {},
        token   => $_->client->token
    };
}
qw(client p2p_order);

rpc_response {
    return {
        rate_display                => $_->p2p_order->rate_display,
        offer_id                    => $_->p2p_order->offer_id,
        offer_description           => $_->p2p_order->offer_description,
        expiry_time                 => $_->p2p_order->expiry_time,
        amount                      => $_->p2p_order->amount,
        rate                        => $_->p2p_order->rate,
        agent_name                  => $_->p2p_order->agent_name,
        agent_id                    => $_->p2p_order->agent_id,
        status                      => $_->p2p_order->status,
        local_currency              => $_->p2p_order->local_currency,
        order_id                    => $_->p2p_order->order_id,
        amount_display              => $_->p2p_order->amount_display,
        price                       => $_->p2p_order->price,
        account_currency            => $_->client->currency,
        created_time                => $_->p2p_order->created_time,
        price_display               => $_->p2p_order->price_display,
        order_description           => $_->p2p_order->order_description,
        type                        => $_->p2p_order->type,
        P2P_SUBSCIPTION_BROKER_CODE => $_->client->broker,
    };
};

publish p2p => sub {
    return {
              "P2P::ORDER::NOTIFICATION::"
            . $_->client->broker . '::'
            . $_->p2p_order->order_id => {
            rate_display      => $_->p2p_order->rate_display,
            offer_id          => $_->p2p_order->offer_id,
            offer_description => $_->p2p_order->offer_description,
            expiry_time       => $_->p2p_order->expiry_time,
            amount            => $_->p2p_order->amount,
            rate              => $_->p2p_order->rate,
            agent_name        => $_->p2p_order->agent_name,
            agent_id          => $_->p2p_order->agent_id,
            status            => $_->p2p_order->status,
            local_currency    => $_->p2p_order->local_currency,
            order_id          => $_->p2p_order->order_id,
            amount_display    => $_->p2p_order->amount_display,
            price             => $_->p2p_order->price,
            account_currency  => $_->client->currency,
            created_time      => $_->p2p_order->created_time,
            price_display     => $_->p2p_order->price_display,
            order_description => $_->p2p_order->order_description,
            type              => $_->p2p_order->type,
            },
    };
};

1;
