#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];
use lib qw(/home/git/regentmarkets/bom-backoffice /home/git/regentmarkets/bom/cgi/oop);

use JSON qw(to_json);
use BOM::Backoffice::Sysinit ();
use BOM::Backoffice::CustomCommissionTool;
BOM::Backoffice::Sysinit::init();

my $args = {
    name              => request()->param('name'),
    currency_symbol   => request()->param('currency_symbol'),
    underlying_symbol => request()->param('underlying_symbol'),
    contract_type     => request()->param('contract_type'),
    cap_rate          => request()->param('cap_rate'),
    floor_rate        => request()->param('floor_rate'),
    width             => request()->param('width'),
    center_offset     => request()->param('center_offset'),
    flat              => request()->param('flat'),
};

if (request()->param('save_config')) {
    print to_json(BOM::Backoffice::CustomCommissionTool::save_commission($args));
}

if (request()->param('draw_chart')) {
    print to_json(BOM::Backoffice::CustomCommissionTool::get_chart_params($args));
}

if (request()->param('delete_config')) {
    print to_json(BOM::Backoffice::CustomCommissionTool::delete_commission($args->{name}));
}
