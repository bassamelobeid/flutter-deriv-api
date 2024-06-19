use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::Exception;
use Test::MockModule;
use Guard;
use P2P;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::P2P;
use BOM::Test::Helper::P2PWithClient;
use BOM::Test::Helper::Client;
use BOM::Config::Runtime;
use BOM::Rules::Engine;

my $rule_engine = BOM::Rules::Engine->new();
my $app_config  = BOM::Config::Runtime->instance->app_config;

BOM::Test::Helper::P2PWithClient::bypass_sendbird();
BOM::Test::Helper::P2PWithClient::create_escrow();
BOM::Test::Helper::Client::create_doughflow_methods('CR');

subtest 'sell ads reversible balance' => sub {

    my $advertiser = BOM::Test::Helper::P2PWithClient::create_advertiser;
    my $client     = BOM::Test::Helper::P2PWithClient::create_advertiser;

    my (undef, $advert) = BOM::Test::Helper::P2P::create_advert(
        client           => P2P->new(client => $advertiser),
        type             => 'sell',
        min_order_amount => 20
    );
    is($client->p2p_advert_list(type => 'sell')->@*, 0, 'ad is hidden');

    $advertiser->payment_doughflow(
        currency          => $advertiser->currency,
        remark            => 'x',
        amount            => 100,
        payment_processor => 'reversible',
    );

    $app_config->payments->reversible_balance_limits->p2p(25);
    cmp_ok($advertiser->p2p_advertiser_info->{balance_available}, '==', 25, 'balance with partial reversible limit');
    is($client->p2p_advert_list(type => 'sell')->@*, 1, 'ad is shown');

    my $err = exception { $client->p2p_order_create(advert_id => $advert->{id}, amount => 25.01, rule_engine => $rule_engine) };
    is($err->{error_code}, 'OrderCreateFailAmountAdvertiser', 'Got OrderCreateFailAmountAdvertiser if order exceeds reversible balance');

    $app_config->payments->reversible_balance_limits->p2p(50);
    cmp_ok($advertiser->p2p_advertiser_info->{balance_available}, '==', 50, 'balance with new reversible limit');
    is($client->p2p_advert_list(type => 'sell')->@*, 1, 'ad is still shown');

    my $order;
    lives_ok { $order = $client->p2p_order_create(advert_id => $advert->{id}, amount => 25.01, rule_engine => $rule_engine) }
    'can create order after advertiser limit raised';

    cmp_ok($advertiser->p2p_balance, '==', 24.99, 'advertiser balance is reduced');

    $client->p2p_order_cancel(id => $order->{id});
    cmp_ok($advertiser->p2p_advertiser_info->{balance_available}, '==', 50, 'advertiser got balance back');

    $advertiser->payment_doughflow(
        currency          => $advertiser->currency,
        remark            => 'x',
        amount            => 100,
        payment_processor => 'nonreversible',
    );
    cmp_ok($advertiser->p2p_advertiser_info->{balance_available}, '==', 150, 'non reversible deposit completely included');

    $advertiser->db->dbic->dbh->do('SELECT p2p.set_advertiser_totals(?,NULL,NULL,NULL,?)', undef, $advertiser->_p2p_advertiser_cached->{id}, 10);
    delete $advertiser->{_p2p_advertiser_cached};
    cmp_ok $advertiser->p2p_balance, '==', 160, 'extra_sell_amount increases p2p_balance';

    $advertiser->db->dbic->dbh->do('SELECT p2p.set_advertiser_totals(?,NULL,NULL,NULL,?)', undef, $advertiser->_p2p_advertiser_cached->{id}, 1000);
    delete $advertiser->{_p2p_advertiser_cached};
    cmp_ok $advertiser->p2p_balance, '==', $advertiser->account->balance, 'extra_sell_amount increases p2p_balance no higher than account balance';
};

