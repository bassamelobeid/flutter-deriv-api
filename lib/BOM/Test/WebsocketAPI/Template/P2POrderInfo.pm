package BOM::Test::WebsocketAPI::Template::P2POrderInfo;

use strict;
use warnings;
no indirect;

use BOM::Test::WebsocketAPI::Template::DSL;

request p2p_order_info => sub {
    return p2p_order_info => {
        id => $_->p2p_order->id,
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
            p2p_order_info => 1,
            subscribe      => 1,
            id             => $_->p2p_order->id,
        },
        source  => '1',
        logging => {},
        token   => $_->client->token
    };
}
qw(client p2p_order);

rpc_response {
    return {
        account_currency => $_->client->currency,
        amount           => $_->p2p_order->amount,
        amount_display   => $_->p2p_order->amount_display,
        created_time     => $_->p2p_order->created_time,
        description      => $_->p2p_order->description,
        expiry_time      => $_->p2p_order->expiry_time,
        id               => $_->p2p_order->id,
        is_incoming      => $_->p2p_order->is_incoming,
        local_currency   => $_->p2p_order->local_currency,
        price            => $_->p2p_order->price,
        price_display    => $_->p2p_order->price_display,
        rate             => $_->p2p_order->rate,
        rate_display     => $_->p2p_order->rate_display,
        status           => $_->p2p_order->status,
        type             => $_->p2p_order->type,
        advert_details   => {
            id          => $_->p2p_order->advert_id,
            description => $_->p2p_order->advert_description,
            type        => $_->p2p_order->advert_type,
        },
        advertiser_details => {
            id   => $_->p2p_order->advertiser_id,
            name => $_->p2p_order->advertiser_name,
        },
    };
};

publish p2p => sub {
    return {
              "P2P::ORDER::NOTIFICATION::"
            . uc($_->client->broker) . '::'
            . uc($_->client->country) . '::'
            . uc($_->client->currency) => {
            account_currency   => $_->client->currency,
            advertiser_loginid => $_->client->loginid,
            amount             => $_->p2p_order->amount,
            amount_display     => $_->p2p_order->amount_display,
            client_loginid     => $_->client->loginid,
            created_time       => $_->p2p_order->created_time,
            description        => $_->p2p_order->description,
            expiry_time        => $_->p2p_order->expiry_time,
            id                 => $_->p2p_order->id,
            is_incoming        => $_->p2p_order->is_incoming,
            local_currency     => $_->p2p_order->local_currency,
            price              => $_->p2p_order->price,
            price_display      => $_->p2p_order->price_display,
            rate               => $_->p2p_order->rate,
            rate_display       => $_->p2p_order->rate_display,
            status             => $_->p2p_order->status,
            type               => $_->p2p_order->type,
            advert_details     => {
                id          => $_->p2p_order->advert_id,
                description => $_->p2p_order->advert_description,
                type        => $_->p2p_order->advert_type,
            },
            advertiser_details => {
                id   => $_->p2p_order->advertiser_id,
                name => $_->p2p_order->advertiser_name,
            },
            },
    };
};

1;
