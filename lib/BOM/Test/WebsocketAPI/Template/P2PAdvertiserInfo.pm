package BOM::Test::WebsocketAPI::Template::P2PAdvertiserInfo;

use strict;
use warnings;
no indirect;

use BOM::Test::WebsocketAPI::Template::DSL;

request p2p_advertiser_info => sub {
    return p2p_advertiser_info => {
        id => $_->p2p_advertiser->id,
    };
    },
    qw(p2p_advertiser);

rpc_request {
    return {
        brand                      => 'binary',
        language                   => 'EN',
        source_bypass_verification => 0,
        valid_source               => '1',
        country_code               => 'aq',
        args                       => {
            p2p_advertiser_info => 1,
            subscribe           => 1,
            id                  => $_->p2p_advertiser->id,
        },
        source  => '1',
        logging => {},
        token   => $_->client->token
    };
}
qw(client p2p_advertiser);

rpc_response {
    return {
        contact_info               => $_->p2p_advertiser->contact_info,
        created_time               => $_->p2p_advertiser->created_time,
        default_advert_description => $_->p2p_advertiser->default_advert_description,
        id                         => $_->p2p_advertiser->id,
        is_approved                => $_->p2p_advertiser->is_approved,
        is_listed                  => $_->p2p_advertiser->is_listed,
        name                       => $_->p2p_advertiser->name,
        payment_info               => $_->p2p_advertiser->payment_info,
        chat_token                 => $_->p2p_advertiser->chat_token,
        chat_user_id               => $_->p2p_advertiser->chat_user_id,
        buy_completion_rate        => $_->p2p_advertiser->buy_completion_rate,
        buy_orders_count           => $_->p2p_advertiser->buy_orders_count,
        cancel_time_avg            => $_->p2p_advertiser->cancel_time_avg,
        release_time_avg           => $_->p2p_advertiser->release_time_avg,
        sell_completion_rate       => $_->p2p_advertiser->sell_completion_rate,
        sell_orders_count          => $_->p2p_advertiser->sell_orders_count,
        total_orders_count         => $_->p2p_advertiser->total_orders_count,
        total_completion_rate      => $_->p2p_advertiser->total_completion_rate,
        basic_verification         => $_->p2p_advertiser->basic_verification,
        full_verification          => $_->p2p_advertiser->full_verification,
    };
};

publish p2p => sub {
    return {
        "P2P::ADVERTISER::NOTIFICATION::"
            . uc($_->client->broker) => {
            client_loginid             => $_->client->loginid,
            contact_info               => $_->p2p_advertiser->contact_info,
            created_time               => $_->p2p_advertiser->created_time,
            default_advert_description => $_->p2p_advertiser->default_advert_description,
            id                         => $_->p2p_advertiser->id,
            is_approved                => $_->p2p_advertiser->is_approved,
            is_listed                  => $_->p2p_advertiser->is_listed,
            name                       => $_->p2p_advertiser->name,
            payment_info               => $_->p2p_advertiser->payment_info,
            chat_token                 => $_->p2p_advertiser->chat_token,
            chat_user_id               => $_->p2p_advertiser->chat_user_id,
            buy_completion_rate        => $_->p2p_advertiser->buy_completion_rate,
            buy_orders_count           => $_->p2p_advertiser->buy_orders_count,
            cancel_time_avg            => $_->p2p_advertiser->cancel_time_avg,
            release_time_avg           => $_->p2p_advertiser->release_time_avg,
            sell_completion_rate       => $_->p2p_advertiser->sell_completion_rate,
            sell_orders_count          => $_->p2p_advertiser->sell_orders_count,
            total_orders_count         => $_->p2p_advertiser->total_orders_count,
            total_completion_rate      => $_->p2p_advertiser->total_completion_rate,
            basic_verification         => $_->p2p_advertiser->basic_verification,
            full_verification          => $_->p2p_advertiser->full_verification,
            },
    };
};

1;
