#!/etc/rmg/bin/perl

package main;

use strict;
use warnings;

use BOM::Backoffice::Sysinit                                 ();
use BOM::Backoffice::Quant::FeedConfiguration                qw(get_existing_drift_switch_spread get_maximum_commission get_maximum_perf);
use BOM::Backoffice::Quant::FeedConfiguration::TacticalIndex qw(get_existing_params);

BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation('Feed Configuration Management');

my $is_quants  = BOM::Backoffice::Auth::has_quants_write_access();
my $is_dealing = BOM::Backoffice::Auth::has_authorisation(['DealingWrite']);
my $clerk      = BOM::Backoffice::Auth::get_staffname();

Bar("Drift Switch Spread Configuration");

BOM::Backoffice::Request::template()->process(
    'backoffice/feed_drift_switch_spread_configuration.html.tt',
    {
        feed_drift_switch_spread_configuration_upload_url => request()->url_for('backoffice/quant/market_data_mgmt/update_feed_config.cgi'),
        existing_config                                   => get_existing_drift_switch_spread(),
        maximum_commission                                => get_maximum_commission(),
        maximum_perf                                      => get_maximum_perf,
        disabled                                          => not($is_quants || $is_dealing),
    }) || die BOM::Backoffice::Request::template()->error;

Bar("Tactical Index Configuration");

BOM::Backoffice::Request::template()->process(
    'backoffice/feed_tactical_index_configuration.html.tt',
    {
        feed_tactical_index_upload_url => request()->url_for('backoffice/quant/market_data_mgmt/update_feed_config.cgi'),
        action                         => request()->url_for('backoffice/quants_createdcc.cgi'),
        is_quants                      => $is_quants,
        is_dealing                     => $is_dealing,
        existing_config                => get_existing_params(),
        disabled                       => not($is_quants || $is_dealing),
    }) || die BOM::Backoffice::Request::template()->error;

code_exit_BO();
