#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use f_brokerincludeall;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

use BOM::Backoffice::Utility qw(master_live_server_error);
use BOM::DynamicSettings;
use BOM::Config::Runtime;
use BOM::Config;
use BOM::User::Client;
use LandingCompany::Registry;
use List::Util qw(min);
use Syntax::Keyword::Try;
use JSON::MaybeXS;
use Text::Trim;

my $cgi = CGI->new;

PrintContentType();

code_exit_BO('<p class="error"><b>Both IT and Quants permissions are required to access this page</b></p>')
    unless BOM::Backoffice::Auth0::has_authorisation(['Quants']) && BOM::Backoffice::Auth0::has_authorisation(['IT']);

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
    payments.p2p.available_for_countries
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
    payments.p2p.credit_card_turnover_requirement
    payments.p2p.credit_card_check_period
);

my $countries_list           = request()->brand->countries_instance->countries_list;
my $payment_methods          = BOM::Config::p2p_payment_methods;
my $payment_method_countries = {};

if (request()->http_method eq 'POST' and request()->params->{save}) {
    if (not(grep { $_ eq 'binary_role_master_server' } @{BOM::Config::node()->{node}->{roles}})) {
        code_exit_BO('<p class="error"><b>' . master_live_server_error() . '</b></p>');
    } else {
        my $message;
        for my $param (keys request()->params->%*) {
            if ($param =~ /^pm-mode_(.*)$/) {
                my $pm = $1;
                $payment_method_countries->{$pm}{mode} = request()->params->{$param};
                my @countries = sort map { lc trim($_) } split(',', request()->params->{'pm-countries_' . $pm});
                for my $country (@countries) {
                    $message .= '<div class="notify notify--warning">Invalid country for payment method ' . $pm . ': "' . $country . '"</div>'
                        unless exists $countries_list->{$country};
                }
                $payment_method_countries->{$pm}{countries} = \@countries;
            }
        }

        if ($message) {
            print $message;
        } else {
            my $settings = request()->params;
            $settings->{'payments.p2p.payment_method_countries'} = JSON::MaybeXS->new->encode($payment_method_countries);
            BOM::DynamicSettings::save_settings({
                'settings'          => $settings,
                'settings_in_group' => [@setting_keys, 'payments.p2p.payment_method_countries'],
                'save'              => 'global',
            });
        }
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

$payment_method_countries = JSON::MaybeXS->new->decode($app_config->get('payments.p2p.payment_method_countries'));

Bar('P2P Dynamic Settings');

my @enabled_lc = map { $_->{short} } grep { $_->{p2p_available} } values LandingCompany::Registry::get_loaded_landing_companies()->%*;

BOM::Backoffice::Request::template()->process(
    'backoffice/p2p/p2p_dynamic_settings.tt',
    {
        settings                 => $settings,
        escrow_currencies        => $escrow_currencies,
        countries_list           => $countries_list,
        revision                 => $revision,
        enabled_lc               => \@enabled_lc,
        payment_methods          => $payment_methods,
        payment_method_countries => $payment_method_countries,
    });

code_exit_BO();
