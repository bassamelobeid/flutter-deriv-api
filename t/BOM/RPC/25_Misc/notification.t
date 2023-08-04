use strict;
use warnings;
use utf8;

use Test::Most;
use Test::Mojo;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::Token;
use Test::BOM::RPC::QueueClient;

use BOM::Config::Redis;
use BOM::User::Onfido;

my $user = BOM::User->create(
    email    => 'rpc_notif@binary.com',
    password => 'abcdabcd'
);
my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});
$user->add_client($test_client);

my $m     = BOM::Platform::Token::API->new;
my $token = $m->create_token($test_client->loginid, 'test token');

my $c      = Test::BOM::RPC::QueueClient->new();
my $method = 'notification_event';

subtest 'Notification - validations' => sub {
    my $params = {};
    is_deeply $c->tcall($method, $params)->{error},
        {
        code              => 'InvalidToken',
        message_to_client => 'The token is invalid.'
        },
        'missing token error';

    $params->{token} = 'abcd';
    is_deeply $c->tcall($method, $params)->{error},
        {
        code              => 'InvalidToken',
        message_to_client => 'The token is invalid.'
        },
        'invalid token error';

    $params->{token} = $token;
    is_deeply $c->tcall($method, $params)->{error},
        {
        code              => 'UnrecognizedEvent',
        message_to_client => 'No such category or event. Please check the provided value.'
        },
        'missing catetory and event error';

    $params->{args}->{category} = 'authentication';
    is_deeply $c->tcall($method, $params)->{error},
        {
        code              => 'UnrecognizedEvent',
        message_to_client => 'No such category or event. Please check the provided value.'
        },
        'No error with valid category and event';

    $params->{args}->{event} = 'poi_documents_uploaded';
    is $c->tcall($method, $params)->{error}, undef, 'Valid category and event';
};

subtest 'Notification - authentication events' => sub {
    my $onfido_mock = Test::MockModule->new('BOM::User::Onfido');
    my $applicant_id;
    $onfido_mock->mock(
        'get_user_onfido_applicant',
        sub {
            return {id => $applicant_id};
        });

    my $params = {
        token => $token,
        args  => {
            category => 'authentication',
            event    => 'poi_documents_uploaded'
        }};

    my $redis       = BOM::Config::Redis::redis_events();
    my $pending_key = +BOM::User::Onfido::ONFIDO_REQUEST_PENDING_PREFIX . $test_client->binary_user_id;
    my $key         = +BOM::User::Onfido::ONFIDO_REQUEST_PER_USER_PREFIX . $test_client->binary_user_id;
    $redis->del($key);

    my @emit_args;
    my $mock_emitter = Test::MockModule->new('BOM::Platform::Event::Emitter');
    $mock_emitter->redefine(emit => sub { @emit_args = @_; });

    $redis->del($pending_key);
    is_deeply $c->tcall($method, $params), {status => 1}, 'Expected response';
    is_deeply [@emit_args], [], 'Enitted event args are correct';
    ok !$redis->get($key),        'Counter not increased';
    ok $redis->get($pending_key), 'Pending acquired';

    $applicant_id = 'test';
    $redis->del($pending_key);
    is_deeply $c->tcall($method, $params), {status => 1}, 'Expected response';
    is scalar @emit_args, 2,                          'Correct number of event args';
    is $emit_args[0],     'ready_for_authentication', 'Emitted event name is correct';
    is_deeply $emit_args[1],
        {
        loginid      => $test_client->loginid,
        applicant_id => 'test',
        },
        'Enitted event args are correct';
    is $redis->get($key), 1, 'Counter increased';
    ok $redis->get($pending_key), 'Pending acquired';

    $redis->del($pending_key);
    $redis->del($key);

    $params->{args}->{args}->{documents} = [10, 11];
    undef @emit_args;
    is_deeply $c->tcall($method, $params), {status => 1}, 'Expected response';
    is scalar @emit_args, 2,                          'Correct number of event args';
    is $emit_args[0],     'ready_for_authentication', 'Emitted event name is correct';
    is_deeply $emit_args[1],
        {
        loginid      => $test_client->loginid,
        applicant_id => 'test',
        documents    => [10, 11],
        },
        'Enitted event args are correct';
    is $redis->get($key), 1, 'Counter increased';
    ok $redis->get($pending_key), 'Pending acquired';

    subtest 'pending flag' => sub {
        undef @emit_args;
        $params->{args}->{args}->{documents} = [100, 101];
        is_deeply $c->tcall($method, $params), {status => 1}, 'Expected response';
        is $redis->get($key), 1, 'Counter not increased';
        is scalar @emit_args, 0, 'No event emitted';
    };

};

done_testing();

