use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::Exception;
use Test::MockModule;
use Guard;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::P2P;
use BOM::Config::Runtime;

BOM::Test::Helper::P2P::bypass_sendbird();
BOM::Test::Helper::P2P::create_escrow();

my $original_limit = BOM::Config::Runtime->instance->app_config->payments->reversible_balance_limits->p2p;
my $original_tover = BOM::Config::Runtime->instance->app_config->payments->p2p->credit_card_turnover_requirement;

scope_guard {
    BOM::Config::Runtime->instance->app_config->payments->reversible_balance_limits->p2p($original_limit);
    BOM::Config::Runtime->instance->app_config->payments->p2p->credit_card_turnover_requirement($original_tover);
};

BOM::Config::Runtime->instance->app_config->payments->p2p->credit_card_turnover_requirement(0);

my ($advertiser, $client, $advert, $order, $processor);

subtest 'sell ads' => sub {

    $advertiser = BOM::Test::Helper::P2P::create_advertiser;
    $client     = BOM::Test::Helper::P2P::create_advertiser;

    # write user doesn't have permission to write to this table, so we have to use what's there
    ($processor) = $advertiser->db->dbic->dbh->selectrow_array(
        "SELECT payment_processor FROM payment.doughflow_method WHERE payment_method = '' AND reversible = TRUE LIMIT 1");

    (undef, $advert) = BOM::Test::Helper::P2P::create_advert(
        client           => $advertiser,
        type             => 'sell',
        min_order_amount => 20
    );
    is($client->p2p_advert_list(type => 'sell')->@*, 0, 'ad is hidden');

    $advertiser->payment_doughflow(
        currency          => $advertiser->currency,
        remark            => 'x',
        amount            => 100,
        payment_processor => $processor,
        trace_id          => 1
    );

    BOM::Config::Runtime->instance->app_config->payments->reversible_balance_limits->p2p(25);
    cmp_ok($advertiser->p2p_advertiser_info->{balance_available}, '==', 25, 'global limit');
    is($client->p2p_advert_list(type => 'sell')->@*, 1, 'ad is shown');

    BOM::Config::Runtime->instance->app_config->payments->reversible_balance_limits->p2p(50);
    cmp_ok($advertiser->p2p_advertiser_info->{balance_available}, '==', 50, 'new global limit');
    is($client->p2p_advert_list(type => 'sell')->@*, 1, 'ad is shown');

    BOM::Config::Runtime->instance->app_config->payments->p2p->credit_card_turnover_requirement(1);
    cmp_ok($advertiser->p2p_advertiser_info->{balance_available}, '==', 0, 'zero balance when sell blocked');
    BOM::Config::Runtime->instance->app_config->payments->p2p->credit_card_turnover_requirement(0);

    $client->db->dbic->dbh->do('SELECT betonmarkets.manage_client_limit_by_cashier(?,?,?)', undef, $advertiser->loginid, 'p2p', 0.1);
    cmp_ok($advertiser->p2p_advertiser_info->{balance_available}, '==', 10, 'client specific limit');
    is($client->p2p_advert_list(type => 'sell')->@*, 0, 'ad is hidden');

    $client->db->dbic->dbh->do('SELECT betonmarkets.manage_client_limit_by_cashier(?,?,?)', undef, $advertiser->loginid, 'p2p', 0.2);
    cmp_ok($advertiser->p2p_advertiser_info->{balance_available}, '==', 20, 'new client specific limit');
    is($client->p2p_advert_list(type => 'sell')->@*, 1, 'ad is shown');

    my $err = exception { $client->p2p_order_create(advert_id => $advert->{id}, amount => 25) };
    is($err->{error_code}, 'OrderCreateFailAdvertiser', 'cannot create order exceeding advertisers irreversible balance');

    $client->db->dbic->dbh->do('SELECT betonmarkets.manage_client_limit_by_cashier(?,?,?)', undef, $advertiser->loginid, 'p2p', 0.25);
    lives_ok { $order = $client->p2p_order_create(advert_id => $advert->{id}, amount => 25) } 'can create order after advertiser limit raised';

    cmp_ok($advertiser->balance_for_cashier('p2p'), '==', 0, 'advertiser balance is zero');

    $client->p2p_order_cancel(id => $order->{id});
    cmp_ok($advertiser->p2p_advertiser_info->{balance_available}, '==', 25, 'advertiser got balance back');

    $advertiser->payment_doughflow(
        currency          => $advertiser->currency,
        remark            => 'x',
        amount            => 100,
        payment_processor => 'goldbars',
        trace_id          => 1
    );
    cmp_ok($advertiser->p2p_advertiser_info->{balance_available}, '==', 125, 'non reversible deposit completely included');
};

subtest 'buy ads' => sub {

    $advertiser = BOM::Test::Helper::P2P::create_advertiser;
    $client     = BOM::Test::Helper::P2P::create_advertiser;

    (undef, $advert) = BOM::Test::Helper::P2P::create_advert(
        client           => $advertiser,
        type             => 'buy',
        min_order_amount => 20
    );
    is($client->p2p_advert_list(type => 'buy')->@*, 1, 'buy ad is shown');

    my $err = exception { $client->p2p_order_create(advert_id => $advert->{id}, amount => 25) };
    is($err->{error_code}, 'OrderCreateFailClientBalance', 'cannot create order with 0 balance');

    BOM::Config::Runtime->instance->app_config->payments->reversible_balance_limits->p2p(20);
    $client->payment_doughflow(
        currency          => $client->currency,
        remark            => 'x',
        amount            => 100,
        payment_processor => $processor,
        trace_id          => 1
    );
    cmp_ok($client->p2p_advertiser_info->{balance_available}, '==', 20, 'client balance');

    my %params = (
        advert_id    => $advert->{id},
        contact_info => 'x',
        payment_info => 'x'
    );
    $err = exception { $client->p2p_order_create(amount => 25, %params) };
    is($err->{error_code}, 'OrderCreateFailClientBalance', 'order amount exceeds balance');

    lives_ok { $client->p2p_order_create(amount => 20, %params) } 'order amount equals balance';
};

done_testing;
