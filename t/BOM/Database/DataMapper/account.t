#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::Warnings;
use Test::More tests => 4;    # match to number of subs in Account DataMapper
use Test::Exception;

use BOM::Database::DataMapper::Account;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $conn_builder;
my $acc;
my $client;
my $acc_dm;

lives_ok {
    $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $client->set_default_account('USD');
}
'Create a client';

subtest 'get balance' => sub {
    lives_ok {
        $acc_dm = BOM::Database::DataMapper::Account->new({
            'client_loginid' => 'CR0111',
            'currency_code'  => 'USD'
        });
    }
    'Initializing account data mapper for CR0111 USD';

    my $balance = $acc_dm->get_balance();

    is($balance + 0, 100, 'balance is as expected');
};

subtest 'get total trades income' => sub {
    lives_ok {
        $acc_dm = BOM::Database::DataMapper::Account->new({
            'client_loginid' => 'CR0111',
            'currency_code'  => 'USD'
        });
    }
    'Initializing account data mapper for CR0111 USD';

    my $total_income = $acc_dm->get_total_trades_income();

    is $total_income+ 0, -10, 'total income is as expected';
};
