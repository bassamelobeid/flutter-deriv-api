package BOM::Platform::Acquired::Webhook;

use strict;
use warnings;
use Log::Any::Adapter qw(Stderr), log_level => $ENV{ACQUIRED_LOG_LEVEL} // 'info';
use BOM::Platform::Acquired::Webhook::Collector;
use Log::Any qw($log);

use parent qw(Mojolicious);

=head2 startup

Sets the Mojolicious configuration and routing to serve the acquired.com webhook
requests.

This service includes only one route ("/"), this is good enough to verify and process 
the acquired.com payloads.

=cut

sub startup {
    my ($self) = @_;
    $self->moniker('acquired_dotcom_webhook');
    $self->plugin('Config' => {file => '/etc/rmg/acquired_dotcom_webhook.conf'}) if -e '/etc/rmg/acquired_dotcom_webhook.conf';
    $log->info('Starting webhook handler');
    $self->routes->post('/')->to('collector#collect');
    $self->routes->get('/')->to('collector#collect');
}

1;
