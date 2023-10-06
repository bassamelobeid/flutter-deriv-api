use strict;
use warnings;

use Test::More;
use Test::Fatal qw(exception lives_ok);
use Test::Deep;
use JSON::MaybeUTF8 qw(:v1);

use BOM::Test::Helper::P2P;
use BOM::Test::Helper::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Rules::Engine;

BOM::Test::Helper::P2P::bypass_sendbird();
BOM::Test::Helper::P2P::create_escrow();
BOM::Test::Helper::Client::create_doughflow_methods('CR');

my $config      = BOM::Config::Runtime->instance->app_config->payments;
my $rule_engine = BOM::Rules::Engine->new();

$config->reversible_balance_limits->p2p(0);

subtest 'positive p2p and reversible, balance more than p2p+reversible' => sub {

    # net P2P = +50
    # net reversible = +100
    # Balance = 250

    my $advertiser = BOM::Test::Helper::P2P::create_advertiser(client_details => {residence => 'id'});
    my $client     = BOM::Test::Helper::P2P::create_advertiser(
        balance        => 50,
        client_details => {residence => 'th'});

    my (undef, $ad) = BOM::Test::Helper::P2P::create_advert(
        client           => $advertiser,
        type             => 'buy',
        max_order_amount => 50,
        amount           => 50,
    );

    my (undef, $order) = BOM::Test::Helper::P2P::create_order(
        client    => $client,
        advert_id => $ad->{id},
        amount    => 50
    );
    $advertiser->p2p_order_confirm(id => $order->{id});
    $client->p2p_order_confirm(id => $order->{id});

    $config->p2p_withdrawal_limit(100);
    cmp_ok $advertiser->p2p_withdrawable_balance, '==', 50, 'full balance available with 100% limit';
    check_total($advertiser);

    $config->p2p_withdrawal_limit(20);
    cmp_ok $advertiser->p2p_withdrawable_balance, '==', 10, 'partial balance available with 20% limit';
    check_total($advertiser);

    $config->p2p_withdrawal_limit(0);
    cmp_ok $advertiser->p2p_withdrawable_balance, '==', 0, 'zero available with 0% limit';
    check_total($advertiser);

    $config->p2p->restricted_countries(['id']);
    cmp_ok $advertiser->p2p_withdrawable_balance, '==', $advertiser->account->balance, 'full balance availble when country is banned';
    $config->p2p->restricted_countries(['th']);
    cmp_ok $advertiser->p2p_withdrawable_balance, '==', 0, 'zero available when other country banned';
    $config->p2p->restricted_countries([]);

    $advertiser->payment_doughflow(
        currency          => $advertiser->currency,
        remark            => 'x',
        amount            => 100,
        payment_processor => 'reversible',
    );

    cmp_ok $advertiser->p2p_withdrawable_balance, '==', 100, 'net p2p is witheld with reversible deposits';
    check_total($advertiser);

    $advertiser->payment_doughflow(
        currency          => $advertiser->currency,
        remark            => 'x',
        amount            => 100,
        payment_processor => 'nonreversible',
    );

    cmp_ok $advertiser->p2p_withdrawable_balance, '==', 200, 'net p2p is witheld with irreversible deposits';
    check_total($advertiser);

    (undef, $ad) = BOM::Test::Helper::P2P::create_advert(
        client           => $advertiser,
        type             => 'sell',
        max_order_amount => 100,
        amount           => 100,
    );

    (undef, $order) = BOM::Test::Helper::P2P::create_order(
        client    => $client,
        advert_id => $ad->{id},
        amount    => 100
    );
    check_total($advertiser);
    $client->p2p_order_confirm(id => $order->{id});
    $advertiser->p2p_order_confirm(id => $order->{id});

    cmp_ok $advertiser->p2p_withdrawable_balance, '==', 150, 'net p2p negative, full balance available';
    check_total($advertiser);
};

subtest 'transfers' => sub {

    #net P2P = +50
    #net reversible = +1000
    #net transfers = -500

    $config->p2p_withdrawal_limit(0);

    my $advertiser = BOM::Test::Helper::P2P::create_advertiser();

    my $client_usdc = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $advertiser->email,
    });

    $client_usdc->account('USDC');
    $advertiser->user->add_client($client_usdc);

    my (undef, $ad) = BOM::Test::Helper::P2P::create_advert(
        client           => $advertiser,
        type             => 'buy',
        max_order_amount => 50,
        amount           => 50,
    );

    my ($client, $order) = BOM::Test::Helper::P2P::create_order(
        advert_id => $ad->{id},
        amount    => 50
    );
    check_total($advertiser);
    $advertiser->p2p_order_confirm(id => $order->{id});
    $client->p2p_order_confirm(id => $order->{id});
    check_total($advertiser);

    $advertiser->payment_doughflow(
        currency          => $advertiser->currency,
        remark            => 'x',
        amount            => 1000,
        payment_processor => 'reversible',
    );
    check_total($advertiser);

    $advertiser->payment_account_transfer(
        toClient  => $client_usdc,
        currency  => 'USD',
        amount    => 500,
        fees      => 0,
        to_amount => 500,
        remark    => 'x',
    );

    # account balance = 550, it's all reversible so full amount should be available to withdraw
    cmp_ok $advertiser->p2p_withdrawable_balance, '==', 550, 'full balance is reversible so can be withdrawn';
    cmp_ok $advertiser->p2p_balance,              '==', 0,   'p2p balance is zero';
    check_total($advertiser);

    $advertiser->db->dbic->dbh->do('SELECT p2p.set_advertiser_totals(?,NULL,NULL,NULL,?)', undef, $advertiser->_p2p_advertiser_cached->{id}, 10);
    delete $advertiser->{_p2p_advertiser_cached};

    cmp_ok $advertiser->p2p_balance, '==', 10, 'extra sell amount can be added';

    $advertiser->payment_doughflow(
        currency          => $advertiser->currency,
        remark            => 'x',
        amount            => 500,
        payment_processor => 'nonreversible',
    );

    cmp_ok $advertiser->p2p_withdrawable_balance, '==', 1000, 'net p2p can be sold in p2p now so is excluded from cashier';
    cmp_ok $advertiser->p2p_balance,              '==', 60,   'p2p balance only has reversible + extra sell amount';
    check_total($advertiser);
};

