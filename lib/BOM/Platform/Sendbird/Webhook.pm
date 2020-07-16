package BOM::Platform::Sendbird::Webhook;

use strict;
use warnings;
use Log::Any::Adapter qw(Stderr), log_level => $ENV{SENDBIRD_LOG_LEVEL} // 'info';
use BOM::Platform::Sendbird::Webhook::Collector;
use Log::Any qw($log);

use parent qw(Mojolicious);

sub startup {
    my ($self) = @_;
    $self->moniker('sendbird_webhoook');
    $self->plugin('Config' => {file => '/etc/rmg/sendbird_webhook.conf'}) if -e '/etc/rmg/sendbird_webhook.conf';
    $log->infof('Starting webhook handler');
    $self->routes->post('/')->to('collector#collect');
    $self->routes->get('/')->to('collector#collect');
}

1;
