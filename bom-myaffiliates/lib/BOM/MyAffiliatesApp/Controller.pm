package BOM::MyAffiliatesApp::Controller;

use Mojo::Base 'Mojolicious::Controller';
use Date::Utility;
use Path::Tiny;

use BOM::MyAffiliates::ActivityReporter;
use BOM::MyAffiliates::TurnoverReporter;
use BOM::MyAffiliates::GenerateRegistrationDaily;
use BOM::MyAffiliates::LookbackReporter;
use BOM::MyAffiliates::CombinedReporter;
use BOM::Config::Runtime;

=head2 activity_report

Returns myaffiliates activity pnl report.

=cut

sub activity_report {
    return shift->__send_file('activity_report');
}

=head2 registration

Returns myaffiliates registration  pnl report.

=cut

sub registration {
    return shift->__send_file('registration');
}

=head2 turnover_report

Returns myaffiliates turnover report.

=cut

sub turnover_report {
    return shift->__send_file('turnover_report');
}

=head2 multiplier_report

Returns myaffiliates combined commission report.

=cut

sub multiplier_report {
    return shift->__send_file('combined_report');
}

=head2 lookback_report

Returns myaffiliates looback commission report.

=cut

sub lookback_report {
    return shift->__send_file('lookback_report');
}

sub __send_file {
    my ($c, $type) = @_;

    my $date = $c->param('date');
    return $c->__bad_request("Invalid date format. Format should be YYYY-MM-DD.") unless $date =~ /^\d{4}-\d{2}-\d{2}$/;
    $date or return $c->__bad_request('the request was missing date');

    my ($report_class, $contract_category);

    my %report_mapping = (
        'activity_report' => {class => 'ActivityReporter'},
        'registration'    => {class => 'GenerateRegistrationDaily'},
        'turnover_report' => {class => 'TurnoverReporter'},
        'combined_report' => {class => 'CombinedReporter'},
        'lookback_report' => {class => 'LookbackReporter'});

    if (exists $report_mapping{$type}) {
        $report_class      = $report_mapping{$type}{class};
        $contract_category = $report_mapping{$type}{category} // undef;

    } else {
        return $c->__bad_request("Invalid request");
    }

    my $reporter = "BOM::MyAffiliates::$report_class"->new(
        brand           => Brands->new(name => $c->stash('brand')),
        processing_date => Date::Utility->new($date),
        (defined $contract_category ? (contract_category => $contract_category) : ()));

    my $file_name = $reporter->output_file_name();
    my $file_path = $reporter->output_file_path();

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
