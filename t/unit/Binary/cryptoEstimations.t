use Test::Most;
use Test::MockObject;
use Binary::WebSocketAPI::v3::Subscription::CryptoEstimations;

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
my $subscription_message = {data => 'test message'};
my $currency_code        = 'BTC';
my $c                    = mock_c();
my $worker               = new_ok(
    'Binary::WebSocketAPI::v3::Subscription::CryptoEstimations' => [
        c             => $c,
        currency_code => $currency_code,
        args          => {},
    ]);

lives_ok { $worker->register } 'register ok';
like($worker->uuid, qr/^\w{8}-\w{4}-\w{4}-\w{4}-\w{12}$/, 'has correct uuid');
isa_ok $worker->subscription_manager, 'Binary::WebSocketAPI::v3::SubscriptionManager', 'subscription_manager';
is $worker->channel, 'CRYPTOCASHIER::ESTIMATIONS::FEE::' . $currency_code, 'channel matches';

lives_ok { $worker->process(encode_json_utf8($subscription_message)) } 'process with no tx';
ok !$worker->c->{send_data}, 'no data when no tx';

$c->mock('tx', sub { return 1 });

lives_ok { $worker->process(encode_json_utf8($subscription_message)) } 'process ok';

my $send_data = $worker->c->{send_data}->{json};
is $send_data->{'subscription'}->{id}, $worker->uuid,        'subscription id matches';
is $send_data->{'msg_type'},           'crypto_estimations', 'msg_type matches';
is_deeply $send_data->{'crypto_estimations'}, {$currency_code => $subscription_message}, 'send_data matches';
lives_ok { $worker->unregister } 'unregister ok';

done_testing();