subtest 'mix of deposits' => sub {
    # net p2p: 50
    # reversible: 100
    # non reversible: 500

    my $advertiser = BOM::Test::Helper::P2P::create_advertiser();

    my (undef, $ad) = BOM::Test::Helper::P2P::create_advert(
        client           => $advertiser,
        type             => 'buy',
        max_order_amount => 50,
        amount           => 50,
    );

    my ($client, $order) = BOM::Test::Helper::P2P::create_order(
        advert_id => $ad->{id},
        amount    => 50
    );
    check_total($advertiser);
    $advertiser->p2p_order_confirm(id => $order->{id});
    $client->p2p_order_confirm(id => $order->{id});
    check_total($advertiser);

    $advertiser->payment_doughflow(
        currency          => $advertiser->currency,
        remark            => 'x',
        amount            => 100,
        payment_processor => 'reversible',
    );
    check_total($advertiser);

    $advertiser->payment_doughflow(
        currency          => $advertiser->currency,
        remark            => 'x',
        amount            => 500,
        payment_processor => 'nonreversible',
    );

    cmp_ok $advertiser->p2p_withdrawable_balance, '==', 600, 'net p2p excluded from cashier';
    cmp_ok $advertiser->p2p_balance,              '==', 550, 'p2p balance is non reversible';
    check_total($advertiser);
};

subtest 'negative reversible' => sub {
    # net p2p: 100
    # reversible: -50
    # non-reversible: 100

    my $advertiser = BOM::Test::Helper::P2P::create_advertiser();

    my (undef, $ad) = BOM::Test::Helper::P2P::create_advert(
        client           => $advertiser,
        type             => 'buy',
        max_order_amount => 100,
        amount           => 100,
    );

    my ($client, $order) = BOM::Test::Helper::P2P::create_order(
        advert_id => $ad->{id},
        amount    => 100
    );
    check_total($advertiser);
    $advertiser->p2p_order_confirm(id => $order->{id});
    $client->p2p_order_confirm(id => $order->{id});
    check_total($advertiser);

    $advertiser->payment_doughflow(
        currency          => $advertiser->currency,
        remark            => 'x',
        amount            => 100,
        payment_processor => 'nonreversible',
    );
    check_total($advertiser);

    $advertiser->payment_doughflow(
        currency          => $advertiser->currency,
        remark            => 'x',
        amount            => -50,
        payment_processor => 'reversible',
    );

    cmp_ok $advertiser->p2p_withdrawable_balance, '==', 50,  'net p2p excluded from cashier';
    cmp_ok $advertiser->p2p_balance,              '==', 150, 'p2p balance is correct';
    check_total($advertiser);
};

subtest 'fiat deposit exclusion' => sub {
    $config->p2p->fiat_deposit_restricted_countries(['ng']);
    my $advertiser = BOM::Test::Helper::P2P::create_advertiser(client_details => {residence => 'ng'});

    my (undef, $ad) = BOM::Test::Helper::P2P::create_advert(
        client           => $advertiser,
        type             => 'buy',
        max_order_amount => 50,
        amount           => 50,
    );

    my ($client, $order) = BOM::Test::Helper::P2P::create_order(
        advert_id => $ad->{id},
        amount    => 50
    );
    $advertiser->p2p_order_confirm(id => $order->{id});
    $client->p2p_order_confirm(id => $order->{id});

    $advertiser->payment_doughflow(
        currency          => $advertiser->currency,
        remark            => 'x',
        amount            => 500,
        payment_processor => 'nonreversible',
    );

    cmp_ok $advertiser->p2p_withdrawable_balance, '==', 500, 'net p2p excluded from cashier';
    cmp_ok $advertiser->p2p_balance,              '==', 50,  'p2p balance is only net p2p';
    check_total($advertiser);
};

sub check_total {
    my $client = shift;
    cmp_ok $client->p2p_balance + $client->p2p_withdrawable_balance, '>=', $client->account->balance,
        'total of P2P and withdrawable balance is not less than total balance';
}

done_testing();
