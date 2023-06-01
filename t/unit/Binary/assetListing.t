use Test::Most;
use Test::MockObject;
use Binary::WebSocketAPI::v3::Subscription::AssetListing;

use JSON::MaybeUTF8 qw(:v1);

sub mock_c {
    my $c = Test::MockObject->new;
    $c->{stash} = {};
    $c->mock('stash',  sub { return shift->{stash} });
    $c->mock('tx',     sub { });
    $c->mock('send',   sub { shift; $c->{send_data} = shift; });
    $c->mock('finish', sub { my $self = shift; $self->{stash} = {} });
    return $c;
}

subtest 'P2P::Advert' => sub {
    my $c      = mock_c();
    my $worker = new_ok(
        'Binary::WebSocketAPI::v3::Subscription::AssetListing' => [
            type   => 'mytype',
            symbol => 'abc',
            c      => $c,
            args   => {},
        ]);

    lives_ok { $worker->register } 'register ok';
    is $worker->symbol, 'abc',    'symbol matches';
    is $worker->type,   'mytype', 'type matches';
    like($worker->uuid, qr/^\w{8}-\w{4}-\w{4}-\w{4}-\w{12}$/, 'has correct uuid');
    isa_ok $worker->subscription_manager, 'Binary::WebSocketAPI::v3::SubscriptionManager', 'subscription_manager';
    is $worker->channel, 'asset_listing::abc', 'channel matches';

    lives_ok { $worker->process(encode_json_utf8({data => 'test message'})) } 'process ok';

    my $send_data = $worker->c->{send_data}->{json};
    is $send_data->{'subscription'}->{id}, $worker->uuid,                    'subscription id matches';
    is $send_data->{'msg_type'},           'trading_platform_asset_listing', 'msg_type matches';
    is_deeply $send_data->{'trading_platform_asset_listing'}, {'mt5' => {'assets' => []}}, 'send_data matches';
    lives_ok { $worker->unregister } 'unregister ok';
};

done_testing();
