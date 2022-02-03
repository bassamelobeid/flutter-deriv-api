use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::MockObject;
use BOM::Test::Helper::P2P;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

use BOM::Event::Actions::P2P;
use BOM::Event::Process;
use WebService::SendBird;

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

$client->p2p_chat_create(order_id => $order->{id});

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
    BOM::Test::Helper::P2P::set_order_status($client, $order->{id}, $status);
    BOM::Event::Process->new(category => 'generic')->process({
            type    => 'p2p_order_updated',
            details => {
                client_loginid => $client->loginid,
                order_id       => $order->{id}
            },
        }
        ),
        is $frozen, $tests{$status}, "expected freeze for $status";
}

BOM::Test::Helper::P2P::reset_escrow();

done_testing()
