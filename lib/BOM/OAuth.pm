package BOM::OAuth;

use Mojo::Base 'Mojolicious';

use BOM::System::Config;
use BOM::Platform::Context;
use BOM::Platform::Context::Request;

sub startup {
    my $app = shift;

    $app->plugin('Config' => {file => $ENV{OAUTH_CONFIG} || '/etc/rmg/oauth.conf'});

    my $log = $app->log;

    # announce startup and context in logfile
    $log->warn("BOM-OAuth:            Starting.");
    $log->warn("Mojolicious Mode is " . $app->mode);
    $log->warn("Log Level        is " . $log->level);

    $app->plugin(charset => {charset => 'utf-8'});
    $app->plugin('DefaultHelpers');
    $app->secrets([BOM::System::Config::aes_keys->{web_secret}{1}]);

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
        });

    my $r = $app->routes;
    $r->any('/authorize')->to('O#authorize');
    $r->any('/login')->to('O#login');
    # $r->any('/access_token')->to('O#access_token');
}

1;
