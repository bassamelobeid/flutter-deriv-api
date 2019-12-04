package BOM::MyAffiliatesApp::Controller;

use Mojo::Base 'Mojolicious::Controller';
use Date::Utility;
use Path::Tiny;

use BOM::Config::Runtime;

sub activity_report {
    return shift->__send_file('activity_report');
}

sub registration {
    return shift->__send_file('registration');
}

sub turnover_report {
    return shift->__send_file('turnover_report');
}

sub __send_file {
    my ($c, $type) = @_;

    my $date = $c->param('date');

    return $c->__bad_request("Invalid date format. Format should be YYYY-MM-DD.") unless $date =~ /^\d{4}-\d{2}-\d{2}$/;

    $date or return $c->__bad_request('the request was missing date');

    my $path = BOM::Config::Runtime->instance->app_config->system->directory->db . '/myaffiliates/';
    Path::Tiny::path($path)->mkpath unless -d $path;

    my $filename;
    if ($type eq 'activity_report') {
        $filename = 'pl_';
    } elsif ($type eq 'registration') {
        $filename = 'registrations_';
    } elsif ($type eq 'turnover_report') {
        $filename = 'turnover_';
    } else {
        return $c->__bad_request("Invalid request");
    }

    $filename = $filename . Date::Utility->new({datetime => $date})->date_yyyymmdd . '.csv';

    unless (-f -r $path . $filename) {
        return $c->__bad_request("No data for date: $date");
    }

    # Set response headers
    my $headers = $c->res->content->headers();
    $headers->add('Content-Type',        'application/octet-stream ;name=' . $filename);
    $headers->add('Content-Disposition', 'inline; filename=' . $filename);

    my $asset = Mojo::Asset::File->new(path => $path . $filename);
    $c->res->content->asset($asset);

    return $c->rendered(200);
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
