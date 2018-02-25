#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More qw(no_plan);
use Test::Exception;
use Test::Output qw(:functions);
use Test::Warn;

use BOM::Database::DataMapper::Payment;
use BOM::Database::DataMapper::Account;

use FindBin;
use lib "$FindBin::Bin/../../../lib";
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

use ClientAccountTestHelper;

use lib qw(/home/git/regentmarkets/bom/cgi);

subtest 'client Balance' => sub {
    plan tests => 14;
    my $client = ClientAccountTestHelper::create_client({
        broker_code => 'CR',
    });
    my $account = $client->set_default_account('GBP');

    $client->payment_free_gift(
        currency => 'GBP',
        amount   => 1234.25,
        remark   => 'here is money',
    );
    $client->payment_free_gift(
        currency => 'GBP',
        amount   => 1234.25,
        remark   => 'here is money',
    );
    $client->payment_free_gift(
        currency => 'GBP',
        amount   => -357.30,
        remark   => 'here is money',
    );
    $client->payment_free_gift(
        currency => 'GBP',
        amount   => -1111.19,
        remark   => 'here is money',
    );
    #ClientAccountTestHelper::create_fmb({
    #    type       => 'fmb_higher_lower_sold_won',
    #    account_id => $account->id,
    #    sell_price => 565.23,
    #    buy_price  => 165.12
    #});

    my ($account_mapper, $payment_mapper, $payment_mapper_client, $aggregate_deposit, $aggregate_withdrawal, $aggregate_deposit_withdrawal,
        $withdrawal_ref);
    lives_ok {
        $account_mapper = BOM::Database::DataMapper::Account->new({
            client_loginid => $account->client_loginid,
            currency_code  => 'GBP',
        });
        $payment_mapper = BOM::Database::DataMapper::Payment->new({
            client_loginid => $account->client_loginid,
            currency_code  => 'GBP',
        });
        $payment_mapper_client = BOM::Database::DataMapper::Payment->new({
            client_loginid => $account->client_loginid,
        });
    }
    'Successfully get Balance related figure for client, GBP';

    $aggregate_deposit    = $payment_mapper->get_total_deposit();
    $aggregate_withdrawal = $payment_mapper->get_total_withdrawal();

    $aggregate_deposit_withdrawal = $aggregate_deposit - $aggregate_withdrawal;

    is($account_mapper->get_balance(), 1000.01,   'check account balance');
    is($aggregate_deposit,             '2468.50', 'check aggregate deposit');
    is($aggregate_withdrawal,          1468.49,   'check aggregate withdrawal');
    is($aggregate_deposit_withdrawal,  1000.01,   'check aggredate deposit & withdrawal');

    lives_ok {
        $account_mapper = BOM::Database::DataMapper::Account->new({
            client_loginid => 'MX0013',
            currency_code  => 'USD',
        });
        $payment_mapper = BOM::Database::DataMapper::Payment->new({
            client_loginid => 'MX0013',
            currency_code  => 'USD',
        });
        $payment_mapper_client = BOM::Database::DataMapper::Payment->new({
            client_loginid => 'MX0013',
        });
    }
    'Successfully get Balance related figure for MX0013, USD';

    $aggregate_deposit    = $payment_mapper->get_total_deposit();
    $aggregate_withdrawal = $payment_mapper->get_total_withdrawal();

    $aggregate_deposit_withdrawal = $aggregate_deposit - $aggregate_withdrawal;

    cmp_ok($account_mapper->get_balance(), '==', 4.96, 'check account balance');
    cmp_ok($aggregate_deposit,             '==', 20,   'check aggregate deposit');
    cmp_ok($aggregate_withdrawal,          '==', 0,    'no withdrawal has been made');
    cmp_ok($aggregate_deposit_withdrawal,  '==', 20,   'check aggredate deposit & withdrawal');

    lives_ok {
        $account_mapper = BOM::Database::DataMapper::Account->new({
            client_loginid => 'TEST9999',
            currency_code  => 'USD',
        });
        $payment_mapper = BOM::Database::DataMapper::Payment->new({
            client_loginid => 'TEST9999',
            currency_code  => 'USD',
        });
        $payment_mapper_client = BOM::Database::DataMapper::Payment->new({
            client_loginid => 'TEST9999',
        });
    }
    'Successfully get Balance related figure for TEST9999, USD';

    throws_ok { $aggregate_deposit = $payment_mapper->get_total_deposit(); } qr/No such domain with the broker code TEST/,
        'Get total deposit of unknown broker code failed';
    throws_ok { $aggregate_withdrawal = $payment_mapper->get_total_withdrawal(); } qr/No such domain with the broker code TEST/,
        'Get total withdrawal failed for unknow broker code failed';

    $aggregate_deposit_withdrawal = $aggregate_deposit - $aggregate_withdrawal;

    throws_ok { $account_mapper->get_balance(); } qr/No such domain with the broker code TEST/, 'check account balance for invalid broker code';
};

