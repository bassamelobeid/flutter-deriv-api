package BOM::Platform::Webhook;

use strict;
use warnings;
use Log::Any::Adapter qw(Stderr), log_level => $ENV{WEBHOOK_LOG_LEVEL} // 'info';
use BOM::Platform::Webhook::Acquired;
use BOM::Platform::Webhook::ISignThis;
use Log::Any qw($log);

use parent qw(Mojolicious);

=head2 startup

Sets the Mojolicious configuration and routing to serve our multipurpose webhooks.

This service should include a path for each webhook implemented, so far we've implemented:

=over 4

=item * B<Acquired>, payments fraud and dispute notifications

=item * B<ISignThis>, payments fraud and dispute notifications

=back

=cut

sub startup {
    my ($self) = @_;
    $self->moniker('binary_webhook');
    $self->plugin('Config' => {file => '/etc/rmg/binary_webhook.conf'}) if -e '/etc/rmg/binary_webhook.conf';
    $log->info('Starting the webhook service');

    my $routes = {
        '/acquired'  => 'acquired#collect',
        '/isignthis' => 'i_sign_this#collect',
    };

    for (keys $routes->%*) {
        $self->routes->post($_)->to($routes->{$_});
        $self->routes->get($_)->to($routes->{$_});
    }
}

1;
