package BOM::Test::WebsocketAPI::Template::P2PAdvertiserCreate;

use strict;
use warnings;
no indirect;

use BOM::Test::WebsocketAPI::Template::DSL;

request p2p_advertiser_create => sub {
    return p2p_advertiser_create => {
        name => $_->p2p_advertiser->name,
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
            p2p_advertiser_create => 1,
            subscribe             => 1,
            name                  => $_->p2p_advertiser->name,
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
            },
    };
};

1;
