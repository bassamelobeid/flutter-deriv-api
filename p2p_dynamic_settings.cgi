#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use f_brokerincludeall;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request      qw(request);
use BOM::Backoffice::Sysinit      ();
BOM::Backoffice::Sysinit::init();

use BOM::Backoffice::Utility qw(master_live_server_error);
use BOM::DynamicSettings;
use BOM::Config::Runtime;
use BOM::Config;
use BOM::User::Client;
use LandingCompany::Registry;
use List::Util qw(min);
use Syntax::Keyword::Try;

my $cgi = CGI->new;

PrintContentType();

BrokerPresentation('P2P DYNAMIC SETTINGS');
# Make sure to add these keys and any new keys in DynamicSettings.pm exclude
my @setting_keys = qw(
    payments.p2p.enabled
    payments.p2p.available
    payments.p2p.clients
    payments.p2p.email_to
    payments.p2p.order_timeout
    payments.p2p.escrow
    payments.p2p.limits.count_per_day_per_client
    payments.p2p.limits.maximum_advert
    payments.p2p.limits.maximum_order
    payments.p2p.limits.maximum_ads_per_type
    payments.p2p.restricted_countries
    payments.p2p.available_for_currencies
    payments.p2p.cancellation_grace_period
    payments.p2p.cancellation_barring.count
    payments.p2p.cancellation_barring.period
    payments.p2p.cancellation_barring.bar_time
    payments.p2p.fraud_blocking.buy_count
    payments.p2p.fraud_blocking.buy_period
    payments.p2p.fraud_blocking.sell_count
    payments.p2p.fraud_blocking.sell_period
    payments.p2p.refund_timeout
    payments.p2p.disputed_timeout
    payments.p2p.archive_ads_days
    payments.p2p.delete_ads_days
    payments.p2p.payment_methods_enabled
    payments.p2p.float_rate_global_max_range
    payments.p2p.float_rate_order_slippage
    payments.p2p.email_campaign_ids
    payments.p2p.review_period
    payments.p2p.create_order_chat
    payments.p2p.transaction_verification_countries
    payments.p2p.transaction_verification_countries_all
    payments.p2p.feature_level
    payments.p2p.block_trade.enabled
    payments.p2p.block_trade.maximum_advert
    payments.p2p.cross_border_ads_restricted_countries
    payments.p2p.fiat_deposit_restricted_countries
    payments.p2p.fiat_deposit_restricted_lookback
);

my $countries_list = request()->brand->countries_instance->countries_list;

if (request()->http_method eq 'POST' and request()->params->{save}) {
    if (not(grep { $_ eq 'binary_role_master_server' } @{BOM::Config::node()->{node}->{roles}})) {
        code_exit_BO('<p class="error"><b>' . master_live_server_error() . '</b></p>');
    } else {
        my $settings = request()->params;
        BOM::DynamicSettings::save_settings({
            'settings'          => $settings,
            'settings_in_group' => [@setting_keys],
            'save'              => 'global',
        });
    }
}

my $app_config = BOM::Config::Runtime->instance->app_config;
my $revision   = $app_config->global_revision();

my $settings;
for my $setting (@setting_keys) {
    $settings->{$setting} = {
        value       => $app_config->get($setting),
        type        => $app_config->get_data_type($setting),
        description => $app_config->get_description($setting),
        default     => $app_config->get_default($setting),
    };
}

my $escrow_currencies;
for my $escrow ($settings->{'payments.p2p.escrow'}{value}->@*) {
    try {
        my $c = BOM::User::Client->new({loginid => $escrow});
        $escrow_currencies->{$escrow} = $c->broker_code . ' - ' . $c->account->currency_code;

    } catch {
        $escrow_currencies->{$escrow} = 'invalid!';
    }
}

Bar('P2P Dynamic Settings');

my @enabled_lc = map { $_->{short} } grep { $_->{p2p_available} } values LandingCompany::Registry::get_loaded_landing_companies()->%*;

BOM::Backoffice::Request::template()->process(
    'backoffice/p2p/p2p_dynamic_settings.tt',
    {
        settings          => $settings,
        escrow_currencies => $escrow_currencies,
        countries_list    => $countries_list,
        revision          => $revision,
        enabled_lc        => \@enabled_lc,
    });

code_exit_BO();
