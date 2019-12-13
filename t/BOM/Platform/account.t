use strict;
use warnings;
use Test::More (tests => 4);
use Test::Exception;
use Test::Warnings;

use BOM::User::Client;

use BOM::Database::DataMapper::Account;
use BOM::Database::Model::Transaction;
use BOM::Database::Model::Constants;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my ($acc_data_mapper, $balance);

subtest "Try MX, GBP" => sub {
    lives_ok {
        # Setup fixtures
        my $client = BOM::User::Client->new({loginid => 'MX0012'});
        my $account = $client->default_account;

        $client->payment_free_gift(
            currency => 'GBP',
            amount   => 4191.05,
            remark   => 'here is money',
        );

        # XXX Client MX0012 has got affiliate reward of 5.04

        cmp_ok(
            BOM::Database::DataMapper::Account->new({
                    'client_loginid' => $account->client_loginid,
                    'currency_code'  => 'GBP'
                }
                )->get_balance,
            '==',
            (4191.05 + 5.04),
            'Check balance for account on MX, GBP'
        );
    }
    'Expect to initialize the account data mapper for MX,GBP';
};

subtest "get_balance" => sub {
    lives_ok {
        $acc_data_mapper = BOM::Database::DataMapper::Account->new({
            'client_loginid' => 'CR0016',
            'currency_code'  => 'USD'
        });
    }
    'Expect to initialize the account data mapper';

    $balance = $acc_data_mapper->get_balance();
    cmp_ok($balance, '==', 274.34, 'Check balance for account CR0016, USD');
};

subtest "making new transaction" => sub {
    lives_ok {

        my $client = BOM::User::Client->new({loginid => 'CR0008'});
        $client->payment_legacy_payment(
            currency     => 'USD',
            amount       => 3,
            remark       => 'test',
            payment_type => 'adjustment',
        );

    }
    'use the payment handler to handle the payment';
};

