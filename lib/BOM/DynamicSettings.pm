package BOM::DynamicSettings;

use strict;
use warnings;

use Data::Compare;
use Encode;
use HTML::Entities;
use JSON::MaybeXS;
use Text::CSV;
use Try::Tiny;
use feature 'state';
use BOM::Platform::Email qw(send_email);
use BOM::Config::Runtime;
use Array::Utils qw(:all);
use Date::Utility;

sub textify_obj {
    my $type  = shift;
    my $value = shift;
    return ($type eq 'ArrayRef') ? join(',', @$value) : $value;
}

sub save_settings {
    my $args              = shift;
    my $settings          = $args->{settings};
    my $submitted         = $args->{save};
    my $settings_in_group = $args->{settings_in_group};

    my $message = "";
    if ($submitted) {
        my $app_config = BOM::Config::Runtime->instance->app_config;

        my $setting_revision   = $app_config->global_revision();
        my $submitted_revision = $settings->{'revision'};
        if ($setting_revision ne $submitted_revision) {
            $message .=
                  '<div id="error">FAILED to save global'
                . '<br />Setting has been changed after you loaded dynamic settings page<br />'
                . 'Old Revision '
                . encode_entities($setting_revision) . '=='
                . encode_entities($submitted_revision)
                . ' New Revision '
                . '</div>';
        } elsif ($submitted eq 'global') {

            my @settings = $app_config->dynamic_keys();

            my $has_errors    = 0;
            my $values_to_set = {};

            SAVESETTING:
            foreach my $s (@settings) {
                next SAVESETTING unless grep { $s eq $_ } @{$settings_in_group};
                my ($new_value, $display_value) = parse_and_refine_setting($settings->{$s}, $app_config->get_data_type($s));
                my $old_value = $app_config->get($s);
                my $compare = Data::Compare->new($new_value, $old_value);
                try {
                    if (not $compare->Cmp) {
                        my $extra_validation = get_extra_validation($s);
                        $extra_validation->($new_value, $old_value) if $extra_validation;
                        send_email_notification($new_value, $old_value, $s) if ($s =~ /quants/ and ($s =~ /suspend/ or $s =~ /disabled/));
                        $values_to_set->{$s} = $new_value;
                        $message .= join('', '<div id="saved">Set ', encode_entities($s), ' to ', encode_entities($display_value), '</div>');
                    }
                }
                catch {
                    $message .= join('',
                        '<div id="error">Invalid value, could not set ',
                        encode_entities($s), ' to ', encode_entities($display_value),
                        ' because ', encode_entities($_), '</div>');
                    $has_errors = 1;
                };
            }

            if ($has_errors) {
                $message .= '<div id="error">NOT saving global settings due to data problems.</div>';
            } else {
                try {
                    $app_config->set($values_to_set);
                    $message .= '<div id="saved">Saved global settings to environment, offerings updated</div>';
                }
                catch {
                    $message .= '<div id="error">Could not save global settings to environment</div>';
                };
            }
        } else {
            $message .= "<div id=\"error\">Invalid 'submitted' value " . encode_entities($submitted) . "</div>";
        }

        print '<div id="message">' . $message . '</div>';
        print "<br />";
    }
    return;
}

