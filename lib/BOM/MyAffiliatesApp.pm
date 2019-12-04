package BOM::MyAffiliatesApp;

use Mojo::Base 'Mojolicious';

use Date::Utility;
use BOM::Config;
use BOM::Config::Runtime;

sub startup {
    my $app = shift;

    $app->plugin('Config' => {file => $ENV{MYAFFILIATES_CONFIG} || '/etc/rmg/myaffiliates.conf'});

    my $log = $app->log;

    # announce startup and context in logfile
    $log->warn("BOM-MyAffiliates: Starting.");
    $log->warn("Mojolicious Mode is " . $app->mode);
    $log->warn("Log Level        is " . $log->level);

    $app->plugin('DefaultHelpers');

    my $r = $app->routes;
    $r->get('/activity_report')->to('Controller#activity_report');
    $r->get('/registration')->to('Controller#registration');
    $r->get('/turnover_report')->to('Controller#turnover_report');

    return;
}

1;
