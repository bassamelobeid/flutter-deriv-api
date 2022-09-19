package BOM::Platform::CryptoWebhook::Webhook;

use DataDog::DogStatsd::Helper qw(stats_timing);
use Mojo::Base 'Mojolicious';
use Log::Any qw($log);
use Time::HiRes;

use constant {
    CALL_START_TIME  => "call_start_time",
    DD_METRIC_PREFIX => 'bom_platform.crypto_webhook.',
};

=head2 startup

Sets the Mojolicious configuration and routing.

=cut

sub startup {
    my $app = shift;

    $app->plugin('Config' => {file => '/etc/rmg/crypto_webhook.conf'}) if -e '/etc/rmg/crypto_webhook.conf';

    $log->infof('Starting Crypto Webhook');

    $app->plugin('DefaultHelpers');

    $app->hook(
        before_dispatch => sub {
            # Save the time in stash to calculate processing duration later
            shift->stash(CALL_START_TIME, Time::HiRes::time);
        });

    $app->hook(
        after_dispatch => sub {
            generate_metrics_after_dispatch(shift);
        });

    my $r = $app->routes;
    $r->post('/api/v1/coinspaid')->to('Controller#processor_coinspaid');

    $r->any('/')->to('Controller#invalid_request');
    $r->any('/*')->to('Controller#invalid_request');
}

=head2 generate_metrics_after_dispatch

Calculate various metrics after processing an api request

=over 4

=item * C<c> - A L<Mojolicious::Controller> object containing request data

=back

=cut

sub generate_metrics_after_dispatch {
    my $c          = shift;
    my $origin     = $c->req->headers->origin // '';
    my $code       = $c->res->code            // '0';
    my $start_time = $c->stash(CALL_START_TIME);
    my $endpoint   = $c->stash('action') // '';

    my $elapsed_ms = Time::HiRes::tv_interval([$start_time]) * 1000;
    my $tags       = ['origin:' . $origin, 'code:' . $code, 'endpoint:' . $endpoint,];

    stats_timing(DD_METRIC_PREFIX . 'call', $elapsed_ms, {tags => $tags});
}

1;
