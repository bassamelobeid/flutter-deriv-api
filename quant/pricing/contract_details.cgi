#!/etc/rmg/bin/perl

=head1 NAME

Contract's pricing details

=head1 DESCRIPTION

A b/o tool that output contract's pricing parameters that will be used to replicate the contract price with an excel template.
This is a Japanese regulatory requirements.

=cut

package main;

use lib qw(/home/git/regentmarkets/bom-backoffice);
use f_brokerincludeall;
use BOM::Backoffice::PlackHelpers qw( PrintContentType PrintContentType_excel PrintContentType_XSendfile);
use BOM::Backoffice::Sysinit ();
use LandingCompany::Registry;
BOM::Backoffice::Sysinit::init();
BOM::Backoffice::Auth0::can_access(['Quants']);
use BOM::Platform::Runtime;
use BOM::JapanContractDetails;
use Data::Dumper;
my %params = %{request()->params};

my $cgi             = new CGI;
my $broker          = $params{'broker'};
my $landing_company = LandingCompany::Registry::get_by_broker($broker)->short;

if ($cgi->param('upload_file')) {
    my $file     = $cgi->param('filetoupload');
    my $fh       = File::Temp->new(SUFFIX => '.csv');
    my $filename = $fh->filename;
    copy($file, $filename);
    my $output_filename = $file;
    $output_filename =~ s/.csv/.xls/g;
    my $temp_file = BOM::Platform::Runtime->instance->app_config->system->directory->tmp . "/$output_filename";
    my $pricing_parameters = BOM::JapanContractDetails::parse_file($filename, $landing_company);
    BOM::JapanContractDetails::batch_output_as_excel($pricing_parameters, $temp_file);
    PrintContentType_XSendfile($temp_file, 'application/octet-stream');

} elsif ($cgi->param('manual_verify_with_id')) {
    my $args;
    my $id = $cgi->param('id');
    $args->{transaction_id}  = $id;
    $args->{landing_company} = $landing_company;
    my $pricing_parameters = BOM::JapanContractDetails::verify_with_id($args);
    if ($cgi->param('download') eq 'download') {
        my $file = BOM::JapanContractDetails::batch_output_as_excel($pricing_parameters, $id . '.xls');

    } else {
        BOM::JapanContractDetails::output_on_display($pricing_parameters);

    }
} elsif ($cgi->param('manual_verify_with_shortcode')) {
    my $args;
    $args->{landing_company} = $landing_company;
    $args->{shortcode}       = $cgi->param('short_code');
    $args->{contract_price}  = $cgi->param('price');
    $args->{currency}        = $cgi->param('currency');
    $args->{start_time}      = $cgi->param('start');
    $args->{action_type}     = $cgi->param('action_type');
    my $pricing_parameters = BOM::JapanContractDetails::verify_with_shortcode($args);
    $pricing_parameters = include_contract_details(
        $parameters,
        {
            order_type  => $cgi->param('action_type'),
            order_price => $cgi->param('price')});

    if ($cgi->param('download') eq 'download') {
        my $file = BOM::JapanContractDetails::batch_output_as_excel($pricing_parameters, $cgi->param('short_code') . '.xls');

    } else {
        BOM::JapanContractDetails::output_on_display($pricing_parameters);

    }
} elsif ($params{'load_template'}) {

    PrintContentType();
    BrokerPresentation("Price Verification Tool");
    Bar("Tools");

    BOM::Backoffice::Request::template->process(
        'backoffice/japan_contract_details.html.tt',
        {
            broker     => $params{broker},
            upload_url => 'contract_details.cgi',
        }) || die BOM::Backoffice::Request::template->error;

}
code_exit_BO();
