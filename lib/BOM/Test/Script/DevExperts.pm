package BOM::Test::Script::DevExperts;
use strict;
use warnings;

BEGIN {
    local $ENV{NO_PURGE_REDIS} = 1;
    require BOM::Test;
}
use BOM::Test::Script;

my ($service, $demo, $real);

BEGIN {
    if (not BOM::Test::on_production()) {
        # these are set in BOM::Test
        my ($service_port, $demo_port, $real_port) = @ENV{qw(DEVEXPERTS_API_SERVICE_PORT DEVEXPERTS_DEMO_SERVER_PORT DEVEXPERTS_REAL_SERVER_PORT)};

        $service = BOM::Test::Script->new(
            script => '/home/git/regentmarkets/bom-platform/bin/devexperts_api_service.pl',
            args   => [
                '--port',      $service_port, '--demo_port', $demo_port, '--demo_host', 'http://localhost',
                '--real_port', $real_port,    '--real_host', 'http://localhost'
            ],
            perlinc => [
                qw(/home/git/regentmarkets/perl-WebService-Async-DevExperts/lib /home/git/regentmarkets/perl-WebService-Async-DevExperts/local/lib/perl5)
            ],
        );
        die 'Failed to start DevExperts API service.' unless $service->start_script_if_not_running;

        $demo = BOM::Test::Script->new(
            script  => '/home/git/regentmarkets/bom-platform/bin/devexperts_server.pl',
            args    => ['--port', $demo_port],
            perlinc => [
                qw(/home/git/regentmarkets/perl-WebService-Async-DevExperts/lib /home/git/regentmarkets/perl-WebService-Async-DevExperts/local/lib/perl5)
            ],
            file_base => '/tmp/devexperts_demo_server'    # for pid file
        );
        die 'Failed to start DevExperts demo server.' unless $demo->start_script_if_not_running;

        $real = BOM::Test::Script->new(
            script  => '/home/git/regentmarkets/bom-platform/bin/devexperts_server.pl',
            args    => ['--port', $real_port],
            perlinc => [
                qw(/home/git/regentmarkets/perl-WebService-Async-DevExperts/lib /home/git/regentmarkets/perl-WebService-Async-DevExperts/local/lib/perl5)
            ],
            file_base => '/tmp/devexperts_real_server'
        );
        die 'Failed to start DevExperts real server.' unless $real->start_script_if_not_running;

    }
}

END {
    $service->stop_script if $service;
    $demo->stop_script    if $demo;
    $real->stop_script    if $real;
}

1;
