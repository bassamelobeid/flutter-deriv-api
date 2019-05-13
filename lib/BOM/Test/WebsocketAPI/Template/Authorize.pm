package BOM::Test::WebsocketAPI::Template::Authorize;

use strict;
use warnings;
no indirect;

use BOM::Test::WebsocketAPI::Template::DSL;

rpc_request authorize => sub {
    return {authorize => $_->client->token};
    },
    qw(client);

rpc_response authorize => sub {
    my $client = $_->client;
    return {
        'stash' => {
            'landing_company_name'       => $client->landing_company_name,
            'currency'                   => $client->currency,
            'valid_source'               => '1',
            'loginid'                    => $client->loginid,
            'source_bypass_verification' => 0,
            'token_type'                 => 'oauth_token',
            'token'                      => $client->token,
            'app_markup_percentage'      => '0',
            'is_virtual'                 => 0,
            'email'                      => $client->email,
            'scopes'                     => ['read', 'admin', 'trade', 'payments'],
            'country'                    => $client->country,
            'account_id'                 => $client->account_id
        },
        'country'      => $client->country,
        'balance'      => $client->balance,
        'email'        => $client->email,
        'scopes'       => ['read', 'admin', 'trade', 'payments'],
        'is_virtual'   => 0,
        'account_list' => [{
                'loginid'              => $client->loginid,
                'currency'             => $client->currency,
                'is_virtual'           => 0,
                'is_disabled'          => 0,
                'landing_company_name' => $client->landing_company_name
            }
        ],
        'currency'                      => $client->currency,
        'loginid'                       => $client->loginid,
        'fullname'                      => 'MR bRaD pItT',
        'landing_company_fullname'      => 'Binary (SVG) Ltd.',
        'upgradeable_landing_companies' => [$client->landing_company_name],
        'landing_company_name'          => $client->landing_company_name
    };
};

1;
