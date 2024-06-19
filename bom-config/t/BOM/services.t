use strict;
use warnings;

no indirect;

use Test::More;
use Test::Fatal;
use Test::MockModule;

use BOM::Config;
use BOM::Config::Services;

subtest 'Tests for is_enabled' => sub {
    my $service_name = 'fraud_prevention';

    my $mock_cfg    = Test::MockModule->new('BOM::Config');
    my $service_cfg = {
        $service_name => {
            enabled => 0,
            host    => 'test',
            port    => '80',
        }};

    $mock_cfg->mock(services_config => $service_cfg);

    ok !BOM::Config::Services->is_enabled($service_name), 'Able to disable from cfg file';

    $service_cfg->{$service_name}{enabled} = 1;

    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->system->services->$service_name(0);

    ok !BOM::Config::Services->is_enabled($service_name), 'Able to disable from app config';

    $app_config->system->services->$service_name(1);
    ok(BOM::Config::Services->is_enabled($service_name), 'Able to enable from app config');

    like exception { BOM::Config::Services->is_enabled() },                      qr{Service name is missed}, 'Got exception for missed service name';
    like exception { BOM::Config::Services->is_enabled('not_existed_service') }, qr{Invalid service name},   'Got exception for invalid service name';
};

subtest 'Test for config' => sub {
    my $service_name = 'fraud_prevention';

    my $mock_cfg    = Test::MockModule->new('BOM::Config');
    my $service_cfg = {
        $service_name => {
            enabled => 0,
            host    => 'test',
            port    => '80',
        }};

    $mock_cfg->mock(services_config => $service_cfg);

    ok(BOM::Config::Services->config($service_name), 'Able to get config for service');

    like exception { BOM::Config::Services->config() },                      qr{Service name is missed}, 'Got exception for missed service name';
    like exception { BOM::Config::Services->config('not_existed_service') }, qr{Invalid service name},   'Got exception for invalid service name';
};

done_testing();
