package BOM::Test::WebsocketAPI::Template::Authorize;

use strict;
use warnings;
no indirect;

use BOM::Test::WebsocketAPI::Template::DSL;

rpc_request {
    return {
        args => {
            authorize => $_->client->token,
            req_id    => 1
        },
        source                     => '1',
        logging                    => {},
        country_code               => 'aq',
        user_agent                 => undef,
        source_bypass_verification => undef,
        language                   => 'EN',
        brand                      => 'binary',
        client_ip                  => '',
        valid_source               => undef,
        ua_fingerprint             => 'c4ca4238a0b923820dcc509a6f75849b'
    };
}
qw(client);

rpc_response sub {
    my $client = $_->client;
    return {
        stash => {
            landing_company_name       => $client->landing_company_name,
            currency                   => $client->currency,
            valid_source               => '1',
            loginid                    => $client->loginid,
            source_bypass_verification => 0,
            token_type                 => 'oauth_token',
            token                      => $client->token,
            app_markup_percentage      => '0',
            is_virtual                 => 0,
            email                      => $client->email,
            scopes                     => ['read', 'admin', 'trade', 'payments'],
            country                    => $client->country,
            account_id                 => $client->account_id
        },
        country      => $client->country,
        balance      => $client->balance,
        email        => $client->email,
        scopes       => ['read', 'admin', 'trade', 'payments'],
        is_virtual   => 0,
        account_list => [{
                loginid              => $client->loginid,
                currency             => $client->currency,
                is_virtual           => 0,
                is_disabled          => 0,
                landing_company_name => $client->landing_company_name
            }
        ],
        currency                      => $client->currency,
        loginid                       => $client->loginid,
        fullname                      => 'MR bRaD pItT',
        landing_company_fullname      => $client->landing_company_fullname,
        upgradeable_landing_companies => [$client->landing_company_name],
        landing_company_name          => $client->landing_company_name
    };
};

1;
