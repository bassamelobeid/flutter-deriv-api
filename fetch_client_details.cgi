#!/etc/rmg/bin/perl
package main;

=head1 NAME
fetch_client_details.cgi
=head1 DESCRIPTION
Handles AJAX requests for client details.
=cut

use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];
use lib qw(/home/git/regentmarkets/bom-backoffice);

use JSON::MaybeXS;
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();
my $json = JSON::MaybeXS->new;

if (request()->param('fiat_details')) {
    my %fiat_details   = get_fiat_login_id_for(request()->param('login_id'), request()->param('broker_code'));
    my $fiat_loginid   = $fiat_details{fiat_loginid};
    my $fiat_link      = $fiat_details{fiat_link};
    my $fiat_statement = $fiat_details{fiat_statement};
    print $json->encode({
        loginid   => $fiat_loginid,
        link      => "$fiat_link",
        statement => "$fiat_statement"
    });
}
