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

if (request()->param('save_config')) {
    my $args = {
        name              => request()->param('name'),
        currency_symbol   => request()->param('currency_symbol'),
        underlying_symbol => request()->param('underlying_symbol'),
        support_from      => request()->param('support_from'),
        support_to        => request()->param('support_to'),
        contract_type     => request()->param('contract_type'),
        cap_rate          => request()->param('cap_rate'),
        floor_rate        => request()->param('floor_rate'),
        width             => request()->param('width'),
        center_offset     => request()->param('center_offset'),
    };
    print to_json(BOM::Backoffice::CustomCommissionTool::save_commission($args));
}

if (request()->param('delete_config')) {
    print to_json(BOM::Backoffice::CustomCommissionTool::delete_commission(request()->param('name')));
}
