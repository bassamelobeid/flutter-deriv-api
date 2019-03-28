#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];
use lib qw(/home/git/regentmarkets/bom-backoffice);

use JSON::MaybeXS;
use BOM::Backoffice::Sysinit ();
use BOM::Backoffice::CustomCommissionTool;
use BOM::Backoffice::Auth0;
use BOM::Backoffice::QuantsAuditLog;
BOM::Backoffice::Sysinit::init();
my $json  = JSON::MaybeXS->new;
my $staff = BOM::Backoffice::Auth0::from_cookie()->{nickname};

my $args = {
    staff             => $staff,
    name              => request()->param('name'),
    currency_symbol   => request()->param('currency_symbol'),
    underlying_symbol => request()->param('underlying_symbol'),
    bias              => request()->param('bias'),
    start_time        => request()->param('start_time'),
    end_time          => request()->param('end_time'),
    OTM_max           => request()->param('OTM_max'),
    ITM_max           => request()->param('ITM_max'),
    ITM_1             => request()->param('ITM_1'),
    ITM_2             => request()->param('ITM_2'),
    ITM_3             => request()->param('ITM_3'),
    OTM_1             => request()->param('OTM_1'),
    OTM_2             => request()->param('OTM_2'),
    OTM_3             => request()->param('OTM_3'),
    ATM               => request()->param('ATM'),
};

my $args_content;

foreach my $key (keys %$args) {

    $args_content .= "$key => $args->{$key}, " if defined($args->{$key});

}

if (request()->param('save_config')) {

    my $commission = BOM::Backoffice::CustomCommissionTool::save_commission($args);
    print $json->encode($commission);

    BOM::Backoffice::QuantsAuditLog::log($staff, "savecommission", $args_content) if not $commission->{error};
}

if (request()->param('delete_config')) {

    my $commission = BOM::Backoffice::CustomCommissionTool::delete_commission($args->{name});
    print $json->encode($commission);
    BOM::Backoffice::QuantsAuditLog::log($staff, "deletecommission", $args_content) if not $commission->{error};

}
