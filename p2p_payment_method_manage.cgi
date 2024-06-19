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

BrokerPresentation('P2P PAYMENT METHODS');

if (request()->http_method eq 'POST' and request()->params->{save}) {
    if (not(grep { $_ eq 'binary_role_master_server' } @{BOM::Config::node()->{node}->{roles}})) {
        code_exit_BO('<p class="error"><b>' . master_live_server_error() . '</b></p>');
    } else {
        my ($message, $settings);
        my $countries_list = request()->brand->countries_instance->countries_list;

        for my $param (keys request()->params->%*) {
            if ($param =~ /^pm-mode_(.*)$/) {
                my $pm = $1;
                $settings->{$pm}{mode} = request()->params->{$param};
                my @countries = sort map { lc trim($_) } split(',', request()->params->{'pm-countries_' . $pm});
                for my $country (@countries) {
                    $message .= '<div class="notify notify--warning">Invalid country for payment method ' . $pm . ': "' . $country . '"</div>'
                        unless exists $countries_list->{$country};
                }
                $settings->{$pm}{countries} = \@countries;
            }
        }

        if ($message) {
            print $message;
        } else {
            my $data = {
                revision                                => request()->params->{revision},
                'payments.p2p.payment_method_countries' => JSON::MaybeXS->new->encode($settings)};
            BOM::DynamicSettings::save_settings({
                'settings'          => $data,
                'settings_in_group' => ['payments.p2p.payment_method_countries'],
                'save'              => 'global',
            });
        }
    }
}

my $payment_methods          = BOM::Config::p2p_payment_methods;
my $app_config               = BOM::Config::Runtime->instance->app_config;
my $revision                 = $app_config->global_revision();
my $payment_method_countries = JSON::MaybeXS->new->decode($app_config->get('payments.p2p.payment_method_countries'));

Bar('Settings');

BOM::Backoffice::Request::template()->process(
    'backoffice/p2p/p2p_payment_method_manage.tt',
    {
        revision                 => $revision,
        payment_methods          => $payment_methods,
        payment_method_countries => $payment_method_countries,
    });

code_exit_BO();