subtest 'buy ads reversible methods' => sub {

    my $advertiser = BOM::Test::Helper::P2PWithClient::create_advertiser;
    my $client     = BOM::Test::Helper::P2PWithClient::create_advertiser;

    my (undef, $advert) = BOM::Test::Helper::P2P::create_advert(
        client           => P2P->new(client => $advertiser),
        type             => 'buy',
        min_order_amount => 20
    );
    is($client->p2p_advert_list(type => 'buy')->@*, 1, 'buy ad is shown');
    is(
        $client->p2p_advert_list(
            type              => 'buy',
            use_client_limits => 1
        )->@*,
        0,
        'buy ad is not shown with use_client_limits=1'
    );

    my $err = exception { $client->p2p_order_create(advert_id => $advert->{id}, amount => 25, rule_engine => $rule_engine) };
    is($err->{error_code}, 'OrderCreateFailClientBalance', 'cannot create order with 0 balance');

    $app_config->payments->reversible_balance_limits->p2p(20);
    $client->payment_doughflow(
        currency          => $client->currency,
        remark            => 'x',
        amount            => 100,
        payment_processor => 'reversible',
    );

    cmp_ok($client->p2p_advertiser_info->{balance_available}, '==', 20, 'client balance');
    is(
        $client->p2p_advert_list(
            type              => 'buy',
            use_client_limits => 1
        )->@*,
        1,
        'buy ad is shown with use_client_limits=1'
    );

    $err = exception { $client->p2p_order_create(advert_id => $advert->{id}, amount => 20.01, rule_engine => $rule_engine) };
    is($err->{error_code}, 'OrderCreateFailClientBalance', 'order amount exceeds available balance');

    lives_ok {
        $client->p2p_order_create(
            advert_id    => $advert->{id},
            amount       => 20,
            rule_engine  => $rule_engine,
            contact_info => 'x',
            payment_info => 'x'
        )
    }
    'order amount equals balance';
};

subtest 'sell ads fiat deposits restricted' => sub {

    $app_config->payments->p2p->fiat_deposit_restricted_countries(['za']);
    $app_config->payments->p2p->fiat_deposit_restricted_lookback(180);

    my $advertiser = BOM::Test::Helper::P2PWithClient::create_advertiser(client_details => {residence => 'ng'});
    my $client     = BOM::Test::Helper::P2PWithClient::create_advertiser(client_details => {residence => 'za'});

    my $client_usdc = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $advertiser->email,
    });

    $client_usdc->account('USDC');
    BOM::Test::Helper::Client::top_up($client_usdc, 'USDC', 100);
    $advertiser->user->add_client($client_usdc);

    my (undef, $advert) = BOM::Test::Helper::P2P::create_advert(
        client           => P2P->new(client => $advertiser),
        type             => 'sell',
        min_order_amount => 20
    );
    is(
        $client->p2p_advert_list(
            local_currency => $advertiser->local_currency,
            type           => 'sell'
        )->@*,
        0,
        'ad is hidden'
    );

    $advertiser->payment_doughflow(
        currency          => $advertiser->currency,
        remark            => 'x',
        amount            => 100,
        payment_processor => 'nonreversible',
    );

    is(
        $client->p2p_advert_list(
            local_currency => $advertiser->local_currency,
            type           => 'sell'
        )->@*,
        1,
        'ad visible after non reversible deposit'
    );

    $app_config->payments->p2p->fiat_deposit_restricted_countries(['ng']);

    is(
        $client->p2p_advert_list(
            local_currency => $advertiser->local_currency,
            type           => 'sell'
        )->@*,
        0,
        'ad hidden after country restricted'
    );

    my $err = exception { BOM::Test::Helper::P2PWithClient::create_order(advert_id => $advert->{id}, amount => 20) };
    is $err->{error_code}, 'AdvertNotFound', 'Cannot place order';

    $client_usdc->payment_account_transfer(
        toClient  => $advertiser,
        currency  => 'USDC',
        amount    => 20,
        fees      => 0,
        to_amount => 20,
        remark    => 'x',
    );

    is(
        $client->p2p_advert_list(
            local_currency => $advertiser->local_currency,
            type           => 'sell'
        )->@*,
        1,
        'ad visible after crypto transfer'
    );

    $err = exception { BOM::Test::Helper::P2PWithClient::create_order(advert_id => $advert->{id}, amount => 20.01) };
    is $err->{error_code}, 'OrderCreateFailAmountAdvertiser', 'Cannot place order that exceeds non-cashier balance';

    lives_ok { BOM::Test::Helper::P2PWithClient::create_order(advert_id => $advert->{id}, amount => 20.00) } 'can create order with correct amount';
    is(
        $client->p2p_advert_list(
            local_currency => $advertiser->local_currency,
            type           => 'sell'
        )->@*,
        0,
        'ad hidden now'
    );

    $app_config->payments->p2p->fiat_deposit_restricted_countries(['za']);
    is(
        $client->p2p_advert_list(
            local_currency => $advertiser->local_currency,
            type           => 'sell'
        )->@*,
        1,
        'ad visible after country unrestricted'
    );
};

