package BOM::Test::Script::DevExperts;
use strict;
use warnings;

BEGIN {
    local $ENV{NO_PURGE_REDIS} = 1;
    require BOM::Test;
}
use BOM::Test::Script;

my $api_service;
my $server;

BEGIN {

    if (not BOM::Test::on_production()) {
        # these are set in BOM::Test
        my ($service_port, $api_port) = @ENV{qw(DEVEXPERTS_API_SERVICE_PORT DEVEXPERTS_SERVER_PORT)};

        $api_service = BOM::Test::Script->new(
            script  => '/home/git/regentmarkets/bom-platform/bin/devexperts_api_service.pl',
            args    => ['--port', $service_port, '--api_port', $api_port, '--api_host', 'localhost', '--api_auth', 'hmac'],
            perlinc => [
                qw(/home/git/regentmarkets/perl-WebService-Async-DevExperts/lib /home/git/regentmarkets/perl-WebService-Async-DevExperts/local/lib/perl5)
            ],
        );
        die 'Failed to start DevExperts API service.' unless $api_service->start_script_if_not_running;

        $server = BOM::Test::Script->new(
            script  => '/home/git/regentmarkets/bom-platform/bin/devexperts_server.pl',
            args    => ['--port', $api_port],
            perlinc => [
                qw(/home/git/regentmarkets/perl-WebService-Async-DevExperts/lib /home/git/regentmarkets/perl-WebService-Async-DevExperts/local/lib/perl5)
            ],
        );
        die 'Failed to start DevExperts server.' unless $server->start_script_if_not_running;
    }
}

END {
    $api_service->stop_script if $api_service;
    $server->stop_script      if $server;
}

1;
