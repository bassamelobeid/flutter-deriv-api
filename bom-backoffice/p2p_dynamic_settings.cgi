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
use List::Util qw(min any);
use Syntax::Keyword::Try;
use BOM::Platform::Event::Emitter;

my $cgi = CGI->new;

PrintContentType();

BrokerPresentation('P2P DYNAMIC SETTINGS');
# Make sure to add these keys and any new keys in DynamicSettings.pm exclude.
# If value is true, p2p_settings_updated event is emitted when setting is changed.
my %setting_keys = (
    "payments.p2p.enabled"                                         => 1,
    "payments.p2p.available"                                       => 0,
    "payments.p2p.clients"                                         => 0,
    "payments.p2p.email_to"                                        => 0,
    "payments.p2p.order_timeout"                                   => 1,
    "payments.p2p.escrow"                                          => 0,
    "payments.p2p.limits.count_per_day_per_client"                 => 1,
    "payments.p2p.limits.maximum_advert"                           => 0,
    "payments.p2p.limits.maximum_order"                            => 1,
    "payments.p2p.limits.maximum_ads_per_type"                     => 1,
    "payments.p2p.restricted_countries"                            => 0,
    "payments.p2p.available_for_currencies"                        => 1,
    "payments.p2p.cancellation_grace_period"                       => 1,
    "payments.p2p.cancellation_barring.count"                      => 1,
    "payments.p2p.cancellation_barring.period"                     => 1,
    "payments.p2p.cancellation_barring.bar_time"                   => 1,
    "payments.p2p.fraud_blocking.buy_count"                        => 0,
    "payments.p2p.fraud_blocking.buy_period"                       => 0,
    "payments.p2p.fraud_blocking.sell_count"                       => 0,
    "payments.p2p.fraud_blocking.sell_period"                      => 0,
    "payments.p2p.refund_timeout"                                  => 0,
    "payments.p2p.disputed_timeout"                                => 0,
    "payments.p2p.archive_ads_days"                                => 1,
    "payments.p2p.delete_ads_days"                                 => 0,
    "payments.p2p.payment_methods_enabled"                         => 1,
    "payments.p2p.float_rate_global_max_range"                     => 1,
    "payments.p2p.float_rate_order_slippage"                       => 0,
    "payments.p2p.email_campaign_ids"                              => 0,
    "payments.p2p.review_period"                                   => 1,
    "payments.p2p.create_order_chat"                               => 0,
    "payments.p2p.transaction_verification_countries"              => 0,
    "payments.p2p.transaction_verification_countries_all"          => 0,
    "payments.p2p.feature_level"                                   => 1,
    "payments.p2p.block_trade.enabled"                             => 1,
    "payments.p2p.block_trade.maximum_advert"                      => 1,
    "payments.p2p.cross_border_ads_restricted_countries"           => 0,
    "payments.p2p.fiat_deposit_restricted_countries"               => 0,
    "payments.p2p.fiat_deposit_restricted_lookback"                => 0,
    "payments.p2p.poa.enabled"                                     => 0,
    "payments.p2p.poa.countries_includes"                          => 0,
    "payments.p2p.poa.countries_excludes"                          => 0,
    "payments.p2p.advert_counterparty_terms.completion_rate_steps" => 1,
    "payments.p2p.advert_counterparty_terms.join_days_steps"       => 1,
    "payments.p2p.advert_counterparty_terms.rating_steps"          => 1,
    "payments.p2p.dispute_response_time"                           => 0,
    "payments.p2p.order_expiry_options"                            => 1,
    "payments.p2p.limit_upgrade_restricted_countries"              => 0,
);

my $app_config     = BOM::Config::Runtime->instance->app_config;
my $countries_list = request()->brand->countries_instance->countries_list;

if (request()->http_method eq 'POST' and request()->params->{save}) {
    if (not(grep { $_ eq 'binary_role_master_server' } @{BOM::Config::node()->{node}->{roles}})) {
        code_exit_BO('<p class="error"><b>' . master_live_server_error() . '</b></p>');
    } else {
        my $settings = request()->params;
        my ($settings_saved_flag, @updated_keys) = BOM::DynamicSettings::save_settings({
            'settings'          => $settings,
            'settings_in_group' => [keys %setting_keys],
            'save'              => 'global',
        });

        BOM::Platform::Event::Emitter::emit(p2p_settings_updated => {force_update => 1})
            if $settings_saved_flag && any { $setting_keys{$_} } @updated_keys;
    }
}

my $revision = $app_config->global_revision();

my $settings;
for my $setting (keys %setting_keys) {
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
