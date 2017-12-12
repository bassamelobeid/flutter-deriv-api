#!/etc/rmg/bin/perl

=head1 NAME

Contract's pricing details

=head1 DESCRIPTION

A b/o tool that output contract's pricing parameters that will be used to replicate the contract price with an excel template.
This is a Japanese regulatory requirements.

=cut

package main;
use strict;
use warnings;
no warnings 'uninitialized';    ## no critic (ProhibitNoWarnings) # TODO fix these warnings

use lib qw(/home/git/regentmarkets/bom-backoffice);
use f_brokerincludeall;
use BOM::Backoffice::PlackHelpers qw( PrintContentType);
use BOM::Backoffice::Request;
use BOM::Backoffice::Sysinit ();

use BOM::Database::DataMapper::Transaction;
use LandingCompany::Registry;
BOM::Backoffice::Sysinit::init();
use BOM::Platform::Runtime;
use BOM::Pricing::JapanContractDetails;
use BOM::JapanContractDetailsOutput;
use Data::Dumper;
my %params = %{request()->params};

my $cgi = CGI->new;
my $broker = $params{'broker'} // $cgi->param('broker');
code_exit_BO("No broker provided") unless $broker;
my $landing_company = LandingCompany::Registry::get_by_broker($broker)->short;

if ($cgi->param('upload_file')) {
    my $file     = $cgi->param('filetoupload');
    my $fh       = File::Temp->new(SUFFIX => '.csv');
    my $filename = $fh->filename;
    copy($file, $filename);
    my $output_filename = $file;
    $output_filename =~ s/\.csv$/.xlsx/;
    my $pricing_parameters = BOM::Pricing::JapanContractDetails::parse_file($filename, $landing_company);
    BOM::JapanContractDetailsOutput::batch_output_as_excel($pricing_parameters, $output_filename);

} elsif ($cgi->param('manual_verify_with_id')) {
    my $args;
    my $id = $cgi->param('id');
    $args->{transaction_id}  = $id;
    $args->{landing_company} = $landing_company;
    $args->{broker}          = $broker;

    my $details = BOM::Database::DataMapper::Transaction->new({
            broker_code => $broker,
            operation   => 'backoffice_replica',
        })->get_details_by_transaction_ref($id);
    $args->{details} = $details;

    my $pricing_parameters = BOM::Pricing::JapanContractDetails::verify_with_id($args);
    print $pricing_parameters->{error} and return if exists $pricing_parameters->{error};
    if (exists $pricing_parameters->{contract_details}->{description}) {
        $pricing_parameters->{contract_details}->{description} =
            BOM::Backoffice::Request::localize($pricing_parameters->{contract_details}->{description});
    }

    if ($cgi->param('download') eq 'download') {
        BOM::JapanContractDetailsOutput::single_output_as_excel($pricing_parameters, $id . '.xlsx');

    } else {
        load_template($cgi->param('broker'), $pricing_parameters);

    }
} elsif ($params{'load_template'}) {

    load_template($params{broker});

}

sub load_template {
    my $broker             = shift;
    my $pricing_parameters = shift;

    PrintContentType();
    BrokerPresentation("Price Verification Tool");
    Bar("Tools");

    BOM::Backoffice::Request::template->process(
        'backoffice/japan_contract_details.html.tt',
        {
            broker             => $broker,
            pricing_parameters => $pricing_parameters,
            upload_url         => 'contract_details.cgi',
        }) || die BOM::Backoffice::Request::template->error;
    return;
}

code_exit_BO();
