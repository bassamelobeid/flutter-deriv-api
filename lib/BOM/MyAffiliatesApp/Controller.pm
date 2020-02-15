package BOM::MyAffiliatesApp::Controller;

use Mojo::Base 'Mojolicious::Controller';
use Date::Utility;
use Path::Tiny;

use BOM::MyAffiliates::ActivityReporter;
use BOM::MyAffiliates::TurnoverReporter;
use BOM::MyAffiliates::GenerateRegistrationDaily;
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

    my ($file_name, $file_path);
    if ($type eq 'activity_report') {
        my $reporter = BOM::MyAffiliates::ActivityReporter->new(
            brand           => Brands->new(name => $c->stash('brand')),
            processing_date => Date::Utility->new($date));
        $file_name = $reporter->output_file_name();
        $file_path = $reporter->output_file_path();
    } elsif ($type eq 'registration') {
        my $reporter = BOM::MyAffiliates::GenerateRegistrationDaily->new(
            brand           => Brands->new(name => $c->stash('brand')),
            processing_date => Date::Utility->new($date));
        $file_name = $reporter->output_file_name();
        $file_path = $reporter->output_file_path();
    } elsif ($type eq 'turnover_report') {
        my $reporter = BOM::MyAffiliates::TurnoverReporter->new(
            brand           => Brands->new(name => $c->stash('brand')),
            processing_date => Date::Utility->new($date));
        $file_name = $reporter->output_file_name();
        $file_path = $reporter->output_file_path();
    } else {
        return $c->__bad_request("Invalid request");
    }

    unless (-f -r $file_path) {
        return $c->__bad_request("No data for date: $date");
    }

    # Set response headers
    my $headers = $c->res->content->headers();
    $headers->add('Content-Type',        'application/octet-stream ;name=' . $file_name);
    $headers->add('Content-Disposition', 'inline; filename=' . $file_name);

    my $asset = Mojo::Asset::File->new(path => $file_path);
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
