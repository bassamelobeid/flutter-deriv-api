use strict;
use warnings;

no indirect;

use Test::More;
use Test::MockModule;
use Test::Exception;

use BOM::Config;
use BOM::Config::Services;
use App::Config::Chronicle;

subtest 'config' => sub {
    my $config_mock = Test::MockModule->new("BOM::Config");
    my $mocked_services = {
        fraud_prevention => {
            enabled => 'false',
            host => 127.0.0.1,
            port => 8080
        },
        identity_verification => {
            enabled => 'true',
            host => 130.0.0.1,
            port => 8000
        }
    };

    $config_mock->redefine("services_config" => $mocked_services );

    is_deeply(BOM::Config::Services->config("identity_verification"),$mocked_services->{identity_verification},'correct arguments are passed');
    throws_ok { BOM::Config::Services->config()} qr/Service name is missed/ , 'service name is not provided as argument';
    
    my $unsupported_service_name = "Unsupported Service";
    throws_ok {BOM::Config::Services->config($unsupported_service_name)} qr/Invalid service name $unsupported_service_name /, "Un-supported service name is provided as argument";

    $config_mock->unmock_all();
};

subtest 'is_enabled' => sub {
    my $config_mock = Test::MockModule->new("BOM::Config");
    my $mock_services = {
        fraud_prevention => {
            enabled => 'false',
            host => 127.0.0.1,
            port => 8080
        },
        identity_verification => {
            enabled => 'true',
            host => 130.0.0.1,
            port => 8000
        }
    };
    $config_mock->redefine("services_config" => $mock_services );
    throws_ok{ BOM::Config::Services->is_enabled() } qr/Service name is missed/ , 'service name is not provided as argument';
    
    my $unsupported_service_name = "Unsupported Service";
    throws_ok {BOM::Config::Services->is_enabled($unsupported_service_name)} qr/Invalid service name $unsupported_service_name /, "Un-supported service name is provided as argument";
    
    my $app_config = BOM::Config::Runtime->instance->app_config;
    my $identity_verification_enabled_status = $mock_services->{identity_verification}->{enabled} eq 'true' ? 1 : 0 ;
    
    my $mocked_runtime = Test::MockModule->new( ref $app_config->system->services)->redefine("identity_verification"=> sub { $identity_verification_enabled_status });
    is(BOM::Config::Services->is_enabled("identity_verification"),$identity_verification_enabled_status,"service enable status is same on both BOM::Config and Runtime");

    $mocked_runtime = Test::MockModule->new( ref $app_config->system->services)->redefine("identity_verification"=> sub { !$identity_verification_enabled_status || 0 });
    is(BOM::Config::Services->is_enabled("identity_verification"),!$identity_verification_enabled_status || 0 ,"service enable status is different on BOM::Config and Runtime");
};
done_testing;
