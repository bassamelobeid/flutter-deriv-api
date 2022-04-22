package BOM::Test::WebsocketAPI::Template::CashierPayments;

use strict;
use warnings;
no indirect;

use BOM::Test::WebsocketAPI::Template::DSL;

request cashier_payments => sub {
    return cashier_payments => {
        cashier_payments => 1,
        provider         => 'crypto',
        transaction_type => 'all',
    };
};

rpc_request {
    return {
        brand                      => 'binary',
        language                   => 'EN',
        source_bypass_verification => 0,
        valid_source               => '1',
        country_code               => 'id',
        source                     => '1',
        logging                    => {},
        token                      => $_->client->token,
        args                       => {
            cashier_payments => 1,
            provider         => 'crypto',
            transaction_type => 'all',
            subscribe        => 1,
        },
    };
}, qw(client);

rpc_response {
    return {
        crypto => [{
                id                 => 12345678,
                address_hash       => 'recipient_blockchain_address',
                address_url        => 'address_url_on_blockchain',
                amount             => 0.005,
                is_valid_to_cancel => 0,
                transaction_hash   => 'transaction_hash',
                transaction_url    => 'transaction_url_on_blockchain',
                transaction_type   => 'deposit',
                status_code        => 'PENDING',
                status_message     => 'Transaction is pending confirmation on Blockchain.',
                submit_date        => 1234567890,
            },
        ],
    };
};

publish cashier_payments => sub {
    my $channel = 'CASHIER::PAYMENTS::' . uc($_->client->loginid);
    return {
        $channel => crypto => [{
                client_loginid     => $_->client->loginid,
                id                 => 12345678,
                address_hash       => 'recipient_blockchain_address',
                address_url        => 'address_url_on_blockchain',
                amount             => 0.005,
                is_valid_to_cancel => 0,
                transaction_hash   => 'transaction_hash',
                transaction_url    => 'transaction_url_on_blockchain',
                transaction_type   => 'deposit',
                status_code        => 'PENDING',
                status_message     => 'Transaction is pending confirmation on Blockchain.',
                submit_date        => 1234567890,
            }
        ],
    };
};

1;
