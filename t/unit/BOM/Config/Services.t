use strict;
use warnings;

no indirect;

use Test::More;
use Test::MockModule;
use Test::Exception;

use BOM::Config;
use BOM::Config::Services;

subtest 'config' => sub {
    my $config_mock = Test::MockModule->new("BOM::Config");
    $config_mock->redefine("services_config" => {
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
    });

    my $expected = {
        enabled => 'true',
        host => 130.0.0.1,
        port => 8000
    };

    is_deeply(BOM::Config::Services->config("identity_verification"),$expected,'correct arguments are passed');
    throws_ok { BOM::Config::Services->config()} qr/Service name is missed/ , 'service name is not provided as argument';
    
    my $unsupported_service_name = "Unsupported Service";
    throws_ok {BOM::Config::Services->config($unsupported_service_name)} qr/Invalid service name $unsupported_service_name /, "Un-supported service name is provided as argument";

    $config_mock->unmock_all();
};

subtest 'is_enabled' => sub {
    is(1,1,'sample');
};
done_testing;
