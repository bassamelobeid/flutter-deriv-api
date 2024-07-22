use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::MockObject;
use BOM::Test::Helper::P2P;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Customer;

use BOM::Event::Actions::P2P;
use BOM::Event::Process;
use WebService::SendBird;

my $service_contexts = BOM::Test::Customer::get_service_contexts();

my $mock_emitter = Test::MockModule->new('BOM::Platform::Event::Emitter');
my @emissions;
$mock_emitter->redefine(
    'emit' => sub {
        my ($track_event, $args) = @_;
        push @emissions,
            {
            event => $track_event,
            args  => $args
            };
        #return Future->done(1);
    });

BOM::Test::Helper::P2P::bypass_sendbird();

my $escrow = BOM::Test::Helper::P2P::create_escrow();
my ($advertiser, $advert) = BOM::Test::Helper::P2P::create_advert(
    amount => 100,
    type   => 'sell'
);
my ($client, $order) = BOM::Test::Helper::P2P::create_order(
    advert_id => $advert->{id},
    amount    => 100
);

$client->p2p_create_order_chat(order_id => $order->{id});

my %tests = (
    'pending'           => undef,
    'buyer-confirmed'   => undef,
    'timed-out'         => undef,
    'disputed'          => undef,
    'completed'         => 1,
    'cancelled'         => 1,
    'refunded'          => 1,
    'dispute-refunded'  => 1,
    'dispute-completed' => 1,
);

my $frozen;
my $mock_channel = Test::MockObject->new();
$mock_channel->mock(set_freeze => sub { $frozen = $_[1] ? 1 : 0 });

my $mock_sb = Test::MockModule->new('WebService::SendBird');
$mock_sb->mock('view_group_chat' => $mock_channel);

for my $status (sort keys %tests) {
    undef $frozen;
    undef @emissions;
    BOM::Test::Helper::P2P::set_order_status($client, $order->{id}, $status);
    BOM::Event::Process->new(category => 'generic')->process({
            type    => 'p2p_order_updated',
            details => {
                client_loginid => $client->loginid,
                order_id       => $order->{id}
            },
        },
        'Test Stream',
        $service_contexts,
        ),
        is $frozen, $tests{$status}, "expected freeze for $status";
    is $emissions[0]->{event}, 'p2p_order_updated_handled', "event emitted $status";
}

BOM::Test::Helper::P2P::reset_escrow();

done_testing()
