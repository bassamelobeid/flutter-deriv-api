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
use JSON::MaybeXS;
use Text::Trim;

my $cgi = CGI->new;

PrintContentType();

BrokerPresentation('PAYMENT CATEGORIES');

if (request()->http_method eq 'POST' and request()->params->{save}) {
    if (not(grep { $_ eq 'binary_role_master_server' } @{BOM::Config::node()->{node}->{roles}})) {
        code_exit_BO('<p class="error"><b>' . master_live_server_error() . '</b></p>');
    } else {
        my ($message, $settings);
        for my $param (keys request()->params->%*) {
            if ($param =~ /^pm-category_(.*)$/) {
                my ($pm_gateway_code, $pm_type_code) = split('-', $1);
                my $current_category =
                    $settings->{$pm_gateway_code}->{request()->params->{$param}} ? $settings->{$pm_gateway_code}->{request()->params->{$param}} : [];
                push(@$current_category, $pm_type_code);
                $settings->{$pm_gateway_code}->{request()->params->{$param}} = $current_category;
            }
        }

        if ($message) {
            print $message;
        } else {
            my $data = {
                revision              => request()->params->{revision},
                'payments.categories' => JSON::MaybeXS->new->encode($settings)};

            BOM::DynamicSettings::save_settings({
                'settings'          => $data,
                'settings_in_group' => ['payments.categories'],
                'save'              => 'global',
            });
        }
    }
}

my $app_config      = BOM::Config::Runtime->instance->app_config;
my $revision        = $app_config->global_revision();
my $payments        = JSON::MaybeXS->new->decode($app_config->get('payments.categories'));
my $payments_for_fe = {};
my $test            = {};
for my $pm_gateway (keys $payments->%*) {

    if ($payments->{$pm_gateway}->{internal}) {
        for my $pm_type_code ($payments->{$pm_gateway}->{internal}->@*) {
            $payments_for_fe->{$pm_gateway}->{$pm_type_code}->{category} = 'internal';
        }
    }
    if ($payments->{$pm_gateway}->{external}) {
        for my $pm_type_code ($payments->{$pm_gateway}->{external}->@*) {
            $payments_for_fe->{$pm_gateway}->{$pm_type_code}->{category} = 'external';
        }
    }
}

Bar('Settings');

BOM::Backoffice::Request::template()->process(
    'backoffice/payments/payment_categories.tt',
    {
        revision => $revision,
        payments => $payments_for_fe
    });

code_exit_BO();
