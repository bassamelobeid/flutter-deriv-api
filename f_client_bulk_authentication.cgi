#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use Date::Utility;
use HTML::Entities;

use f_brokerincludeall;
use BOM::Platform::Event::Emitter;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use Syntax::Keyword::Try;

BOM::Backoffice::Sysinit::init();

my $result;
my $cgi           = CGI->new;
my $input         = request()->params;
my $staff         = BOM::Backoffice::Auth0::get_staffname();
my $bulk_auth_btn = $input->{bulk_auth_btn} // '';

my $poi_reason             = $input->{poi_reason};
my $client_authentication  = $input->{client_authentication};
my $bulk_upload            = $input->{bulk_authentication_file};
my $staff_department       = $input->{staff_department};
my $comment                = $input->{comment};
my $csrf                   = BOM::Backoffice::Form::get_csrf_token();
my $to_email               = $staff . '@deriv.com';
my $allow_poi_resubmission = 0;

PrintContentType();

BrokerPresentation("Client Authentication");
Bar("Bulk Authentication");
BOM::Backoffice::Request::template()->process(
    'backoffice/bulk_authentication.html.tt',
    {
        input                  => $input,
        csrf                   => $csrf,
        allow_poi_resubmission => $allow_poi_resubmission,
        to_email               => $to_email,
    });

if ($bulk_auth_btn eq "Bulk Authentication" && request()->http_method eq 'POST') {
    my $msg = "";
    my ($file, $csv, $lines);

    # # if resubmission is checked use 1 as value else use 0
    $allow_poi_resubmission = 1 if defined $input->{allow_poi_resubmission};

    code_exit_BO(_display_error_message("ERROR: Invalid CSRF Token"))
        unless ($input->{csrf} // '') eq $csrf;
    code_exit_BO(_display_error_message("ERROR: Please provide login IDs file"))
        unless $bulk_upload;
    code_exit_BO(_display_error_message("ERROR: $bulk_upload: only csv files allowed\n"))
        unless $bulk_upload =~ /(csv)$/i;
    code_exit_BO(_display_error_message("ERROR: Please choose at least one of Allow POI Resubmission or ID Authentication."))
        if not $allow_poi_resubmission and not $client_authentication;
    code_exit_BO(_display_error_message("ERROR: Please select your department."))
        unless $staff_department;

    # Start authentication for a list of client
    try {
        $file  = $cgi->upload('bulk_authentication_file');
        $csv   = Text::CSV->new();
        $lines = $csv->getline_all($file);

        ## In order to avoid too many data, we set this limitation for protection, the 200 is just a guess
        my @loginids = map { $_->@* } $lines->@*;
        code_exit_BO(_display_error_message("ERROR: File should contain less than 200 login IDs")) unless @loginids <= 200;

        BOM::Platform::Event::Emitter::emit(
            'bulk_authentication',
            {
                data                   => $lines,
                client_authentication  => $client_authentication,
                allow_poi_resubmission => $allow_poi_resubmission,
                poi_reason             => $poi_reason,
                staff                  => $staff,
                staff_ip               => request()->client_ip,
                to_email               => $to_email,
                staff_department       => $staff_department,
                comment                => $comment,
            });
        $msg = 'Bulk authentication ' . $bulk_upload . " is being processed. An email with the results will be sent when the job completes.";
        print(_display_success_message($msg));
    } catch ($e) {
        code_exit_BO(_display_error_message("ERROR: " . $e));
    }
}

sub _display_success_message {
    my $message = shift;
    return "<p class='customSuccess center'>$message</p>";
}

sub _display_error_message {
    my $message = shift;
    return "<p class='error'>$message</p>";
}

code_exit_BO();