sub generate_settings_branch {
    my $args              = shift;
    my $settings          = $args->{settings};
    my $settings_in_group = $args->{settings_in_group};
    my $group             = $args->{group};
    my $title             = $args->{title};
    my $submitted         = $args->{submitted};

    my $app_config       = BOM::Config::Runtime->instance->app_config;
    my $setting_revision = $app_config->global_revision();
    my $categories       = {};

    SETTINGS:
    foreach my $ds (sort { scalar split(/\./, $a) >= scalar split(/\./, $b) } @$settings) {
        next SETTINGS unless grep { $ds eq $_ } @$settings_in_group;

        my $description = $app_config->get_description($ds);
        my $data_type   = $app_config->get_data_type($ds);
        my $default     = $app_config->get_default($ds);
        my $value       = $app_config->get($ds);
        my $key_type    = $app_config->get_key_type($ds);

        my $default_text = textify_obj($data_type, $default);
        my $value_text   = textify_obj($data_type, $value);

        #push it in right namespace
        my $space      = $categories;
        my @namespaces = split(/\./, $ds);
        my $i          = 0;
        my $len        = scalar @namespaces;
        for my $name (@namespaces) {
            $i++;
            $name = $ds if $len == $i;
            $space->{$name} //= {};

            $space = $space->{$name};
        }
        my $ds_leaf = {};
        $ds_leaf->{name}          = $ds;
        $ds_leaf->{description}   = $description;
        $ds_leaf->{type}          = $data_type;
        $ds_leaf->{value}         = $value_text;
        $ds_leaf->{default}       = $value_text eq $default_text;
        $ds_leaf->{default_value} = $default_text;
        $ds_leaf->{disabled}      = $key_type ne 'dynamic' ? 1 : 0;
        $space->{leaf}            = $ds_leaf;
    }
    return {
        settings         => $categories,
        group            => $group,
        setting_revision => $setting_revision,
        title            => $title,
        submitted        => $submitted,
    };
}

#Contains the grouping of chronicle variables for displaying it on the Backoffice.
sub get_settings_by_group {
    my $group          = shift;
    my $group_settings = {
        shutdown_suspend => [qw(
                system.suspend.trading
                system.suspend.payments
                system.suspend.payment_agents
                system.suspend.payment_agents_in_countries
                system.suspend.cryptocashier
                system.suspend.cryptocurrencies
                system.suspend.new_accounts
                system.suspend.expensive_api_calls
                system.suspend.all_logins
                system.suspend.social_logins
                system.suspend.logins
                system.suspend.mt5
                system.suspend.mt5_deposits
                system.suspend.mt5_withdrawals
                system.suspend.transfer_between_accounts
                )
        ],
        quant => [qw(
                quants.commission.adjustment.global_scaling
                quants.commission.adjustment.per_market_scaling.forex
                quants.commission.adjustment.per_market_scaling.indices
                quants.commission.adjustment.per_market_scaling.commodities
                quants.commission.adjustment.per_market_scaling.volidx
                quants.markets.disabled
                quants.features.suspend_contract_types
                quants.underlyings.disable_autoupdate_vol
                quants.underlyings.suspend_buy
                quants.underlyings.suspend_trades
                )
        ],
        it => [qw(
                cgi.allowed_languages
                cgi.backoffice.static_url
                cgi.terms_conditions_version
                )
        ],
        payments => [qw(
                payments.payment_limits
                payments.transfer_between_accounts.fees.fiat
                payments.transfer_between_accounts.fees.crypto
                payments.transfer_between_accounts.amount.fiat.min
                payments.transfer_between_accounts.amount.crypto.min
                payments.experimental_currencies_allowed
                )]};

    my $settings;

    if ($group eq 'others') {
        my @grouped_settings = map { @{$group_settings->{$_}} } keys %$group_settings;
        my @all_settings = BOM::Config::Runtime->instance->app_config->all_keys();

        my @filtered_settings;
        #find other settings that are not in groups
        foreach my $s (@all_settings) {
            push @filtered_settings, $s unless (grep { /^$s$/ } @grouped_settings);
        }

        $settings = \@filtered_settings;
    } else {
        $settings = $group_settings->{$group};
    }

    return $settings;
}

