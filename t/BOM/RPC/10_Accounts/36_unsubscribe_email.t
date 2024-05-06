use strict;
use warnings;

use utf8;
use Test::More;
use Test::Deep;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use Test::BOM::RPC::QueueClient;
# init db
my $email    = 'abc@binary.com';
my $password = 'jskjd8292922';
my $hash_pwd = BOM::User::Password::hashpw($password);

my $user = BOM::User->create(
    email          => $email,
    password       => $hash_pwd,
    email_verified => 1,
    email_consent  => 1,
);

my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    email          => $email,
    binary_user_id => $user->id,
});

$user->update_has_social_signup(0);
$user->add_client($test_client);

$test_client->binary_user_id($user->id);
$test_client->save;

is $user->email_consent, 1, 'email consent is accepted by default';

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

my $checksum = BOM::User::Utility::generate_email_unsubscribe_checksum($test_client->binary_user_id, $email);
my $params   = {
    source    => 1,
    client_ip => '127.0.0.1',
    args      => {
        checksum          => $checksum,
        binary_user_id    => $test_client->binary_user_id,
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
    is $user->email_consent, 1, "User subscription is active";

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
    print Data::Dumper::Dumper($result);
    is_deeply($result, $response, 'Unsubscribe Request Successful');

    $user = BOM::User->new(id => $user->id);
    is $user->email_consent, 0, "User subscription is inactive";

    # Check invalid loginid
    my $fake_user_id = '345234';
    $checksum = BOM::User::Utility::generate_email_unsubscribe_checksum($fake_user_id, $email);
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
