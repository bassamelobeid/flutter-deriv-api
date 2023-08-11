use strict;
use warnings;

use Test::Most;
use Test::Fatal;
use Test::Deep;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::P2P;
use BOM::Rules::Engine;
use BOM::Config::Runtime;

BOM::Test::Helper::P2P::bypass_sendbird;
BOM::Test::Helper::P2P::create_escrow;
my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_events->mock('emit' => undef);    # because we don't want to require redis 6 in CI

my $rule_name = 'p2p.no_open_orders';
subtest $rule_name => sub {
    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'p2p1@test.com',
    });

    BOM::User->create(
        email    => $client_cr->email,
        password => 'x',
    )->add_client($client_cr);

    my $rule_engine = BOM::Rules::Engine->new(client => $client_cr);
    my %args        = (loginid => $client_cr->loginid);

    ok $rule_engine->apply_rules($rule_name, %args), 'Rule passes for no account';

    $client_cr->account('USD');
    ok $rule_engine->apply_rules($rule_name, %args), 'Rule passes for non advertiser account';

    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert;

    $rule_engine = BOM::Rules::Engine->new(client => $advertiser);
    %args        = (loginid => $advertiser->loginid);

    ok $rule_engine->apply_rules($rule_name, %args), 'Rule passes for advertiser with no orders';

    my ($client_p2p, $order) = BOM::Test::Helper::P2P::create_order(advert_id => $advert->{id});

    cmp_deeply(
        exception { $rule_engine->apply_rules($rule_name, %args) },
        {
            error_code => 'OpenP2POrders',
            rule       => $rule_name
        },
        'Advertiser fails for open order'
    );

    $rule_engine = BOM::Rules::Engine->new(client => $client_p2p);
    %args        = (loginid => $client_p2p->loginid);

    cmp_deeply(
        exception { $rule_engine->apply_rules($rule_name, %args) },
        {
            error_code => 'OpenP2POrders',
            rule       => $rule_name
        },
        'Counterparty fails for open order'
    );

    BOM::Test::Helper::P2P::set_order_status($advertiser, $order->{id}, 'cancelled');

    ok $rule_engine->apply_rules($rule_name, %args), 'Rule passes for counterparty with cancelled order';

    $rule_engine = BOM::Rules::Engine->new(client => $advertiser);
    %args        = (loginid => $advertiser->loginid);

    ok $rule_engine->apply_rules($rule_name, %args), 'Rule passes for advertiser with cancelled order';
};

