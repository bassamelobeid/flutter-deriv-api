use Test::Most;
use Test::MockObject;
use Binary::WebSocketAPI::v3::Subscription::CashierPayments;

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

my $c      = mock_c();
my $worker = new_ok(
    'Binary::WebSocketAPI::v3::Subscription::CashierPayments' => [
        transaction_type => 'all',
        loginid          => 1,
        c                => $c,
        args             => {},
    ]);

lives_ok { $worker->register } 'register ok';
is $worker->loginid,          1,     'loginid matches';
is $worker->transaction_type, 'all', 'type matches';
like($worker->uuid, qr/^\w{8}-\w{4}-\w{4}-\w{4}-\w{12}$/, 'has correct uuid');
isa_ok $worker->subscription_manager, 'Binary::WebSocketAPI::v3::SubscriptionManager', 'subscription_manager';
is $worker->channel, 'CASHIER::PAYMENTS::1', 'channel matches';

lives_ok { $worker->process(encode_json_utf8({data => 'test message'})) } 'process when no tx';

ok !$worker->c->{send_data}, 'no data when no tx';

$c->mock('tx', sub { return 1 });
lives_ok { $worker->process(encode_json_utf8({data => 'test message', client_loginid => 1})) } 'process ok';
my $send_data = $worker->c->{send_data}->{json};
is $send_data->{'subscription'}->{id}, $worker->uuid,      'subscription id matches';
is $send_data->{'msg_type'},           'cashier_payments', 'msg_type matches';
is_deeply $send_data->{'cashier_payments'},
    {
    'crypto' => [],
    'data'   => 'test message'
    },
    'send_data matches';
lives_ok { $worker->unregister } 'unregister ok';

done_testing();