sub parse_and_refine_setting {
    my $input_value = shift;
    my $type        = shift;

    # Trim
    $input_value =~ s/^\s+//  if (defined($input_value));
    $input_value =~ s/\s+$//g if (defined($input_value));

    my $display_value = $input_value;

    if ($type eq 'Bool') {
        if (not defined $input_value or ($input_value =~ /^(no|n|0|false)$/i)) {
            $input_value   = 0;
            $display_value = 'false';
        } elsif ($input_value =~ /^(yes|y|1|true|on)$/i) {
            $input_value   = 1;
            $display_value = 'true';
        }
    } elsif ($type eq 'ArrayRef') {
        if (ref($input_value) eq 'ARRAY') {
            $input_value = [@{$input_value}];
            $display_value = join(',', @{$input_value});
        } elsif (not defined($input_value)) {
            $input_value   = [];
            $display_value = '';
        } elsif (not length($input_value)) {
            $input_value   = [];
            $display_value = '';
        } elsif ($input_value =~ /,/) {
            my $csv = Text::CSV->new;
            $input_value =~ s/, /,/g;    # in case of: 'val1, val2, etc'
            if ($csv->parse($input_value)) {
                $input_value = [$csv->fields()];
                $csv->combine(@$input_value);
                $display_value = $csv->string;
            }
        } else {
            $input_value = [split(/\s+/, $input_value)];
            $display_value = join(', ', @$input_value);
        }
    } elsif ($type eq 'json_string') {
        my $decoded;
        try {
            $decoded = JSON::MaybeXS->new->decode($input_value);
        }
        catch {
            warn("Error: decoding of $input_value failed - $_");
        };
        if (not defined $input_value or not defined $decoded) {
            $input_value = '{}';
        } else {
            $input_value = Encode::encode_utf8(
                JSON::MaybeXS->new(
                    pretty    => 1,
                    canonical => 1,
                )->encode($decoded));
        }
        $display_value = $input_value;
    } else {
        $input_value = defined($input_value) ? $input_value : undef;
    }

    return ($input_value, $display_value);

}

# This contains functions to do field-specific validation on the dynamic settings
#   Functions specified should:
#       - Accept one argument (the value being validated)...
#       -   and an optional second argument (the old value)
#       - If there is a problem die with a message describing the issue.
sub get_extra_validation {
    my $setting = shift;
    state $setting_validators = {
        'cgi.terms_conditions_version' => \&validate_tnc_string,
    };

    return $setting_validators->{$setting};
}

sub validate_tnc_string {
    my ($new_string, $old_string) = @_;

    state $tnc_string_format = qr/^Version ([0-9]+) ([0-9]{4}-[0-9]{2}-[0-9]{2})$/;

    # Check expected date format
    die 'Incorrect format (must be Version X yyyy-mm-dd)'
        unless my ($version, $date) = $new_string =~ $tnc_string_format;

    # Date needs to be valid (will die if not)
    my $new_date = Date::Utility->new($date);

    # Date shouldn't be in the future
    die 'Date is in the future' if $new_date->is_after(Date::Utility::today);

    # Shouldn't go backward from old
    die 'Existing version failed validation. Please raise with IT.'
        unless my ($old_version, $old_date) = $old_string =~ $tnc_string_format;

    die 'New version is lower than previous' if $version < $old_version;
    die 'New date is older than previous' if $new_date->is_before(Date::Utility->new($old_date));

    # No errors
    return;
}

sub send_email_notification {
    my $new_value = shift;
    my $old_value = shift;
    my $for       = shift;

    my $enable_disable = scalar(@$new_value) > scalar(@$old_value) ? 'Disable' : 'Enable';

    my $subject = "$enable_disable Asset/Product Notification. ";

    my @different = array_diff(@$new_value, @$old_value);

    my $disable_type =
        $for eq 'quants.features.suspend_contract_types' ? 'Contract_type' : $for eq 'quants.markets.disabled' ? 'Market' : 'Underlying';
    my $staff   = BOM::Backoffice::Cookie::get_staff();
    my @message = "$enable_disable the following offering:";
    push @message, "$disable_type: " . join(",", @different);
    push @message, "By $staff on " . Date::Utility->new->datetime;

    my $email_list = 'x-quants@binary.com, compliance@binary.com, x-cs@binary.com,x-marketing@binary.com';

    send_email({
        from    => 'system@binary.com',
        to      => $email_list,
        subject => $subject,
        message => \@message,
    });

    return;
}
1;
