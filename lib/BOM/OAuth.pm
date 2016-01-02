package BOM::OAuth;

use Mojo::Base 'Mojolicious';

use BOM::System::Config;
use BOM::Platform::Context;
use BOM::Platform::Context::Request;

sub startup {
    my $app = shift;

    # use the log target expected by the init.d starman runner script..
    $app->log(
        Mojo::Log->new(
            path  => $ENV{ERROR_LOG},
            level => ('warn'),
        )) unless $app->mode eq 'development';
    my $log = $app->log;

    # announce startup and context in logfile
    $log->warn("BOM-OAuth:            Starting.");
    $log->warn("Mojolicious Mode is " . $app->mode);
    $log->warn("Log Level        is " . $log->level);

    $app->plugin(charset => {charset => 'utf-8'});
    $app->secrets([BOM::System::Config::aes_keys->{web_secret}{1}]);

    $app->helper(
        throw_error => sub {
            my ($c, $error_code, $error_description) = @_;

            return $c->render(
                status => 400,
                json   => {
                    error             => $error_code,
                    error_description => $error_description
                });
        } );

    $app->hook(
        before_dispatch => sub {
            my $c = shift;

            my $request = BOM::Platform::Context::Request::from_mojo({mojo_request => $c->req});
            BOM::Platform::Context::request($request);
            $c->stash(request => $request);
        });

    my $r = $app->routes;
    $r->get('/oauth2/authorize')->to('O#authorize');
    $r->any('/oauth2/access_token')->to('O#access_token');
}

1;
