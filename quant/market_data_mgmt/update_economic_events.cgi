#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];
use lib qw(/home/git/regentmarkets/bom-backoffice /home/git/regentmarkets/bom/cgi/oop);

use JSON::MaybeXS;
use BOM::Backoffice::Sysinit ();
use BOM::Backoffice::EconomicEventTool;
use BOM::Backoffice::PricePreview;
use BOM::Backoffice::Auth0;
BOM::Backoffice::Sysinit::init();
my $staff = BOM::Backoffice::Auth0::get_staffname();
my $json  = JSON::MaybeXS->new;
## Updates economic event list
if (request()->param('get_event')) {
    print $json->encode(BOM::Backoffice::EconomicEventTool::get_economic_events_for_date(request()->param('date')));
}

## Delete economic event
if (request()->param('delete_event')) {
    print $json->encode(BOM::Backoffice::EconomicEventTool::delete_by_id(request()->param('event_id'), $staff));
}

if (request()->param('restore_event')) {
    print $json->encode(BOM::Backoffice::EconomicEventTool::restore_by_id(request()->param('event_id'), request()->param('type'), $staff));
}

## Update with custom magnitude
if (request()->param('update_event')) {
    my $args =
        {map { $_ => request()->param($_) } qw/id vol_change duration decay_factor vol_change_before duration_before decay_factor_before underlying/};
    $args->{staff} = $staff;
    print $json->encode(BOM::Backoffice::EconomicEventTool::update_by_id($args));
}

## Add new economic event
if (request()->param('save_event')) {
    my $param = {
        symbol       => request()->param('symbol'),
        impact       => request()->param('impact'),
        event_name   => request()->param('event_name'),
        source       => request()->param('source'),
        release_date => request()->param('release_date'),
    };
    print $json->encode(BOM::Backoffice::EconomicEventTool::save_new_event($param, $staff));
}

if (request()->param('compare_price_preview')) {
    my $args->{event} =
        {map { $_ => request()->param($_) } qw/id vol_change duration decay_factor vol_change_before duration_before decay_factor_before underlying/};
    $args->{symbol}        = request()->param('compare_symbol');
    $args->{pricing_date}  = request()->param('compare_date');
    $args->{expiry_option} = request()->param('compare_expiry_option');
    print $json->encode(BOM::Backoffice::PricePreview::update_price_preview($args));
}
