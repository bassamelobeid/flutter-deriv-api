package BOM::MyAffiliatesApp;

use Mojo::Base 'Mojolicious';

use Date::Utility;
use Path::Tiny;
use BOM::System::Config;
use BOM::Platform::Context;
use BOM::Platform::Context::Request;
use BOM::Platform::Runtime;

sub startup {
    my $app = shift;

    $app->plugin('Config' => {file => $ENV{MYAFFILIATES_CONFIG} || '/etc/rmg/myaffiliates.conf'});

    my $log = $app->log;

    # announce startup and context in logfile
    $log->warn("BOM-MyAffiliates: Starting.");
    $log->warn("Mojolicious Mode is " . $app->mode);
    $log->warn("Log Level        is " . $log->level);

    $app->plugin(charset => {charset => 'utf-8'});
    $app->plugin('DefaultHelpers');
    $app->secrets([BOM::System::Config::aes_keys->{web_secret}{1}]);

    $app->hook(
        before_dispatch => sub {
            my $c = shift;

            my $request = BOM::Platform::Context::Request::from_mojo({mojo_request => $c->req});
            BOM::Platform::Context::request($request);
            $c->stash(request => $request);
        });

    my $r = $app->routes;
    $r->get('/activity_report')->to('#activity_report');
    $r->get('/registration')->to('#registration');
}

sub activity_report {
    my $c = shift;

    my $date = $c->param('date');
    $date or return $c->__bad_request('the request was missing date');

    my $path = BOM::Platform::Runtime->instance->app_config->system->directory->db . '/myaffiliates';
    Path::Tiny::path($path)->mkpath unless -d $path;

    my $filename = $path . '/pl_' . Date::Utility->new({datetime => $date})->date_yyyymmdd . '.csv';
    unless (-f -r $filename) {
        return $c->__bad_request("No data for date: $date");
    }

    my $asset = Mojo::Asset::File->new(path => $filename);

    # Set response headers
    my $headers = $c->res->content->headers();
    $headers->add( 'Content-Type', 'application/octet-stream ;name=' . $filename );
    $headers->add( 'Content-Disposition', 'inline; filename=' . $filename );

    $c->res->content->asset($asset);
    return $c->rendered(200);
}

sub registration {

}

sub __bad_request {
    my ($c, $error) = @_;

    return $c->render(
        status => 200,    # 400,
        json   => {
            error             => 'invalid_request',
            error_description => $error
        });
}

1;
