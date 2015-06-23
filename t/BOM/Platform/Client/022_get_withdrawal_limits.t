#!/usr/bin/perl
package main;

use strict;
use warnings;

use Test::MockTime;
use Test::More qw( no_plan );
use Test::Exception;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

use BOM::Platform::Client;
use BOM::Product::ContractFactory qw( produce_contract );
use Date::Utility;
use BOM::Product::Transaction;
use BOM::Platform::Promocode;
use BOM::Platform::Client::Utility;

initialize_realtime_ticks_db();

my $now = Date::Utility->new;

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('exchange', {recorded_date => $now});

subtest 'CR0027.' => sub {
    plan tests => 2;

    my $client = BOM::Platform::Client->new({loginid => 'CR0027'});
    my $withdrawal_limits = $client->get_withdrawal_limits();

    is($withdrawal_limits->{'frozen_free_gift'},         0,   'USD frozen_free_gift is 0');
    is($withdrawal_limits->{'free_gift_turnover_limit'}, 250, 'USD free_gift_turnover_limit is 250');
};

subtest 'CR0028.' => sub {
    plan tests => 2;

    my $client = BOM::Platform::Client->new({loginid => 'CR0028'});
    my $withdrawal_limits = $client->get_withdrawal_limits();

    cmp_ok($withdrawal_limits->{'frozen_free_gift'}, '==', 20, 'USD frozen_free_gift is 20');
    is($withdrawal_limits->{'free_gift_turnover_limit'}, 500, 'USD free_gift_turnover_limit is 500');
};

subtest 'CR0029.' => sub {
    plan tests => 8;

    my $client = BOM::Platform::Client->new({loginid => 'CR0029'});
    my $withdrawal_limits = $client->get_withdrawal_limits();

    is($withdrawal_limits->{'frozen_free_gift'},         0, 'USD frozen_free_gift is 100');
    is($withdrawal_limits->{'free_gift_turnover_limit'}, 0, 'USD free_gift_turnover_limit is 2500');

    {
        local $ENV{REQUEST_STARTTIME} = '2009-11-17 00:00:00';
        my $txn = BOM::Product::Transaction->new({
            contract => produce_contract('CALL_FRXUSDJPY_2500_1258502400_1258588800_892700_0', 'USD'),
            client   => $client,
            price    => 1440.26,
            staff    => 'UnitTest',
        });
        $txn->buy(skip_validation => 1);
    }

    $withdrawal_limits = $client->get_withdrawal_limits();

    is($withdrawal_limits->{'frozen_free_gift'},         0, 'USD frozen_free_gift is 100');
    is($withdrawal_limits->{'free_gift_turnover_limit'}, 0, 'USD free_gift_turnover_limit is 2500');

    {
        local $ENV{REQUEST_STARTTIME} = '2009-11-17 00:00:00';
        my $txn = BOM::Product::Transaction->new({
            contract => produce_contract('CALL_FRXUSDJPY_3000_1258502400_1258588800_892100_0', 'USD'),
            client   => $client,
            price    => 1728.5,
            staff    => 'UnitTest',
        });
        $txn->buy(skip_validation => 1);
    }

    $withdrawal_limits = $client->get_withdrawal_limits();

    is($withdrawal_limits->{'frozen_free_gift'},         0, 'USD frozen_free_gift is 0');
    is($withdrawal_limits->{'free_gift_turnover_limit'}, 0, 'USD free_gift_turnover_limit is 2500');

    $client->smart_payment(
        currency     => 'USD',
        amount       => 100,
        remark       => 'affiliate reward',
        payment_type => 'affiliate_reward'
    );

    $withdrawal_limits = $client->get_withdrawal_limits();

    is($withdrawal_limits->{'frozen_free_gift'},         0, 'USD frozen_free_gift is 0');
    is($withdrawal_limits->{'free_gift_turnover_limit'}, 0, 'USD free_gift_turnover_limit is 2500');
};

subtest 'CR0012.' => sub {
    plan tests => 5;

    my $client = BOM::Platform::Client->new({loginid => 'CR0012'});
    $client->promo_code('BOM2009');
    my $account = $client->set_default_account('USD');

    is($client->promo_code, 'BOM2009', 'Client has expected promo code');

    cmp_ok($account->load->balance, '==', 0, 'Balance starts zero.');

    $client->smart_payment(
        currency     => 'USD',
        amount       => 20,
        remark       => 'promo',
        payment_type => 'free_gift'
    );

    BOM::Platform::Promocode::process_promotional_code($client);

    cmp_ok($account->load->balance, '==', 20, 'Balance after being given promo bonus.');
    my $txn_buy;
    {
        local $ENV{REQUEST_STARTTIME} = '2009-11-17 00:00:00';
        $txn_buy = BOM::Product::Transaction->new({
            contract => produce_contract('CALL_FRXUSDJPY_40_1258502400_1258588800_892100_0', 'USD'),
            client   => $client,
            price    => 20,
            staff    => 'UnitTest',
        });
        $txn_buy->buy(skip_validation => 1);
    }

    my $txn = BOM::Product::Transaction->new({
        contract    => produce_contract('CALL_FRXUSDJPY_40_1258502400_1258588800_892100_0', 'USD'),
        client      => $client,
        price       => 40,
        staff       => 'UnitTest',
        contract_id => $txn_buy->contract_id,
    });
    $txn->sell(skip_validation => 1);

    my $balance = $account->load->balance;
    cmp_ok($balance, '==', 40, 'Balance is 40');

    # Now we're at a stage where we have a client who has only deposted by Free Gift,
    # and has $40 in his account (I say his as I think the default client is "Carlos")

    my $withdrawal_limits = $client->get_withdrawal_limits();

    cmp_ok($withdrawal_limits->{frozen_free_gift}, '==', $balance, 'Frozen free gift is full balance.');
};

Test::MockTime::restore_time();
