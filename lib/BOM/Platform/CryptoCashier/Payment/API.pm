package BOM::Platform::CryptoCashier::Payment::API;

use DataDog::DogStatsd::Helper qw(stats_inc stats_timing);
use Digest::HMAC;
use Digest::SHA1;
use Mojo::Base 'Mojolicious';
use Log::Any qw($log);
use Syntax::Keyword::Try;
use Time::HiRes;

use BOM::Database::Rose::DB;

use constant {
    CALL_START_TIME  => "call_start_time",
    DD_METRIC_PREFIX => 'bom_platform.crypto_cashier_paymentapi.',
};

=head2 startup

Sets the Mojolicious configuration and routing.

=cut

sub startup {
    my $app = shift;

    $app->plugin('Config' => {file => '/etc/rmg/crypto_cashier_paymentapi.conf'});

    $log->infof('Starting Crypto Cashier paymentapi');

    $app->plugin('DefaultHelpers');

    $app->hook(
        before_dispatch => sub {
            my $c = shift;

            # Save the time in stash to calculate processing duration later
            $c->stash(CALL_START_TIME, Time::HiRes::time);

            return $c->render(
                text   => 'Invalid signature.',
                status => 401
            ) unless validate_signature($c->req);

            if (my $json = $c->req->json) {
                $c->param($_ => $json->{$_}) for keys $json->%*;
            }
        });

    $app->hook(
        after_dispatch => sub {
            my $c = shift;

            try {
                BOM::Database::Rose::DB->db_cache->finish_request_cycle;
            } catch ($e) {
                warn "->finish_request_cycle: $e\n";
            }

            generate_metrics_after_dispatch($c);
        });

    my $r = $app->routes;
    $r->post('/v1/payment/deposit')->to('Controller#deposit');
    $r->post('/v1/payment/withdraw')->to('Controller#withdraw');
    $r->post('/v1/payment/revert_withdrawal')->to('Controller#revert_withdrawal');

    $r->any('/')->to('Controller#invalid_request');
    $r->any('/*')->to('Controller#invalid_request');
}

=head2 validate_signature

Compares the C<X-Signature> header from a request with the HMAC-SHA1 expected
header based on our secret key.

=over 4

=item C<Mojo::Message::Request> request object from crypto cashier

=back

Returns 1 if valid otherwise 0

=cut

sub validate_signature {
    my $req = shift;

    my $sig = $req->headers->header('X-Signature');
    unless ($sig) {
        stats_inc(DD_METRIC_PREFIX . 'no_signature');
        return 0;
    }

    my $secret_token = $ENV{CRYPTO_PAYMENT_API_SECRET_TOKEN} // die "The secret token is not defined!";
    my $expected     = do {
        my $digest = Digest::HMAC->new($secret_token, 'Digest::SHA1');
        $digest->add($req->body);
        $digest->hexdigest;
    };
    return 0 unless lc($sig) eq lc($expected);
    return 1;
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
    my $code       = $c->res->code;
    my $start_time = $c->stash(CALL_START_TIME);
    my $endpoint   = $c->stash('action') // '';

    my $elapsed_ms = Time::HiRes::tv_interval([$start_time]) * 1000;
    my $tags       = ['origin:' . $origin, 'code:' . $code, 'endpoint:' . $endpoint,];

    stats_timing(DD_METRIC_PREFIX . 'call', $elapsed_ms, {tags => $tags});
}

1;
