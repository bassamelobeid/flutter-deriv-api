#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];
use lib  qw(/home/git/regentmarkets/bom-backoffice /home/git/regentmarkets/bom/cgi/oop);

use JSON::MaybeXS;
use BOM::Backoffice::Sysinit ();
use BOM::Backoffice::PricePreview;
BOM::Backoffice::Sysinit::init();
my $json = JSON::MaybeXS->new;

if (request()->param('update_price_preview')) {
    my %args = (
        symbol        => request()->param('symbol'),
        pricing_date  => request()->param('pricing_date'),
        expiry_option => request()->param('expiry_option'),
    );
    print $json->encode(BOM::Backoffice::PricePreview::update_price_preview(\%args));
}
