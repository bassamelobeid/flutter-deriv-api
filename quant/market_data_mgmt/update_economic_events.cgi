#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];
use lib qw(/home/git/regentmarkets/bom-backoffice /home/git/regentmarkets/bom/cgi/oop);

use JSON qw(to_json);
use BOM::Backoffice::Sysinit ();
use BOM::Backoffice::EconomicEventTool;
BOM::Backoffice::Sysinit::init();

## Updates economic event list
if (request()->param('get_event')) {
    print to_json(BOM::Backoffice::EconomicEventTool::get_economic_events_for_date(request()->param('date')));
}

## Delete economic event
if (request()->param('delete_event')) {
    print to_json(BOM::Backoffice::EconomicEventTool::delete_by_id(request()->param('event_id')));
}

if (request()->param('restore_event')) {
    print to_json(BOM::Backoffice::EconomicEventTool::restore_by_id(request()->param('event_id'), request()->param('type')));
}

## Update with custom magnitude
if (request()->param('update_event')) {
    my $args =
        {map { $_ => request()->param($_) } qw/id vol_change duration decay_factor vol_change_before duration_before decay_factor_before underlying/};
    print to_json(BOM::Backoffice::EconomicEventTool::update_by_id($args));
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
    print to_json(BOM::Backoffice::EconomicEventTool::save_new_event($param));
}
