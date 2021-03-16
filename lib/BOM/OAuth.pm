package BOM::OAuth;

use Mojo::Base 'Mojolicious';

use Mojolicious::Plugin::ClientIP::Pluggable;

use BOM::Config;
use BOM::Platform::Context;
use BOM::Platform::Context::Request;
use BOM::Database::Rose::DB;
use Syntax::Keyword::Try;
use Log::Any qw($log);

sub startup {
    my $app = shift;

    $app->plugin('Config' => {file => $ENV{OAUTH_CONFIG} || '/etc/rmg/oauth.conf'});

    my $mojo_log = $app->log;

    $mojo_log->on(
        message => sub {
            my ($msg, $level, @lines) = @_;
            if ($msg) {
                if ($level eq 'info') {
                    $log->infof('%s: %s', $level, @lines);
                } elsif ($level eq 'error') {
                    $log->errorf('%s: %s', $level, @lines);
                } elsif ($level eq 'fatal') {
                    $log->fatalf('%s: %s', $level, @lines);
                } elsif ($level eq 'warn') {
                    $log->warnf('%s: %s', $level, @lines);
                } elsif ($level eq 'debug') {
                    $log->debugf('%s: %s', $level, @lines);
                } else {
                    $log->infof('%s: %s', $level, @lines);
                }
            }
        });

    # announce startup and context in logfile
    $mojo_log->warn("BOM-OAuth:            Starting.");
    $mojo_log->debug("Mojolicious Mode is " . $app->mode);
    $mojo_log->warn("Log Level        is " . $mojo_log->level);

    $app->plugin('DefaultHelpers');
    $app->plugin(
        'Mojolicious::Plugin::ClientIP::Pluggable',
        analyze_headers => [qw/cf-pseudo-ipv4 cf-connecting-ip true-client-ip/],
        restrict_family => 'ipv4',
        fallbacks       => [qw/rfc-7239 x-forwarded-for remote_address/]);
    $app->secrets([BOM::Config::aes_keys()->{web_secret}{1}]);

    $app->helper(
        l => sub {
            shift;
            return BOM::Platform::Context::localize(@_);
        });

    $app->helper(
        throw_error => sub {
            my ($c, $error_code, $error_description) = @_;

            ## use 200 for now since 400 will return an error page without message
            return $c->render(
                status => 200,    # 400,
                json   => {
                    error             => $error_code,
                    error_description => $error_description
                });
        });

    $app->hook(
        before_dispatch => sub {
            my $c = shift;

            my $request = BOM::Platform::Context::Request::from_mojo({mojo_request => $c->req});
            BOM::Platform::Context::request($request);
            $c->stash(request => $request);
            $c->stash(brand   => $request->brand);
        });

    $app->hook(
        after_dispatch => sub {
            try {
                BOM::Database::Rose::DB->db_cache->finish_request_cycle;
            } catch ($e) {
                warn "->finish_request_cycle: $e\n";
            }
        });

    my $r = $app->routes;
    $r->any('/authorize')->to('O#authorize');

    $r->any('/oneall/callback')->to('OneAll#callback');
    $r->any('/oneall/redirect')->to('OneAll#redirect');

    $r->any('session/:service/sso')->to('SingleSignOn#authorize');
    $r->any('session/:service/authorize')->to('SingleSignOn#create');

    $r->post('/api/v1/authorize')->to('RestAPI#authorize');
    $r->post('/api/v1/verify')->to('RestAPI#verify');
}

1;

=head1 NAME

bom-oauth

=head1 TEST

    # run all test scripts
    make test
    # run one script
    prove t/BOM/001_structure.t
    # run one script with perl
    perl -MBOM::Test t/BOM/001_structure.t
