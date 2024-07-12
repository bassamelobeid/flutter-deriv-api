use strict;
use warnings;

use utf8;
use Test::More;
use Test::Deep;
use Test::MockModule;
use BOM::Test::Customer;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use Test::BOM::RPC::QueueClient;

my $customer = BOM::Test::Customer->create(
    email_verified    => 1,
    email_consent     => 1,
    has_social_signup => 0,
    clients           => [{
            name            => 'CR',
            broker_code     => 'CR',
            default_account => 'USD'
        },
    ]);
my $test_client = $customer->get_client_object('CR');

my $c = Test::BOM::RPC::QueueClient->new();
my $emitted;
my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_events->mock(
    'emit',
    sub {
        my ($type, $data) = @_;
        $emitted->{$type} = $data;
    });
my $mocked_thirdparty = Test::MockModule->new('BOM::Config');
$mocked_thirdparty->mock(
    'third_party',
    sub {
        return {'customerio' => {'hash_key' => 'some_key'}};
    });

my $method = 'unsubscribe_email';
my $response;

my $checksum = BOM::User::Utility::generate_email_unsubscribe_checksum($test_client->binary_user_id, $customer->get_email());
my $params   = {
    source    => 1,
    client_ip => '127.0.0.1',
    args      => {
        checksum          => $checksum,
        binary_user_id    => $customer->get_user_id(),
        unsubscribe_email => 1
    }};

subtest 'unsubscribe email' => sub {

    # Check checksum
    $params->{'args'}->{'checksum'} = $checksum . 'test';
    my $result = $c->tcall($method, $params);
    $response = {
        'error' => {
            'code'              => 'InvalidChecksum',
            'message_to_client' => 'The security hash used in your request appears to be invalid.'
        }};
    is_deeply($result, $response, 'unsubscribe_email returns invalid checksum error');

    # Check checksum and login and do subscribed
    $response = BOM::Service::user(
        context    => $customer->get_user_service_context(),
        command    => 'get_attributes',
        user_id    => $customer->get_user_id(),
        attributes => [qw(email_consent)],
    );
    is $response->{status},                    'ok', 'user service call succeeded';
    is $response->{attributes}{email_consent}, 1,    "User subscription is still active";

    $params->{'args'}->{'checksum'} = $checksum;
    $result                         = $c->tcall($method, $params);
    $response                       = {
        'stash' => {
            'source_bypass_verification' => 0,
            'app_markup_percentage'      => '0',
            'valid_source'               => 1,
            source_type                  => 'official',
        },
        'binary_user_id'           => $test_client->binary_user_id,
        'email_unsubscribe_status' => 1
    };
    is_deeply($result, $response, 'Unsubscribe Request Successful');

    $response = BOM::Service::user(
        context    => $customer->get_user_service_context(),
        command    => 'get_attributes',
        user_id    => $customer->get_user_id(),
        attributes => [qw(email_consent)],
    );
    is $response->{status},                    'ok', 'user service call succeeded';
    is $response->{attributes}{email_consent}, 0,    "User subscription is inactive";

    # Check invalid loginid
    my $fake_user_id = '345234';
    $checksum = BOM::User::Utility::generate_email_unsubscribe_checksum($fake_user_id, $customer->get_email());
    $params   = {
        source    => 1,
        client_ip => '127.0.0.1',
        args      => {
            checksum          => $checksum,
            binary_user_id    => $fake_user_id,
            unsubscribe_email => 1
        }};

    $result = $c->tcall($method, $params);

    ok($emitted->{email_subscription}, 'email_subscription event emitted');

    $response = {
        'error' => {
            'code'              => 'InvalidUser',
            'message_to_client' => 'Your User ID appears to be invalid.'
        }};
    is_deeply($result, $response, 'unsubscribe_email returns invalid user error for fake user');
};

done_testing();
