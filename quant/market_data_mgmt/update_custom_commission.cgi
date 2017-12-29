#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];
use lib qw(/home/git/regentmarkets/bom-backoffice /home/git/regentmarkets/bom/cgi/oop);

use JSON::MaybeXS;
use BOM::Backoffice::Sysinit ();
use BOM::Backoffice::CustomCommissionTool;
BOM::Backoffice::Sysinit::init();
my $json = JSON::MaybeXS->new;

my $args = {
    name              => request()->param('name'),
    currency_symbol   => request()->param('currency_symbol'),
    underlying_symbol => request()->param('underlying_symbol'),
    bias              => request()->param('bias'),
    cap_rate          => request()->param('cap_rate'),
    floor_rate        => request()->param('floor_rate'),
    width             => request()->param('width'),
    centre_offset     => request()->param('centre_offset'),
    flat              => request()->param('flat'),
    start_time        => request()->param('start_time'),
    end_time          => request()->param('end_time'),
    partition_range   => request()->param('partition_range'),
};

if (request()->param('save_config')) {
    print $json->encode(BOM::Backoffice::CustomCommissionTool::save_commission($args));
}

if (request()->param('draw_chart')) {
    print $json->encode(BOM::Backoffice::CustomCommissionTool::get_chart_params($args));
}

if (request()->param('delete_config')) {
    print $json->encode(BOM::Backoffice::CustomCommissionTool::delete_commission($args->{name}));
}
