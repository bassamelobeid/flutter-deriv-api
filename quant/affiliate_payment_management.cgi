#!/etc/rmg/bin/perl

package main;

use strict;
use warnings;
use JSON::MaybeUTF8 qw(:v1);
use BOM::Config::Runtime;
use BOM::Backoffice::CommissionTool;
use BOM::Backoffice::Sysinit ();

BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation('Affiliate Payment Management Tool');

Bar("Update Affiliate Payment Details");
BOM::Backoffice::Request::template()->process(
    'backoffice/commission_affiliate_payment_update.html.tt',
    {
        upload_url         => request()->url_for('backoffice/quant/market_data_mgmt/update_commission.cgi'),
        affiliate_provider => BOM::Backoffice::CommissionTool::get_enum_type('affiliate.affiliate_provider'),
    }) || die BOM::Backoffice::Request::template()->error;

code_exit_BO();
