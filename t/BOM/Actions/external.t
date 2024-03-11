use Test::More;
use Log::Any::Test;
use Log::Any qw($log);
use BOM::Event::Actions::External;
use Test::MockModule;
use Test::Exception;
use Test::Deep;
use IO::Async::Loop;
use BOM::Event::Services;
use BOM::User::IdentityVerification;
use BOM::Platform::Utility;
use JSON::MaybeUTF8 qw(decode_json_utf8);

my $loop = IO::Async::Loop->new;
$loop->add(my $services = BOM::Event::Services->new);
my $redis = $services->redis_events_write();

subtest 'nodejs_hello' => sub {
    $log->clear();

    BOM::Event::Actions::External::nodejs_hello();

    $log->contains_ok(qr/Hello from nodejs/);
};

subtest 'send_idv_configuration' => sub {
    my $mocked_emitter = Test::MockModule->new('BOM::Platform::Event::Emitter');
    my $emissions      = {};
    $mocked_emitter->mock(
        'emit',
        sub {
            my $args = {@_};

            $emissions = {$emissions->%*, $args->%*};

            return undef;
        });

    my $dog_mock = Test::MockModule->new('DataDog::DogStatsd::Helper');
    my @doggy_bag;
    $dog_mock->mock(
        'stats_inc',
        sub {
            push @doggy_bag, shift;
        });

    BOM::Event::Actions::External::send_idv_configuration->get;
    is exists($emissions->{idv_configuration}), 1, 'idv_configuration event emitted';

    my $config = BOM::Platform::Utility::idv_configuration();
    my $sent   = $emissions->{idv_configuration};
    cmp_deeply($sent, $config, 'Expected bundle sent.');

    cmp_deeply [@doggy_bag], ['event.identity_verification.configuration_bundle_sent'], 'Expected dog bag';

    $mocked_emitter->unmock_all();
    $dog_mock->unmock_all();
};

subtest 'idv_configuration_disable_provider' => sub {
    my $mocked_emitter = Test::MockModule->new('BOM::Platform::Event::Emitter');
    my $emissions      = {};
    $mocked_emitter->mock(
        'emit',
        sub {
            my $args = {@_};

            $emissions = {$emissions->%*, $args->%*};

            return undef;
        });

    my $dog_mock = Test::MockModule->new('DataDog::DogStatsd::Helper');
    my @doggy_bag;
    $dog_mock->mock(
        'stats_inc',
        sub {
            push @doggy_bag, shift;
        });

    my $countries_mock = Test::MockModule->new('Brands::Countries');
    my $idv_config     = {py => {document_types => {national_id => {providers => ['provider_a', 'provider_b']}}}};
    $countries_mock->mock(
        'get_idv_config',
        sub {
            my (undef, $country) = @_;

            return $idv_config->{$country} if $country;
            return $idv_config;
        });

    my $args = {};
    dies_ok { BOM::Event::Actions::External::idv_configuration_disable_provider($args)->get } 'Exception thrown in no provider';

    $args = {provider => 'provider_a'};
    BOM::Event::Actions::External::idv_configuration_disable_provider($args)->get;
    is $redis->get(BOM::User::IdentityVerification::IDV_CONFIGURATION_OVERRIDE . 'provider_a')->get, 1, 'provider disabled redis key set';

    my $config           = BOM::Platform::Utility::idv_configuration();
    my $provider_enabled = $config->{'providers'}->{'provider_a'}->{'countries'}->{'py'}->{'documents'}->{'national_id'}->{'enabled'};
    ok !$provider_enabled, 'provider is disabled';

    is exists($emissions->{idv_configuration}), 1, 'idv_configuration event emitted';

    my $config = BOM::Platform::Utility::idv_configuration();
    my $sent   = $emissions->{idv_configuration};
    cmp_deeply($sent, $config, 'Expected bundle sent.');

    cmp_deeply [@doggy_bag], ['event.identity_verification.disabled_provider_provider_a', 'event.identity_verification.configuration_bundle_sent'],
        'Expected dog bag';

    $mocked_emitter->unmock_all();
    $dog_mock->unmock_all();
};

subtest 'idv_configuration_enable_provider' => sub {
    my $mocked_emitter = Test::MockModule->new('BOM::Platform::Event::Emitter');
    my $emissions      = {};
    $mocked_emitter->mock(
        'emit',
        sub {
            my $args = {@_};

            $emissions = {$emissions->%*, $args->%*};

            return undef;
        });

    my $dog_mock = Test::MockModule->new('DataDog::DogStatsd::Helper');
    my @doggy_bag;
    $dog_mock->mock(
        'stats_inc',
        sub {
            push @doggy_bag, shift;
        });

    my $countries_mock = Test::MockModule->new('Brands::Countries');
    my $idv_config     = {py => {document_types => {national_id => {providers => ['provider_a', 'provider_b']}}}};
    $countries_mock->mock(
        'get_idv_config',
        sub {
            my (undef, $country) = @_;

            return $idv_config->{$country} if $country;
            return $idv_config;
        });

    $redis->set(BOM::User::IdentityVerification::IDV_CONFIGURATION_OVERRIDE . 'provider_a', 1)->get;
    my $config           = BOM::Platform::Utility::idv_configuration();
    my $provider_enabled = $config->{'providers'}->{'provider_a'}->{'countries'}->{'py'}->{'documents'}->{'national_id'}->{'enabled'};
    ok !$provider_enabled, 'provider is disabled';

    my $args = {};
    dies_ok { BOM::Event::Actions::External::idv_configuration_enable_provider($args)->get } 'Exception thrown in no provider';

    $args = {provider => 'provider_a'};
    BOM::Event::Actions::External::idv_configuration_enable_provider($args)->get;
    is $redis->get(BOM::User::IdentityVerification::IDV_CONFIGURATION_OVERRIDE . 'provider_a')->get, undef, 'provider disabled redis key deleted';

    is exists($emissions->{idv_configuration}), 1, 'idv_configuration event emitted';

    my $config = BOM::Platform::Utility::idv_configuration();
    my $sent   = $emissions->{idv_configuration};
    cmp_deeply($sent, $config, 'Expected bundle sent.');

    cmp_deeply [@doggy_bag], ['event.identity_verification.enabled_provider_provider_a', 'event.identity_verification.configuration_bundle_sent'],
        'Expected dog bag';

    $mocked_emitter->unmock_all();
    $dog_mock->unmock_all();
};

done_testing;
