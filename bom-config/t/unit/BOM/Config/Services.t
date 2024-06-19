use strict;
use warnings;

no indirect;

use Test::More;
use Test::MockModule;
use Test::MockObject;
use Test::Exception;
use Test::Deep;

use BOM::Config;
use BOM::Config::Services;
use App::Config::Chronicle;

subtest 'config' => sub {
    my $config_mock     = Test::MockModule->new("BOM::Config");
    my $mocked_services = {
        fraud_prevention => {
            enabled => 'false',
            host    => 127.0.0.1,
            port    => 8080
        },
        identity_verification => {
            enabled => 'true',
            host    => 130.0.0.1,
            port    => 8000
        }};

    $config_mock->redefine("services_config" => $mocked_services);

    is_deeply(BOM::Config::Services->config("identity_verification"), $mocked_services->{identity_verification}, 'correct arguments are passed');
    throws_ok { BOM::Config::Services->config() } qr/Service name is missed/, 'service name is not provided as argument';

    my $unsupported_service_name = "Unsupported Service";
    throws_ok { BOM::Config::Services->config($unsupported_service_name) } qr/Invalid service name $unsupported_service_name /,
        "Un-supported service name is provided as argument";

    $config_mock->unmock_all();
};

subtest 'is_enabled' => sub {
    my $config_mock    = Test::MockModule->new("BOM::Config");
    my $dummy_services = {
        fraud_prevention => {
            enabled => 'false',
            host    => 127.0.0.1,
            port    => 8080
        },
        identity_verification => {
            enabled => 'true',
            host    => 130.0.0.1,
            port    => 8000
        }};

    $config_mock->redefine("services_config" => $dummy_services);
    throws_ok { BOM::Config::Services->is_enabled() } qr/Service name is missed/, 'service name is not provided as argument';

    my $unsupported_service_name = "Unsupported Service";
    throws_ok { BOM::Config::Services->is_enabled($unsupported_service_name) } qr/Invalid service name $unsupported_service_name /,
        "Un-supported service name is provided as argument";

    my $instance          = BOM::Config::Runtime->instance;
    my $mocked_instance   = Test::MockObject->new($instance);
    my $mocked_app_config = Test::MockObject->new();
    my $mocked_system     = Test::MockObject->new();
    my $mocked_services   = Test::MockObject->new();

    $mocked_instance->mock("app_config" => sub { return $mocked_app_config });
    $mocked_app_config->mock("system"           => sub { return $mocked_system });
    $mocked_app_config->mock("check_for_update" => sub { return 0 });
    $mocked_system->mock("services" => sub { return $mocked_services });

    my $identity_verification_enabled_status         = $dummy_services->{identity_verification}->{enabled} eq 'true' ? 1 : 0;
    my $identity_verification_enabled_status_runtime = $identity_verification_enabled_status;

    $mocked_services->mock("identity_verification" => sub { $identity_verification_enabled_status_runtime });

    is(
        BOM::Config::Services->is_enabled("identity_verification"),
        $identity_verification_enabled_status_runtime,
        "service enable status is same on both BOM::Config and Runtime"
    );

    $identity_verification_enabled_status_runtime = !$identity_verification_enabled_status || 0;
    is(
        BOM::Config::Services->is_enabled("identity_verification"),
        $identity_verification_enabled_status_runtime,
        "service enable status is different on BOM::Config and Runtime"
    );
    $config_mock->unmock_all();
};

subtest 'identify_vetification.yml integrity check' => sub {
    my $config   = BOM::Config::identity_verification;
    my $expected = {
        statuses => {
            pending  => 'Pending',
            verified => 'Verified',
            refuted  => 'Refuted',
            failed   => 'Failed',
        },
        messages => [
            qw/
                UNEXPECTED_ERROR
                DOCUMENT_REJECTED
                MALFORMED_JSON
                UNDESIRED_HTTP_CODE
                INFORMATION_LACK
                NEEDS_TECHNICAL_INVESTIGATION
                PROVIDER_UNAVAILABLE
                TIMEOUT
                EMPTY_RESPONSE
                UNAVAILABLE_STATUS
                ADDRESS_VERIFIED
                NAME_MISMATCH
                EXPIRED
                DOB_MISMATCH
                UNDERAGE
                DECEASED
                /
        ],
        providers => {
            smile_identity => {
                selfish      => 0,
                portal_base  => 'https://portal.smileidentity.com/partner/job_results/production/%s',
                display_name => 'Smile Identity',
            },
            derivative_wealth => {
                selfish      => 0,
                display_name => 'Derivative Wealth',
            },
            metamap => {
                selfish      => 0,
                display_name => 'Metamap',
            },
            ai_prise => {
                selfish      => 1,
                display_name => 'AiPrise',
            },
            identity_pass => {
                selfish      => 0,
                display_name => 'Identity Pass',
                additional   => {
                    checks_per_month => 15000,
                }
            },
            data_zoo => {
                selfish      => 1,
                display_name => 'Data Zoo',
            },
            zaig => {
                selfish      => 1,
                portal_base  => 'https://dash.zaig.com.br/natural-person/%s',
                display_name => 'Zaig',
            }}};
    cmp_deeply $config, $expected, 'Expected information for config yml file';
};

done_testing;
