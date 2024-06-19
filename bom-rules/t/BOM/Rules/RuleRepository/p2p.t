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

    $rule_engine = BOM::Rules::Engine->new(client => $advertiser->client);

    %args = (loginid => $advertiser->loginid);

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

    $rule_engine = BOM::Rules::Engine->new(client => $client_p2p->client);
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

    $rule_engine = BOM::Rules::Engine->new(client => $advertiser->client);
    %args        = (loginid => $advertiser->loginid);

    ok $rule_engine->apply_rules($rule_name, %args), 'Rule passes for advertiser with cancelled order';
};

done_testing();
