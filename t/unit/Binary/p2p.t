use Test::Most;
use Test::MockObject;
use Binary::WebSocketAPI::v3::Subscription::P2P::Advert;
use Binary::WebSocketAPI::v3::Subscription::P2P::Advertiser;
use Binary::WebSocketAPI::v3::Subscription::P2P::Order;
use Binary::WebSocketAPI::v3::Subscription::P2P::P2PSettings;

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
        'Binary::WebSocketAPI::v3::Subscription::P2P::Advert' => [
            loginid       => 1,
            account_id    => 2,
            advert_id     => 3,
            advertiser_id => 4,
            c             => $c,
            args          => {},
        ]);

    lives_ok { $worker->register } 'register ok';
    is $worker->advert_id,     3, 'advert_id matches';
    is $worker->advertiser_id, 4, 'advertiser_id matches';
    like($worker->uuid, qr/^\w{8}-\w{4}-\w{4}-\w{4}-\w{12}$/, 'has correct uuid');
    isa_ok $worker->subscription_manager, 'Binary::WebSocketAPI::v3::SubscriptionManager', 'subscription_manager';
    is $worker->channel, 'P2P::ADVERT::4::2::1::3', 'channel matches';

    lives_ok { $worker->process(encode_json_utf8({data => 'test message'})) } 'process with no tx';
    ok !$worker->c->{send_data}, 'no data when no tx';

    $c->mock('tx', sub { return 1 });
    lives_ok { $worker->process(encode_json_utf8({data => 'test message'})) } 'process ok';

    my $send_data = $worker->c->{send_data}->{json};
    is $send_data->{'subscription'}->{id}, $worker->uuid,     'subscription id matches';
    is $send_data->{'msg_type'},           'p2p_advert_info', 'msg_type matches';
    is_deeply $send_data->{'p2p_advert_info'}, {'data' => 'test message'}, 'send_data matches';
    lives_ok { $worker->unregister } 'unregister ok';
};

subtest 'P2P::Advertiser' => sub {
    my $c = mock_c();

    my $worker = new_ok(
        'Binary::WebSocketAPI::v3::Subscription::P2P::Advertiser' => [
            loginid            => 1,
            advertiser_loginid => 4,
            c                  => $c,
            args               => {},
        ]);
    lives_ok { $worker->register } 'register ok';

    is $worker->advertiser_loginid, 4, 'advertiser_loginid matches';
    is $worker->loginid,            1, 'loginid matches';
    like($worker->uuid, qr/^\w{8}-\w{4}-\w{4}-\w{4}-\w{12}$/, 'has correct uuid');
    isa_ok $worker->subscription_manager, 'Binary::WebSocketAPI::v3::SubscriptionManager', 'subscription_manager';
    is $worker->channel, 'P2P::ADVERTISER::NOTIFICATION::4::1', 'channel matches';

    lives_ok { $worker->process(encode_json_utf8({data => 'test message'})) } 'process with no tx';
    ok !$worker->c->{send_data}, 'no data when no tx';

    $c->mock('tx', sub { return 1 });
    lives_ok { $worker->process(encode_json_utf8({data => 'test message'})) } 'process ok';

    my $send_data = $worker->c->{send_data}->{json};
    is $send_data->{'subscription'}->{id}, $worker->uuid,         'subscription id matches';
    is $send_data->{'msg_type'},           'p2p_advertiser_info', 'msg_type matches';
    is_deeply $send_data->{'p2p_advertiser_info'}, {'data' => 'test message'}, 'send_data matches';
    lives_ok { $worker->unregister } 'unregister ok';

};

subtest 'P2P::Order' => sub {
    my $c = mock_c();

    my $worker = new_ok(
        'Binary::WebSocketAPI::v3::Subscription::P2P::Order' => [
            loginid       => 1,
            order_id      => 4,
            advertiser_id => 2,
            broker        => 'xyz',
            c             => $c,
            args          => {},
        ]);
    lives_ok { $worker->register } 'register ok';

    is $worker->order_id, 4, 'order_id matches';
    is $worker->loginid,  1, 'loginid matches';
    like($worker->uuid, qr/^\w{8}-\w{4}-\w{4}-\w{4}-\w{12}$/, 'has correct uuid');
    isa_ok $worker->subscription_manager, 'Binary::WebSocketAPI::v3::SubscriptionManager', 'subscription_manager';
    is $worker->channel, 'P2P::ORDER::NOTIFICATION::XYZ::1::2::-1::4::-1', 'channel matches';

    lives_ok { $worker->process(encode_json_utf8({data => 'test message'})) } 'process with no tx';
    ok !$worker->c->{send_data}, 'no data when no tx';

    $c->mock('tx', sub { return 1 });
    lives_ok { $worker->process(encode_json_utf8({data => 'test message', id => 0})) } 'process with order_id';

    my $send_data = $worker->c->{send_data}->{json};
    is $send_data->{'subscription'}->{id}, $worker->uuid,    'subscription id matches';
    is $send_data->{'msg_type'},           'p2p_order_info', 'msg_type matches';
    is_deeply $send_data->{'p2p_order_info'},
        {
        'data' => 'test message',
        id     => 0
        },
        'send_data matches';
    lives_ok { $worker->unregister } 'unregister ok';

};

subtest 'P2P::P2PSettings' => sub {
    my $c = mock_c();

    my $worker = new_ok(
        'Binary::WebSocketAPI::v3::Subscription::P2P::P2PSettings' => [
            c       => $c,
            args    => {},
            country => 'eg',
        ]);

    lives_ok { $worker->register } 'register ok';
    is $worker->country, 'eg', 'country matches';
    like($worker->uuid, qr/^\w{8}-\w{4}-\w{4}-\w{4}-\w{12}$/, 'has correct uuid');
    isa_ok $worker->subscription_manager, 'Binary::WebSocketAPI::v3::SubscriptionManager', 'subscription_manager';
    is $worker->channel, 'NOTIFY::P2P_SETTINGS::EG', 'channel matches';

    lives_ok { $worker->process(encode_json_utf8({data => 'test message'})) } 'process with no tx';
    ok !$worker->c->{send_data}, 'no data when no tx';

    $c->mock('tx', sub { return 1 });
    lives_ok { $worker->process(encode_json_utf8({data => 'test message'})) } 'process ok';

    my $send_data = $worker->c->{send_data}->{json};
    is $send_data->{'subscription'}->{id}, $worker->uuid,  'subscription id matches';
    is $send_data->{'msg_type'},           'p2p_settings', 'msg_type matches';
    is_deeply $send_data->{'p2p_settings'}, {'data' => 'test message'}, 'send_data matches';
    lives_ok { $worker->unregister } 'unregister ok';
};

done_testing();