subtest 'buy ads fiat deposits restricted' => sub {

    $app_config->payments->p2p->fiat_deposit_restricted_countries(['ke']);

    my $advertiser = BOM::Test::Helper::P2PWithClient::create_advertiser(client_details => {residence => 'ke'});
    my $client     = BOM::Test::Helper::P2PWithClient::create_advertiser(client_details => {residence => 'lk'});

    my $client_usdc = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $client->email,
    });

    $client_usdc->account('USDC');
    BOM::Test::Helper::Client::top_up($client_usdc, 'USDC', 100);
    $advertiser->user->add_client($client_usdc);

    my (undef, $advert) = BOM::Test::Helper::P2P::create_advert(
        client           => P2P->new(client => $advertiser),
        type             => 'buy',
        min_order_amount => 20
    );
    is(
        $client->p2p_advert_list(
            local_currency    => $advertiser->local_currency,
            type              => 'buy',
            use_client_limits => 1
        )->@*,
        0,
        'ad is hidden'
    );

    $client->payment_doughflow(
        currency          => $client->currency,
        remark            => 'x',
        amount            => 100,
        payment_processor => 'nonreversible',
    );

    is(
        $client->p2p_advert_list(
            local_currency    => $advertiser->local_currency,
            type              => 'buy',
            use_client_limits => 1
        )->@*,
        1,
        'ad visible after non reversible deposit'
    );

    $app_config->payments->p2p->fiat_deposit_restricted_countries(['lk']);

    is(
        $client->p2p_advert_list(
            local_currency    => $advertiser->local_currency,
            type              => 'buy',
            use_client_limits => 1
        )->@*,
        0,
        'ad hidden after country restricted'
    );

    my $err = exception {
        $client->p2p_order_create(
            advert_id    => $advert->{id},
            amount       => 20,
            rule_engine  => $rule_engine,
            contact_info => 'x',
            payment_info => 'x'
        )
    };
    is $err->{error_code}, 'OrderCreateFailClientBalance', 'Cannot place order with nonreversible deposits';

    $client_usdc->payment_account_transfer(
        toClient  => $client,
        currency  => 'USDC',
        amount    => 20,
        fees      => 0,
        to_amount => 20,
        remark    => 'x',
    );

    is(
        $client->p2p_advert_list(
            local_currency    => $advertiser->local_currency,
            type              => 'buy',
            use_client_limits => 1
        )->@*,
        1,
        'ad visible after crypto transfer'
    );

    $err = exception {
        $client->p2p_order_create(
            advert_id    => $advert->{id},
            amount       => 20.01,
            rule_engine  => $rule_engine,
            contact_info => 'x',
            payment_info => 'x'
        )
    };
    is $err->{error_code}, 'OrderCreateFailClientBalance', 'Cannot place order that exceeds non-cashier balance';

    lives_ok {
        $client->p2p_order_create(
            advert_id    => $advert->{id},
            amount       => 20.00,
            rule_engine  => $rule_engine,
            contact_info => 'x',
            payment_info => 'x'
        )
    }
    'can create order with correct amount';

    is(
        $client->p2p_advert_list(
            local_currency    => $advertiser->local_currency,
            type              => 'buy',
            use_client_limits => 1
        )->@*,
        0,
        'ad hidden now'
    );

    $app_config->payments->p2p->fiat_deposit_restricted_countries(['ke']);
    is(
        $client->p2p_advert_list(
            local_currency    => $advertiser->local_currency,
            type              => 'buy',
            use_client_limits => 1
        )->@*,
        1,
        'ad visible after country unrestricted'
    );
};

done_testing;
