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
use BOM::User::Client;
use LandingCompany::Registry;
use List::Util qw(min);
use Syntax::Keyword::Try;

my $cgi = CGI->new;

PrintContentType();

code_exit_BO('<p style="color:red;"><b>Both IT and Quants permissions are required to access this page</b></p>')
    unless BOM::Backoffice::Auth0::has_authorisation(['Quants']) && BOM::Backoffice::Auth0::has_authorisation(['IT']);

BrokerPresentation('P2P DYNAMIC SETTINGS');

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
    payments.p2p.available_for_countries
    payments.p2p.restricted_countries
    payments.p2p.available_for_currencies
);

if (request()->http_method eq 'POST' and request()->params->{save}) {
    if (not(grep { $_ eq 'binary_role_master_server' } @{BOM::Config::node()->{node}->{roles}})) {
        code_exit_BO('<p style="color:red;"><b>' . master_live_server_error() . '</b></p>');
    } else {
        BOM::DynamicSettings::save_settings({
            'settings'          => request()->params,
            'settings_in_group' => \@setting_keys,
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

my $country_names;
my %countries_list = request()->brand->countries_instance->countries_list->%*;
for my $country ($settings->{'payments.p2p.available_for_countries'}{value}->@*) {
    $country_names->{$country} = exists $countries_list{$country} ? $countries_list{$country}{name} : 'invalid!';
}

Bar('P2P Dynamic Settings');

my @enabled_lc = map { $_->{short} } grep { $_->{p2p_available} } values LandingCompany::Registry::get_loaded_landing_companies()->%*;

BOM::Backoffice::Request::template()->process(
    'backoffice/p2p/p2p_dynamic_settings.tt',
    {
        settings          => $settings,
        escrow_currencies => $escrow_currencies,
        country_names     => $country_names,
        revision          => $revision,
        enabled_lc        => \@enabled_lc,
    });

code_exit_BO();
