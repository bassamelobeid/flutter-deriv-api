#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

## TODO: techincal debt, to migrate other payments settings here.

use f_brokerincludeall;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::Sysinit ();
use BOM::Backoffice::Auth0;
BOM::Backoffice::Sysinit::init();

use Scalar::Util qw(looks_like_number);
use BOM::Backoffice::Utility qw(master_live_server_error);
use BOM::DynamicSettings;
use BOM::Config::Runtime;
use Syntax::Keyword::Try;
use JSON::MaybeUTF8 qw(decode_json_utf8 encode_json_utf8);
use List::MoreUtils qw(any);

my $cgi = CGI->new;

PrintContentType();

BrokerPresentation('PAYMENTS DYNAMIC SETTINGS');

my $clerk      = BOM::Backoffice::Auth0::get_staffname();
my %input      = request()->params->%*;
my $app_config = BOM::Config::Runtime->instance->app_config;
my $error;
my $message;
my $payment_limits = decode_json_utf8(BOM::Config::Runtime->instance->app_config->payments->payment_limits);

if (request()->http_method eq 'POST' and ($input{section} // '') eq 'limits') {
    my $dcc_code  = $input{dcc};
    my $dcc_error = BOM::DualControl->new({
            staff           => $clerk,
            transactiontype => $input{transtype}})->validate_payments_settings_control_code($dcc_code);

    try {
        die $dcc_error->get_mesg() if $dcc_error;

        if (my $to_update = $input{update}) {
            my $new_limit = $input{"limit[$to_update][limit]"};
            my $new_name  = $input{"limit[$to_update][name]"};

            if (exists $payment_limits->{$new_name} && $new_name ne $to_update) {
                $error = "Limit for $new_name has already been configured";
            } else {
                if (looks_like_number $new_limit && $new_limit > 0) {
                    delete $payment_limits->{$to_update};
                    $payment_limits->{$new_name} = $new_limit;
                } else {
                    $error = 'The limit you have specified is not valid. Must be a number larger than 0';
                }
            }
        }

        if (my $to_delete = $input{delete}) {
            delete $payment_limits->{$to_delete};
        }

        if (my $to_add = $input{new_name}) {
            if (exists $payment_limits->{$to_add}) {
                $error = "Limit for $to_add has already been configured";
            } else {
                my $new_limit = $input{new_limit};

                if (looks_like_number $new_limit && $new_limit > 0) {
                    $payment_limits->{$to_add} = $new_limit;
                } else {
                    $error = 'The limit you have specified is not valid. Must be a number larger than 0';
                }
            }
        }

        unless ($error) {
            my $settings = +{
                'payments.payment_limits' => encode_json_utf8($payment_limits),
                'revision'                => $input{revision},
            };

            BOM::DynamicSettings::save_settings({
                'settings'          => $settings,
                'settings_in_group' => ['payments.payment_limits'],
                'save'              => 'global',
            });
        }
    } catch ($e) {
        $error = $e;
    }
}

my $new_pm;

if (request()->http_method eq 'POST' and ($input{section} // '') eq 'high_risk') {
    try {
        my $high_risk_pm = [map { m/high_risk\[(.*)\]\[pm\]/g } keys %input];

        if (not(grep { $_ eq 'binary_role_master_server' } @{BOM::Config::node()->{node}->{roles}})) {
            die(master_live_server_error() . "\n");
        } else {
            my $json = {};

            if ($new_pm = $input{new}) {
                die("$new_pm is already configured\n") if any { $_ eq $new_pm } $high_risk_pm->@*;

                push $high_risk_pm->@*, $new_pm;

                %input = (
                    "high_risk[$new_pm][pm]"       => delete $input{'new'},
                    "high_risk[$new_pm][siblings]" => delete $input{'siblings[new]'},
                    "high_risk[$new_pm][days]"     => delete $input{'days[new]'},
                    "high_risk[$new_pm][limit]"    => delete $input{'limit[new]'},
                    %input,
                );
            }

            for my $pm ($high_risk_pm->@*) {
                next unless $pm;

                my $updated_pm = $input{"high_risk[$pm][pm]"};

                next unless $updated_pm;

                next if defined $input{high_risk_to_delete} && $input{high_risk_to_delete} eq $pm;

                my ($siblings, $limit, $days) = @input{"high_risk[$pm][siblings]", "high_risk[$pm][limit]", "high_risk[$pm][days]"};

                unless (looks_like_number($limit) and $limit > 0) {
                    die("`limit` setting for $pm must be larger than 0\n");
                }

                unless (looks_like_number($days) and $days > 0) {
                    die("`days` setting for $pm must be larger than 0\n");
                }

                $json->{$updated_pm} = {
                    siblings => [map { trim($_) } split(/,/, $siblings)],
                    limit    => $limit + 0,
                    days     => $days + 0,
                };
            }

            my $settings = +{
                'payments.payment_methods.high_risk' => JSON::MaybeXS->new->encode($json),
                'revision'                           => $input{revision},
            };

            BOM::DynamicSettings::save_settings({
                'settings'          => $settings,
                'settings_in_group' => ['payments.payment_methods.high_risk'],
                'save'              => 'global',
            });

            $message = 'Payment Method High Risk Dynamic settings saved';
        }
    } catch ($e) {
        $error = $e;
    }
}

my $high_risk_payment_methods = JSON::MaybeXS->new->decode(BOM::Config::Runtime->instance->app_config->payments->payment_methods->high_risk);

my $revision = $app_config->global_revision();

BOM::Backoffice::Request::template()->process(
    'backoffice/payments/payments_dynamic_settings.tt',
    {
        high_risk_payment_methods => $high_risk_payment_methods,
        payment_limits            => $payment_limits,
        revision                  => $revision,
        error                     => $error,
        message                   => $message,
        staff                     => $clerk,
        input_new                 => {
            pm       => $input{'new'}           // '',
            siblings => $input{'siblings[new]'} // '',
            days     => $input{'days[new]'}     // '',
            new      => $input{'limit[new]'}    // '',
        },
    });
