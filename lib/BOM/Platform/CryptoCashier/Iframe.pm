package BOM::Platform::CryptoCashier::Iframe;

use BOM::Config;
use BOM::Database::Rose::DB;
use BOM::Platform::Context;
use BOM::Platform::Context::Request;
use LandingCompany::Registry;

use Log::Any qw($log);
use Mojo::Base 'Mojolicious';
use Mojo::Log;
use Time::HiRes;

use constant {
    CALL_START_TIME        => "call_start_time",
    DD_API_CALL_TIMING_KEY => "bom_platform.cryptocashier.iframe.call.timing",
};

sub startup {
    my $app = shift;

    $app->sessions->secure(1);
    $app->sessions->samesite('None');

    $app->plugin('Config' => {file => $ENV{CTC_CONFIG} || '/etc/rmg/cryptocurrency.conf'});

    # announce startup and context in logfile
    $log->warn("BOM::Platform::CryptoCashier::Iframe:                Starting.");
    $log->warn("Mojolicious Mode is " . $app->mode);

    $app->plugin('DefaultHelpers');
    $app->plugin('ClientIP');
    $app->secrets([BOM::Config::aes_keys()->{web_secret}{1}]);

    $app->helper(
        l => sub {
            shift;
            return BOM::Platform::Context::localize(@_);
        });

    # to allow us to change the renderer path on each request
    $app->renderer->cache->max_keys(0);

    $app->hook(
        before_dispatch => sub {
            my $c = shift;

            my $request = BOM::Platform::Context::Request::from_mojo({mojo_request => $c->req});
            BOM::Platform::Context::request($request);
            $c->stash(request => $request);

            my $template_dir = '/home/git/regentmarkets/bom-platform/templates/crypto_cashier/' . $request->brand->name;
            $c->app->renderer->paths([$template_dir]);

            # Save the time in stash to calculate processing duration later
            $c->stash(CALL_START_TIME, Time::HiRes::time);
        });

    $app->hook(
        after_dispatch => sub {
            my $c = shift;

            BOM::Database::Rose::DB->db_cache->finish_request_cycle;

            generate_metrics_after_dispatch($c);
        });

    my @crypto_currencies = map { lc } LandingCompany::Registry::all_crypto_currencies();

    my $r = $app->routes;
    $r->any('/')->to('Controller#notfound');

    $r->get('/:currency/handshake' => [currency => [@crypto_currencies]])->to('Controller#handshake');
    $r->any('/:currency/deposit'  => [currency => [@crypto_currencies]])->to('Controller#deposit');
    $r->any('/:currency/withdraw' => [currency => [@crypto_currencies]])->to('Controller#withdraw');
    $r->post('/:currency/cancel_withdraw' => [currency => [@crypto_currencies]])->to('Controller#cancel_withdraw');

    $r->any('/*')->to('Controller#notfound');
}

=head2 generate_metrics_after_dispatch

Calculate various metrics after processing an api request

=over 4

=item * C<c> - A L<Mojolicious::Controller> object containing request data

=back

=cut

sub generate_metrics_after_dispatch {

    my $c          = shift;
    my $endpoint   = $c->stash('action') // "";
    my $app_id     = $c->param('app_id') || -1;
    my $origin     = $c->param('brand') // "";
    my $start_time = $c->stash(CALL_START_TIME);

    # skip for static resource request. Ex - endpoint: app_id:-1 origin: uri:/js/withdraw_02.js
    return unless ($endpoint && $start_time && $app_id > 0 && $origin);

    my $elapsed_ms = Time::HiRes::tv_interval([$start_time]) * 1000;
    my @tags       = ("endpoint:$endpoint", "app_id:$app_id", "origin:$origin");

    DataDog::DogStatsd::Helper::stats_timing(DD_API_CALL_TIMING_KEY, $elapsed_ms, {tags => \@tags});
}

1;
