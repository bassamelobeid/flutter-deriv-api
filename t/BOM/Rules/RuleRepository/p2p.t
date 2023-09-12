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

    # p2p_withdrawable_balance() tests are in bom-user
    my $mock_client = Test::MockModule->new('BOM::User::Client');
    my $limit;
    $mock_client->mock(p2p_withdrawable_balance => sub { $limit });

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'p2p2@test.com',
    });

    BOM::User->create(
        email    => $client->email,
        password => 'x',
    )->add_client($client);

    $client->account('USD');
    BOM::Test::Helper::Client::top_up($client, 'USD', 10);

    my $rule_engine = BOM::Rules::Engine->new(client => $client);
    my %args        = (
        loginid  => $client->loginid,
        currency => 'USD',
        action   => 'deposit',
    );

    ok $rule_engine->apply_rules($rule_name, %args), 'Rule passes for deposit';
    $args{action} = 'withdrawal';

    like(exception { $rule_engine->apply_rules($rule_name, %args) }, qr/Amount is required/, 'dies if no amount');

    $limit = 10;
    $args{amount} = -10;
    ok $rule_engine->apply_rules($rule_name, %args), 'Rule passes if limit is ok';

    $limit = 0;
    cmp_deeply(
        exception { $rule_engine->apply_rules($rule_name, %args) },
        {
            error_code => 'P2PDepositsWithdrawalZero',
            params     => [num(0), num(10), 'USD'],
            rule       => $rule_name,
        },
        'Error for zero limit'
    );

    $limit = 9;
    cmp_deeply(
        exception { $rule_engine->apply_rules($rule_name, %args) },
        {
            error_code => 'P2PDepositsWithdrawal',
            params     => [num(9), num(1), 'USD'],
            rule       => $rule_name,
        },
        'Error for insufficient limit'
    );

    $args{payment_type} = 'internal_transfer';

    cmp_deeply(
        exception { $rule_engine->apply_rules($rule_name, %args) },
        {
            error_code => 'P2PDepositsTransfer',
            params     => [num(9), num(1), 'USD'],
            rule       => $rule_name,
        },
        'Specific error code for internal_transfer, insufficient limit'
    );

    $limit = 0;
    cmp_deeply(
        exception { $rule_engine->apply_rules($rule_name, %args) },
        {
            error_code => 'P2PDepositsTransferZero',
            params     => [num(0), num(10), 'USD'],
            rule       => $rule_name,
        },
        'Specific error code for internal_transfer, zero limit'
    );
    delete $args{payment_type};

    $client->payment_agent({status => 'applied'});
    cmp_deeply(
        exception { $rule_engine->apply_rules($rule_name, %args) },
        {
            error_code => 'P2PDepositsWithdrawalZero',
            params     => [num(0), num(10), 'USD'],
            rule       => $rule_name,
        },
        'Error for applied PA'
    );

    $client->payment_agent({status => 'authorized'});
    ok $rule_engine->apply_rules($rule_name, %args), 'Rule passes for authorized PA ';
};

done_testing();
