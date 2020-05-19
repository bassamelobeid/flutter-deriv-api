#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];
use lib qw(/home/git/regentmarkets/bom-backoffice /home/git/regentmarkets/bom/cgi/oop);

use JSON::MaybeUTF8 qw(encode_json_utf8);
use BOM::Backoffice::Sysinit ();
use BOM::Backoffice::EconomicEventPricePreview;
BOM::Backoffice::Sysinit::init();

if (request()->param('update_economic_event_price_preview')) {
    my %args = (
        date              => request->param('date'),
        underlying_symbol => request()->param('underlying_symbol'),
        event_timeframe   => request()->param('event_timeframe'),
        event_type        => request()->param('event_type'),
        event_name        => request()->param('event_name'),
        event_parameter_change =>
            {map { $_ => request()->param($_) } qw/vol_change duration decay_factor vol_change_before duration_before decay_factor_before/});
    print encode_json_utf8(BOM::Backoffice::EconomicEventPricePreview::update_economic_event_price_preview(\%args));
}
