use strict;
use warnings;
no indirect;

use Test::Fatal;
use Test::MockModule;
use Test::More;
use Test::MockModule;
use Test::Deep;

use BOM::Event::Process;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::User;
use BOM::User::IdentityVerification;
use BOM::Config::Redis;
use BOM::Config::Runtime;

use constant IDV_LOCK_PENDING => 'IDV::LOCK::PENDING::';

# Initiate test client
my $email = 'test1@binary.com';
my $user  = BOM::User->create(
    email          => $email,
    password       => "pwd",
    email_verified => 1,
);

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    email          => $email,
    binary_user_id => $user->id,
});
$user->add_client($client);
$client->binary_user_id($user->id);
$client->save;

my $idv_model         = BOM::User::IdentityVerification->new(user_id => $client->user->id);
my $idv_event_handler = BOM::Event::Process->new(category => 'generic')->actions->{identity_verification_requested};
my $mock_qa           = Test::MockModule->new('BOM::Config');

my $mock_config_service = Test::MockModule->new('BOM::Config::Services');
my $idv_service_enabled = 1;
$mock_config_service->mock(
    'is_enabled' => sub {
        if ($_[1] eq 'identity_verification') {
            return $idv_service_enabled;
        }
        return $mock_config_service->original('is_enabled')->(@_);
    });

my $args = {
    loginid => $client->loginid,
};

my $mock_idv_model = Test::MockModule->new('BOM::User::IdentityVerification');
my $mock_idv_event = Test::MockModule->new('BOM::Event::Actions::Client::IdentityVerification');
my $redis          = BOM::Config::Redis::redis_events();

my $client_mock                 = Test::MockModule->new('BOM::User::Client');
my $idv_mock                    = Test::MockModule->new('BOM::User::IdentityVerification');
my $has_expired_document_chance = 1;
$idv_mock->mock(
    'has_expired_document_chance',
    sub {
        return $has_expired_document_chance;
    });

subtest 'nonentity client' => sub {
    $args = {loginid => 'CR0'};
    like exception { $idv_event_handler->($args)->get }, qr/Could not initiate client/i, 'Exception thrown for unknown client';
};

subtest 'no submission left' => sub {
    $args = {loginid => $client->loginid};
    $mock_idv_model->mock(submissions_left => 0);
    like exception { $idv_event_handler->($args)->get }, qr/No pending lock found/i, 'Exception thrown when no pending lock';

    $redis->set(IDV_LOCK_PENDING . $client->binary_user_id, 0);

    like exception { $idv_event_handler->($args)->get }, qr/No submissions left/i, 'Exception thrown when no submission left';
};

subtest 'no standby document' => sub {
    $args = {loginid => $client->loginid};
    $mock_idv_model->mock(submissions_left     => 3);
    $mock_idv_model->mock(get_standby_document => undef);
    $redis->set(IDV_LOCK_PENDING . $client->binary_user_id, 1);
    like exception { $idv_event_handler->($args)->get }, qr/No standby document found/i, 'Exception thrown when no standby document found';

    $mock_idv_model->mock(submissions_left => 0);
    $has_expired_document_chance = 1;

    $redis->set(IDV_LOCK_PENDING . $client->binary_user_id, 0);
    like exception { $idv_event_handler->($args)->get }, qr/No submissions left, IDV request has ignored for loginid:/i,
        'Exception thrown for user without submissions left';

    $has_expired_document_chance = 0;

    $redis->set(IDV_LOCK_PENDING . $client->binary_user_id, 1);
    like exception { $idv_event_handler->($args)->get }, qr/No standby document found/i, 'Exception thrown for user without standby document for IDV';

    _set_submissions_left($user->id, 2);

    $redis->set(IDV_LOCK_PENDING . $client->binary_user_id, 1);
    like exception { $idv_event_handler->($args)->get }, qr/No standby document found/i, 'Exception thrown for user without standby document for IDV';
    $mock_idv_model->unmock_all;
};

subtest 'unimplemented provider' => sub {
    $args = {loginid => $client->loginid};
    $mock_idv_event->mock(_trigger_through_microservice => sub { die 'unexpected' });

    $idv_model->add_document({
        issuing_country => 'xx',           # unimplemented provider
        number          => '123',
        type            => 'national_id'
    });
    $redis->set(IDV_LOCK_PENDING . $client->binary_user_id, 1);
    is $idv_event_handler->($args)->get, 1, 'the event processed without error, unimplemented providers are handled by identity_verification service';

    $mock_idv_event->unmock_all;
};

subtest 'disabled document type from a specific provider' => sub {
    $args = {loginid => $client->loginid};

    BOM::Config::Runtime->instance->app_config->system->suspend->idv_document_types([qw(in:drivers_license)]);

    $idv_model->add_document({
        issuing_country => 'in',
        number          => '123',
        type            => 'drivers_license'
    });

    $redis->set(IDV_LOCK_PENDING . $client->binary_user_id, 1);
    is $idv_event_handler->($args)->get, 1, 'the event processed without error, disabled document types are handled by identity_verification service';

    BOM::Config::Runtime->instance->app_config->system->suspend->idv_document_types([qw( )]);
};

subtest 'microservice is disabled' => sub {
    $args                = {loginid => $client->loginid};
    $idv_service_enabled = 0;

    $redis->set(IDV_LOCK_PENDING . $client->binary_user_id, 1);
    like exception { $idv_event_handler->($args)->get }, qr/microservice is not enabled/i,
        'Exception thrown when microservice is disabled through configs';

    $mock_config_service->unmock_all;
};

subtest 'get provider' => sub {
    $mock_qa->mock('on_qa' => 1);
    is BOM::Event::Actions::Client::IdentityVerification::_has_provider('qq', 'passport'), 1, 'Expected truthy for qq country';

    $mock_qa->mock('on_qa' => 0);
    is BOM::Event::Actions::Client::IdentityVerification::_has_provider('qq', 'passport'), undef, 'Expected undef for unsupported country';

    is BOM::Event::Actions::Client::IdentityVerification::_has_provider('br', 'cpf'), 1, 'Expected truthy for br country';

    $redis->set(BOM::User::IdentityVerification::IDV_CONFIGURATION_OVERRIDE . 'zaig', 1);
    is BOM::Event::Actions::Client::IdentityVerification::_has_provider('br', 'cpf'), undef, 'Expected undef for disabled provider';
    $redis->del(BOM::User::IdentityVerification::IDV_CONFIGURATION_OVERRIDE . 'zaig');

    BOM::Config::Runtime->instance->app_config->system->suspend->idv_providers([qw(zaig)]);
    is BOM::Event::Actions::Client::IdentityVerification::_has_provider('br', 'cpf'), undef, 'Expected undef for disabled provider';
    BOM::Config::Runtime->instance->app_config->system->suspend->idv_providers([qw( )]);

    $mock_qa->unmock_all;
};

$idv_mock->unmock_all;
$client_mock->unmock_all;

sub _set_submissions_left {
    my $user_id = shift;
    my $left    = shift;
    my $redis   = BOM::Config::Redis::redis_events();

    $redis->set(BOM::User::IdentityVerification::IDV_REQUEST_PER_USER_PREFIX . $user_id, 2 - $left);
}

done_testing();

