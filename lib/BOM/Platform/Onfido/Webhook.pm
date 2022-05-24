package BOM::Platform::Onfido::Webhook;

use strict;
use warnings;
use BOM::Platform::Onfido::Webhook::Check;
use Log::Any qw($log);

use parent qw(Mojolicious);

=head2 startup

Sets the Mojolicious configuration and routing to serve our Onfido webhook handle.

=cut

sub startup {
    my ($self) = @_;
    $self->moniker('onfido_webhook');
    $self->plugin('Config' => {file => '/etc/rmg/onfido_webhook.conf'}) if -e '/etc/rmg/onfido_webhook.conf';
    $log->infof('Starting webhook handler');
    $self->routes->post('/')->to('check#check');
    $self->routes->get('/')->to('check#check');
}

1;
