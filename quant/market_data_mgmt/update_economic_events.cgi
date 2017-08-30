#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];
use lib qw(/home/git/regentmarkets/bom-backoffice /home/git/regentmarkets/bom/cgi/oop);

use JSON qw(to_json);
use BOM::Backoffice::Sysinit ();
use BOM::EconomicEventTool;
BOM::Backoffice::Sysinit::init();

## Updates economic event list

if (request()->param('get_event')) {
    print to_json(BOM::EconomicEventTool::get_economic_events_for_date(request()->param('date')));
}

## Delete economic event
if (request()->param('delete_event')) {
    print to_json(BOM::EconomicEventTool::delete_by_id(request()->param('event_id')));
}

## Update with custom magnitude
if (request()->param('update_event')) {
    my $args = {
        id               => request()->param('event_id'),
        custom_magnitude => request()->param('custom_magnitude'),
    };
    print to_json(BOM::EconomicEventTool::update_by_id($args));
}

## Restore deleted economic event
if (request()->param('restore_event')) {
    my $args = {
        id => request()->param('event_id'),
    };
    print to_json(BOM::EconomicEventTool::restore_by_id($args));
}

## Add new economic event
if (request()->param('save_event')) {
    my $param = {
        symbol                 => request()->param('symbol'),
        impact                 => request()->param('impact'),
        event_name             => request()->param('event_name'),
        source                 => request()->param('source'),
        is_tentative           => (request()->param('is_tentative') || 0),
        estimated_release_date => (request()->param('estimated_release_date') || 0),
        release_date           => (request()->param('release_date') || 0),
    };
    print to_json(BOM::EconomicEventTool::save_new_event($param));
}
