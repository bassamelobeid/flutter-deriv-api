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
use BOM::Backoffice::PlackHelpers qw( PrintContentType PrintContentType_excel);
use BOM::Backoffice::Sysinit ();
use LandingCompany::Registry;
BOM::Backoffice::Sysinit::init();
BOM::Backoffice::Auth0::can_access(['Quants']);

my $cgi           = new CGI;
my $broker        = $cgi->param('broker');
my $landing_company = LandingCompany::Registry::get_by_broker($broker)->short;
if ($cgi->param('upload_file')) {
    my $file     = $cgi->param('filetoupload');
    my $fh       = File::Temp->new(SUFFIX => '.csv');
    my $filename = $fh->filename;
    copy($file, $filename);
    my $pricing_parameters = BOM::JapanContractDetails::parse_file($filename, $landing_company);
} elsif ($cgi->param('manual_verify_with_id')) {
    my $args;
    $args->{transaction_id} = $cgi->param('id');
    $args->{landing_company} = $landing_company;
    $args->{todo}           = $cgi->param('download') ? 'download' : 'price";
    my $pricing_parameters = BOM::JapanContractDetails::verify_with_id($args);
} elsif ($cgi->param('manual_verify_with_shortcode')) {
    my $args;
    $args->{landing_company} = $landing_company;
    $args->{shortcode} = $cgi->param('short_code');
    $args->{contract_price} = $cgi->param('ask_price');
    $args->{currency}  = $cgi->param('currency');
    $args->{start_time}  = $cgi->param('start');
    $args->{action_type} = 'buy'; #with shortcode , we only verify ask price
    my $pricing_parameters = BOM::JapanContractDetails::verify_with_shortcode($args);
}

code_exit_BO();
