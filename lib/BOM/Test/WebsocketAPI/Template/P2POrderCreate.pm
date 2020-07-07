package BOM::Test::WebsocketAPI::Template::P2POrderCreate;

use strict;
use warnings;
no indirect;

use BOM::Test::WebsocketAPI::Template::DSL;

request p2p_order_create => sub {
    return p2p_order_create => {
        advert_id => $_->p2p_order->advert_id,
        amount    => $_->p2p_order->amount,
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
            advert_id        => $_->p2p_order->advert_id,
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
        account_currency => $_->client->currency,
        amount           => $_->p2p_order->amount,
        amount_display   => $_->p2p_order->amount_display,
        created_time     => $_->p2p_order->created_time,
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
        contact_info     => $_->p2p_order->contact_info,
        payment_info     => $_->p2p_order->payment_info,
        chat_channel_url => $_->p2p_order->chat_channel_url,
        advert_details   => {
            id             => $_->p2p_order->advert_id,
            description    => $_->p2p_order->advert_description,
            type           => $_->p2p_order->advert_type,
            payment_method => $_->p2p_order->payment_method,
        },
        advertiser_details => {
            id         => $_->p2p_order->advertiser_id,
            name       => $_->p2p_order->advertiser_name,
            first_name => $_->p2p_order->advertiser_first_name,
            last_name  => $_->p2p_order->advertiser_last_name,
            loginid    => $_->p2p_order->advertiser_loginid,
        },
        client_details => {
            id         => $_->p2p_order->client_id,
            name       => $_->p2p_order->client_name,
            first_name => $_->p2p_order->client_first_name,
            last_name  => $_->p2p_order->client_last_name,
            loginid    => $_->p2p_order->client_loginid,
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
            contact_info       => $_->p2p_order->contact_info,
            payment_info       => $_->p2p_order->payment_info,
            chat_channel_url   => $_->p2p_order->chat_channel_url,
            advert_details     => {
                id             => $_->p2p_order->advert_id,
                description    => $_->p2p_order->advert_description,
                type           => $_->p2p_order->advert_type,
                payment_method => $_->p2p_order->payment_method,
            },
            advertiser_details => {
                id         => $_->p2p_order->advertiser_id,
                name       => $_->p2p_order->advertiser_name,
                first_name => $_->p2p_order->advertiser_first_name,
                last_name  => $_->p2p_order->advertiser_last_name,
                loginid    => $_->p2p_order->advertiser_loginid,
            },
            client_details => {
                id         => $_->p2p_order->client_id,
                name       => $_->p2p_order->client_name,
                first_name => $_->p2p_order->client_first_name,
                last_name  => $_->p2p_order->client_last_name,
                loginid    => $_->p2p_order->client_loginid,
            },
            },
    };
};

1;
