#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use f_brokerincludeall;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request      qw(request);
use BOM::Backoffice::Sysinit      ();
BOM::Backoffice::Sysinit::init();

use Scalar::Util             qw(looks_like_number);
use BOM::Backoffice::Utility qw(master_live_server_error);
use BOM::DynamicSettings;
use BOM::Config::Runtime;
use Locale::Country;
use BOM::Config;
use Syntax::Keyword::Try;
use JSON::MaybeXS;
use Text::Trim;

my $cgi = CGI->new;

PrintContentType();

BrokerPresentation('PAYMENT AGENTS DYNAMIC SETTINGS');

my %input                    = request()->params->%*;
my $app_config               = BOM::Config::Runtime->instance->app_config;
my $per_country_settings     = {};
my $default_country_settings = {};
my $error;

my $per_country_keys = {
    initial_deposit_per_country => {
        name => 'Initial Deposit Requirement',
        type => 'number',
    }};

if (request()->http_method eq 'POST' and $input{save}) {

    try {
        if (not(grep { $_ eq 'binary_role_master_server' } @{BOM::Config::node()->{node}->{roles}})) {
            die(master_live_server_error() . "\n");
        } else {
            my $jsons = {};

            for my $setting (keys $per_country_keys->%*) {
                my $fullkey = "payment_agents.$setting";
                $jsons->{$setting} = JSON::MaybeXS->new->decode($app_config->get($fullkey));

                for my $param (keys %input) {
                    if (my ($country) = $param =~ /^$setting\[(.*)\]$/) {

                        if ($input{"delete[$country]"}) {
                            delete $jsons->{$setting}{$country};
                        } else {
                            my $value = $input{$param};
                            next if $country eq 'default' and trim($value eq '');

                            if ($country eq 'new') {
                                $country = $input{new};
                                next if trim($country) eq '' and trim($value) eq '';
                                die("Invalid country code '$country'\n") unless Locale::Country::code2country($country);
                            }

                            if ($per_country_keys->{$setting}->{type} eq 'number') {
                                unless (looks_like_number($value) and $value > 0) {
                                    die("$per_country_keys->{$setting}->{name} setting for $country must be a postive number\n");
                                }
                                $value = 0 + $value;
                            }

                            $jsons->{$setting}->{$country} = $value;
                        }
                    }
                }
            }

            my $settings = +{map { ("payment_agents.$_" => JSON::MaybeXS->new->encode($jsons->{$_})) } keys $jsons->%*};
            $settings->{revision} = $input{revision};

            BOM::DynamicSettings::save_settings({
                'settings'          => $settings,
                'settings_in_group' => [map { "payment_agents.$_" } keys $per_country_keys->%*],
                'save'              => 'global',
            });
        }
    } catch ($e) {
        $error = $e;
    }
}

for my $setting (keys $per_country_keys->%*) {
    my $fullkey = "payment_agents.$setting";
    my $values  = JSON::MaybeXS->new->decode($app_config->get($fullkey));
    $default_country_settings->{$setting} = delete $values->{default};

    for my $country (keys $values->%*) {
        $per_country_settings->{$country} //= {
            country  => Locale::Country::code2country($country) // $country,
            settings => {},
        };

        $per_country_settings->{$country}->{settings}->{$setting} = $values->{$country};
    }
}

my $revision = $app_config->global_revision();
BOM::Backoffice::Request::template()->process(
    'backoffice/payment_agents/payment_agents_dynamic_settings.tt',
    {
        per_country_keys         => $per_country_keys,
        per_country_settings     => $per_country_settings,
        revision                 => $revision,
        default_country_settings => $default_country_settings,
        error                    => $error,
    });