$rule_name = 'p2p.withdrawal_check';
subtest $rule_name => sub {

    BOM::Config::Runtime->instance->app_config->payments->p2p_withdrawal_limit(0);

    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'p2p2@test.com',
    });

    BOM::User->create(
        email    => $client_cr->email,
        password => 'x',
    )->add_client($client_cr);

    $client_cr->account('USD');

    my $rule_engine = BOM::Rules::Engine->new(client => $client_cr);
    my %args        = (
        loginid  => $client_cr->loginid,
        currency => 'USD',
        action   => 'withdrawal',
        amount   => -10,
    );

    ok $rule_engine->apply_rules($rule_name, %args), 'Rule passes for no account';

    ok $rule_engine->apply_rules($rule_name, %args), 'Rule passes for non advertiser account';

    my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(type => 'sell');

    my $client_p2p = BOM::Test::Helper::P2P::create_advertiser();
    my (undef, $order) = BOM::Test::Helper::P2P::create_order(
        client    => $client_p2p,
        advert_id => $advert->{id},
        amount    => 10
    );

    $client_p2p->p2p_order_confirm(id => $order->{id});
    $advertiser->p2p_order_confirm(id => $order->{id});

    $rule_engine = BOM::Rules::Engine->new(client => $advertiser);
    $args{loginid} = $advertiser->loginid;
    ok $rule_engine->apply_rules($rule_name, %args), 'Rule passes for advertiser with negative net p2p';

    $rule_engine = BOM::Rules::Engine->new(client => $client_p2p);
    $args{loginid} = $client_p2p->loginid;

    cmp_deeply(
        exception { $rule_engine->apply_rules($rule_name, %args) },
        {
            error_code => 'P2PDepositsWithdrawalZero',
            params     => [num(0), num(10), 'USD'],
            rule       => $rule_name,
        },
        'Rule fails for advertiser with positive net p2p'
    );

    $args{payment_type} = 'internal_transfer';
    cmp_deeply(
        exception { $rule_engine->apply_rules($rule_name, %args) },
        {
            error_code => 'P2PDepositsTransferZero',
            params     => [num(0), num(10), 'USD'],
            rule       => $rule_name,
        },
        'Specific error code for internal_transfer'
    );
    delete $args{payment_type};

    BOM::Test::Helper::Client::top_up($client_p2p, $client_p2p->currency, 10);
    ok $rule_engine->apply_rules($rule_name, %args), 'Rule passes with other deposits';
    $args{amount} = -15;

    cmp_deeply(
        exception { $rule_engine->apply_rules($rule_name, %args) },
        {
            error_code => 'P2PDepositsWithdrawal',
            params     => [num(10), num(10), 'USD'],
            rule       => $rule_name,
        },
        'Rule fails with partial use of P2P amount'
    );

    $args{payment_type} = 'internal_transfer';
    cmp_deeply(
        exception { $rule_engine->apply_rules($rule_name, %args) },
        {
            error_code => 'P2PDepositsTransfer',
            params     => [num(10), num(10), 'USD'],
            rule       => $rule_name,
        },
        'Specific error code for internal_transfer'
    );
    delete $args{payment_type};

    BOM::Config::Runtime->instance->app_config->payments->p2p_withdrawal_limit(50);
    ok $rule_engine->apply_rules($rule_name, %args), 'Rule passes when limit is relaxed';

    BOM::Config::Runtime->instance->app_config->payments->p2p_withdrawal_limit(100);
    $args{amount} = -20;
    ok $rule_engine->apply_rules($rule_name, %args), 'Can withdraw full amount when limit is removed';

    (undef, $order) = BOM::Test::Helper::P2P::create_order(
        client    => $client_p2p,
        advert_id => $advert->{id},
        amount    => 1
    );
    $client_p2p->p2p_order_confirm(id => $order->{id});
    $advertiser->p2p_order_confirm(id => $order->{id});

    BOM::Config::Runtime->instance->app_config->payments->p2p_withdrawal_limit(0);

    cmp_deeply(
        exception { $rule_engine->apply_rules($rule_name, %args) },
        {
            error_code => 'P2PDepositsWithdrawal',
            params     => [num(10), num(11), 'USD'],
            rule       => $rule_name,
        },
        'Additional p2p deposits are aggregated'
    );

    (undef, $advert) = BOM::Test::Helper::P2P::create_advert(
        type   => 'sell',
        client => $client_p2p
    );
    (undef, $order) = BOM::Test::Helper::P2P::create_order(
        client    => $advertiser,
        advert_id => $advert->{id},
        amount    => 11
    );
    $advertiser->p2p_order_confirm(id => $order->{id});
    $client_p2p->p2p_order_confirm(id => $order->{id});
    ok $rule_engine->apply_rules($rule_name, %args), 'P2P sells are aggregated to zero so rule passes';

    subtest 'exclude payment agents' => sub {
        my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(type => 'sell');

        my $client = BOM::Test::Helper::P2P::create_advertiser();
        my (undef, $order) = BOM::Test::Helper::P2P::create_order(
            client    => $client,
            advert_id => $advert->{id},
            amount    => 10
        );

        $client->p2p_order_confirm(id => $order->{id});
        $advertiser->p2p_order_confirm(id => $order->{id});

        my $rule_engine = BOM::Rules::Engine->new(client => $client);
        my %args        = (
            loginid  => $client->loginid,
            currency => 'USD',
            action   => 'withdrawal',
            amount   => -10,
        );

        $client->payment_agent({status => 'applied'});

        cmp_deeply(
            exception { $rule_engine->apply_rules($rule_name, %args) },
            {
                error_code => 'P2PDepositsWithdrawalZero',
                params     => [num(0), num(10), 'USD'],
                rule       => $rule_name,
            },
            'Rule fails for applied PA'
        );

        $client->payment_agent->status('authorized');
        ok $rule_engine->apply_rules($rule_name, %args), 'Rule passes for authorized PA';
    };

    subtest 'Exclude banned countries for withdrawal error' => sub {

        my $config     = BOM::Config::Runtime->instance->app_config->payments;
        my $advertiser = BOM::Test::Helper::P2P::create_advertiser();
        my $client     = BOM::Test::Helper::P2P::create_advertiser(balance => 50);

        my (undef, $ad) = BOM::Test::Helper::P2P::create_advert(
            client           => $advertiser,
            type             => 'buy',
            max_order_amount => 50,
            amount           => 50,
        );
        my (undef, $order) = BOM::Test::Helper::P2P::create_order(
            client    => $client,
            advert_id => $ad->{id},
            amount    => 25
        );
        $advertiser->p2p_order_confirm(id => $order->{id});
        $client->p2p_order_confirm(id => $order->{id});

        $config->p2p->restricted_countries(['au']);
        $config->p2p_withdrawal_limit(0);
        $advertiser->residence('ng');
        $client->residence('au');

        my $rule_engine = BOM::Rules::Engine->new(client => $advertiser);
        my %args        = (
            loginid      => $advertiser->loginid,
            currency     => 'USD',
            action       => 'withdrawal',
            amount       => -5,
            payment_type => 'doughflow'
        );

        cmp_deeply(
            exception { $rule_engine->apply_rules('p2p.withdrawal_check', %args) },
            {
                error_code => 'P2PDepositsWithdrawalZero',
                params     => ['0.00', '25.00', 'USD'],
                rule       => 'p2p.withdrawal_check',
            },
            'Cannot withdraw even ng is not banned'
        );

        $rule_engine = BOM::Rules::Engine->new(client => $client);
        %args        = (
            loginid      => $client->loginid,
            currency     => 'USD',
            action       => 'withdrawal',
            amount       => -5,
            payment_type => 'doughflow'
        );
        ok $rule_engine->apply_rules('p2p.withdrawal_check', %args), 'Can withdraw even au is banned';

        $config->p2p->restricted_countries([]);
        $config->p2p_withdrawal_limit(100);

    };

};

done_testing();
