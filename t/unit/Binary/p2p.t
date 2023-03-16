use Test::Most;
use Test::MockObject;
use Binary::WebSocketAPI::v3::Subscription::P2P::Advert;
use JSON::MaybeUTF8 qw(:v1);

sub mock_c {
    my $c = Test::MockObject->new;
    $c->{stash} = {};
    $c->mock('stash',  sub { return shift->{stash} });
    $c->mock('tx',     sub { return 1 });
    $c->mock('send',   sub { shift; $c->{send_data} = shift; });
    $c->mock('finish', sub { my $self = shift; $self->{stash} = {} });
    return $c;
}

my $c = mock_c();

subtest 'P2P::Advert' => sub {
    my $worker = new_ok(
        'Binary::WebSocketAPI::v3::Subscription::P2P::Advert' => [
            loginid       => 1,
            account_id    => 2,
            advert_id     => 3,
            advertiser_id => 4,
            c             => $c,
            args          => {},
        ]);

    is $worker->advert_id,     3, 'advert_id matches';
    is $worker->advertiser_id, 4, 'advertiser_id matches';
    like($worker->uuid, qr/^\w{8}-\w{4}-\w{4}-\w{4}-\w{12}$/, 'has correct uuid');
    isa_ok $worker->subscription_manager, 'Binary::WebSocketAPI::v3::SubscriptionManager', 'subscription_manager';
    is $worker->channel, 'P2P::ADVERT::4::2::1::3', 'channel matches';

    lives_ok { $worker->process(encode_json_utf8({data => 'test message'})) } 'process ok';
    my $send_data = $worker->c->{send_data}->{json};
    is $send_data->{'subscription'}->{id}, $worker->uuid, 'subscription id matches';
    is $send_data->{'msg_type'}, 'p2p_advert_info', 'msg_type p2p_advert_info';
    is_deeply $send_data->{'p2p_advert_info'}, {'data' => 'test message'}, 'p2p_advert_info matches';
};

done_testing();
