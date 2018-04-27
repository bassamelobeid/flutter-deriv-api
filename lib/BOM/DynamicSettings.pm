package BOM::DynamicSettings;

use strict;
use warnings;

use Data::Compare;
use Encode;
use HTML::Entities;
use JSON::MaybeXS;
use Text::CSV;
use Try::Tiny;

use BOM::Platform::Runtime;

sub get_all_settings_list {
    my $setting = shift;
    my $ds      = BOM::Platform::Runtime->instance->app_config->dynamic_settings_info;
    if ($setting eq 'global') {
        return keys %{$ds->{global}};
    }
}

sub textify_obj {
    my $type  = shift;
    my $value = shift;
    return ($type eq 'ArrayRef') ? join(',', @$value) : $value;
}

sub dynamic_save {
    return 0 unless BOM::Platform::Runtime->instance->app_config->save_dynamic;
    return 1;
}

sub save_settings {
    my $args              = shift;
    my $settings          = $args->{settings};
    my $submitted         = $args->{save};
    my $settings_in_group = $args->{settings_in_group};

    my $message = "";
    if ($submitted) {
        my $data_set = BOM::Platform::Runtime->instance->app_config->data_set;

        my $setting_revision   = $data_set->{version};
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

            my $global;
            my @settings;
            if ($submitted eq 'global') {
                @settings = (get_all_settings_list('global'));
                $global   = 1;
            }

            my $has_errors       = 0;
            my $dynamic_settings = BOM::Platform::Runtime->instance->app_config->dynamic_settings_info;

            SAVESETTING:
            foreach my $s (@settings) {
                next SAVESETTING unless grep { $s eq $_ } @{$settings_in_group};
                if ($global) {
                    my ($new_value, $display_value) = parse_and_refine_setting($settings->{$s}, $dynamic_settings->{global}->{$s}->{type});
                    my $old_value = $data_set->{global}->get($s);
                    my $compare = Data::Compare->new($new_value, $old_value);
                    try {
                        if (not $compare->Cmp) {
                            $data_set->{global}->set($s, $new_value);
                            $message .= join('', '<div id="saved">Set ', encode_entities($s), ' to ', encode_entities($display_value), '</div>');
                        }
                    }
                    catch {
                        $message .= join('',
                            '<div id="error">Invalid value, could not set ',
                            encode_entities($s), ' to ', encode_entities($display_value), '</div>');
                        $has_errors = 1;
                    };
                }
            }

            if ($has_errors) {
                $message .= '<div id="error">NOT saving global settings due to data problems.</div>';
            } elsif (not dynamic_save()) {
                $message .= '<div id="error">Could not save global settings to environment</div>';
            } else {
                $message .= '<div id="saved">Saved global settings to environment, offerings updated</div>';
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

    my $data_set         = BOM::Platform::Runtime->instance->app_config->data_set;
    my $setting_revision = $data_set->{version};
    my $categories       = {};

    SETTINGS:
    foreach my $ds (sort { scalar split(/\./, $a) >= scalar split(/\./, $b) } @{$settings;}) {
        next SETTINGS unless grep { $ds eq $_ } @{$settings_in_group;};
        my $ds_ref = BOM::Platform::Runtime->instance->app_config->dynamic_settings_info->{$submitted}->{$ds};

        my $value;
        if ($submitted eq 'global') {
            $value = $data_set->{global}->get($ds);
        }

        my $overridden;
        if ($data_set->{app_settings_overrides} and defined $data_set->{app_settings_overrides}->get($ds)) {
            $value      = $data_set->{app_settings_overrides}->get($ds);
            $overridden = 1;
        }

        my $default;
        unless (defined $value) {
            $value   = $ds_ref->{default};
            $default = 1;
        }
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
        $ds_leaf->{description}   = $ds_ref->{description};
        $ds_leaf->{type}          = $ds_ref->{type};
        $ds_leaf->{value}         = textify_obj($ds_ref->{type}, $value);
        $ds_leaf->{default}       = $default;
        $ds_leaf->{default_value} = textify_obj($ds_ref->{type}, $ds_ref->{default});
        $ds_leaf->{disabled}      = 1 if ($overridden);
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
                system.suspend.cryptocashier
                system.suspend.cryptocurrencies
                system.suspend.new_accounts
                system.suspend.expensive_api_calls
                system.suspend.all_logins
                system.suspend.social_logins
                system.suspend.logins
                system.suspend.system
                system.suspend.mt5
                )
        ],
        quant => [qw(
                quants.commission.adjustment.global_scaling
                quants.commission.adjustment.per_market_scaling.forex
                quants.commission.adjustment.per_market_scaling.indices
                quants.commission.adjustment.per_market_scaling.commodities
                quants.commission.adjustment.per_market_scaling.stocks
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
                )]};

    my $settings;

    if ($group eq 'others') {
        my @filtered_settings;
        my @all;
        push @all, @{$group_settings->{$_}} for (keys %$group_settings);

        my @global_settings = get_all_settings_list('global');

        #find other settings that are not in groups
        foreach my $s (@global_settings) {
            my $setting_name = $s;
            push @filtered_settings, $s unless (grep { /^$setting_name$/ } @all);
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

1;
