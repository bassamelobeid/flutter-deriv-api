package BOM::OAuth;

use Mojo::Base 'Mojolicious';

use Brands;

use BOM::Config;
use BOM::Platform::Context;
use BOM::Platform::Context::Request;
use BOM::Database::Rose::DB;
use Try::Tiny;

sub startup {
    my $app = shift;

    $app->plugin('Config' => {file => $ENV{OAUTH_CONFIG} || '/etc/rmg/oauth.conf'});

    my $log = $app->log;

    # announce startup and context in logfile
    $log->warn("BOM-OAuth:            Starting.");
    $log->warn("Mojolicious Mode is " . $app->mode);
    $log->warn("Log Level        is " . $log->level);

    $app->plugin('DefaultHelpers');
    $app->plugin('ClientIP');
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
            $c->stash(brand => Brands->new(name => ($request->brand // 'binary')));
        });

    $app->hook(
        after_dispatch => sub {
            try { BOM::Database::Rose::DB->db_cache->finish_request_cycle; } catch { warn "->finish_request_cycle: $_\n" };
        });

    my $r = $app->routes;
    $r->any('/authorize')->to('O#authorize');

    $r->any('/oneall/callback')->to('OneAll#callback');
    $r->any('/oneall/redirect')->to('OneAll#redirect');
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