#!/etc/rmg/bin/perl

package main;

use strict;
use warnings;

use BOM::Backoffice::Sysinit                  ();
use BOM::Backoffice::Quant::FeedConfiguration qw(get_existing_drift_switch_spread get_maximum_commission get_maximum_perf);

BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation('Feed Configuration Management');

my $disabled_write = not BOM::Backoffice::Auth::has_quants_write_access();
Bar("Drift Switch Spread Configuration");

BOM::Backoffice::Request::template()->process(
    'backoffice/feed_drift_switch_spread_configuration.html.tt',
    {
        feed_drift_switch_spread_configuration_upload_url => request()->url_for('backoffice/quant/market_data_mgmt/update_feed_config.cgi'),
        existing_config                                   => get_existing_drift_switch_spread(),
        maximum_commission                                => get_maximum_commission(),
        maximum_perf                                      => get_maximum_perf,
        disabled                                          => $disabled_write,
    }) || die BOM::Backoffice::Request::template()->error;

code_exit_BO();
