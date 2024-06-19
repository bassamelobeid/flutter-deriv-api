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
BrokerPresentation('Commission Management Tool');

my $provider             = request()->param('provider');
my $commission_by_market = BOM::Backoffice::CommissionTool::get_commission_by_provider($provider);

Bar("Configuration");
my $method = $provider . '_affiliate_commission';
my $config = BOM::Config::Runtime->instance->app_config->quants->$method;
BOM::Backoffice::Request::template()->process(
    'backoffice/commission_config.html.tt',
    {
        upload_url          => request()->url_for('backoffice/quant/market_data_mgmt/update_commission.cgi'),
        commission_type     => BOM::Backoffice::CommissionTool::get_enum_type('affiliate.commission_type'),
        selected_financial  => $config->type->financial,
        selected_synthetic  => $config->type->synthetic,
        provider            => $provider,
        enable              => $config->enable,
        enable_auto_payment => $config->enable_auto_payment,
    }) || die BOM::Backoffice::Request::template()->error;

Bar("Existing rates");
BOM::Backoffice::Request::template()->process(
    'backoffice/commission_by_market.html.tt',
    {
        commission => $commission_by_market,
        markets    => [sort { $a cmp $b } keys %$commission_by_market]}) || die BOM::Backoffice::Request::template()->error;

Bar("Create/Update Commission");
BOM::Backoffice::Request::template()->process(
    'backoffice/commission_update.html.tt',
    {
        upload_url      => request()->url_for('backoffice/quant/market_data_mgmt/update_commission.cgi'),
        commission_type => BOM::Backoffice::CommissionTool::get_enum_type('affiliate.commission_type'),
        account_type    => BOM::Backoffice::CommissionTool::get_enum_type('transaction.account_type'),
        provider        => $provider,
    }) || die BOM::Backoffice::Request::template()->error;

Bar("Delete Commission");
BOM::Backoffice::Request::template()->process(
    'backoffice/commission_delete.html.tt',
    {
        upload_url      => request()->url_for('backoffice/quant/market_data_mgmt/update_commission.cgi'),
        commission_type => BOM::Backoffice::CommissionTool::get_enum_type('affiliate.commission_type'),
        account_type    => BOM::Backoffice::CommissionTool::get_enum_type('transaction.account_type'),
        provider        => $provider,
    }) || die BOM::Backoffice::Request::template()->error;

Bar("Transaction/Commission Preview");
BOM::Backoffice::Request::template()->process(
    'backoffice/affiliate_commission_preview.html.tt',
    {
        upload_url         => request()->url_for('backoffice/quant/market_data_mgmt/update_commission.cgi'),
        affiliate_provider => BOM::Backoffice::CommissionTool::get_enum_type('affiliate.affiliate_provider'),
        provider           => $provider,

    }) || die BOM::Backoffice::Request::template()->error;

code_exit_BO();
