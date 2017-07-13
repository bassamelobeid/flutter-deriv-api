#!/etc/rmg/bin/perl

=head1 NAME

=head1 DESCRIPTION

A BO tool to output the open ico on excel or display as histogram 

=cut

package main;
use strict;
use warnings;
use Try::Tiny;

use lib qw(/home/git/regentmarkets/bom-backoffice);
use f_brokerincludeall;
use BOM::Backoffice::PlackHelpers qw( PrintContentType);
use BOM::Backoffice::Request;
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();
BOM::Backoffice::Auth0::can_access(['Quants']);
use BOM::RiskReporting::BinaryIco;
 
if (request()->param('download_csv')) {
    my $res;
    try {
        $res = BOM::RiskReporting::BinaryIco->new->generate_output_in_csv;
    }
    catch { warn "Error $_"; };
    return $res;

}
    PrintContentType();
    BrokerPresentation("Open ICO deals");
    Bar("Tools");
    BOM::Backoffice::Request::template->process(
        'backoffice/ico.html.tt',
        {
            upload_url => 'f_dailyico.cgi',
        }) || die BOM::Backoffice::Request::template->error;
    return ;


code_exit_BO();
