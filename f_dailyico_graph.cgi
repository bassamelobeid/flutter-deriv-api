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
use BOM::Backoffice::PlackHelpers qw(PrintContentType_JSON);
use BOM::Backoffice::Request;
use BOM::Backoffice::Sysinit ();
use JSON qw(to_json);
BOM::Backoffice::Sysinit::init();
use BOM::RiskReporting::BinaryIco;
use BOM::Platform::Runtime;

try {
    my $data = BOM::RiskReporting::BinaryIco->new->generate_output_in_histogram;
    PrintContentType_JSON();
    print to_json($data);
}

catch { warn "Error $_"; };

code_exit_BO();
