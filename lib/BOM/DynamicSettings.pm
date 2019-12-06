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
use LandingCompany::Registry;
use Format::Util::Numbers qw/formatnumber/;
use Array::Utils qw(:all);
use Date::Utility;
use Scalar::Util;
use List::Util;
use BOM::Backoffice::QuantsAuditLog;
use BOM::Platform::Email qw(send_email);
use BOM::Config::Runtime;
use BOM::Config::Chronicle;
use BOM::Config::CurrencyConfig;
use BOM::Backoffice::Request qw(request);

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
        # pass in the writer before setting any config
        $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

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
                my ($new_value, $display_value);
                try {
                    my $field_type = $app_config->get_data_type($s);
                    ($new_value, $display_value) = parse_and_refine_setting($settings->{$s}, $field_type);
                    my $old_value = $app_config->get($s);
                    my $compare =
                        $field_type eq 'json_string'
                        ? Data::Compare->new(JSON::MaybeXS->new->decode($new_value), JSON::MaybeXS->new->decode($old_value))
                        : Data::Compare->new($new_value,                             $old_value);

                    if (not $compare->Cmp) {
                        my $extra_validation = get_extra_validation($s);
                        $extra_validation->($new_value, $old_value, $s) if $extra_validation;
                        send_email_notification($new_value, $old_value, $s) if ($s =~ /quants/ and ($s =~ /suspend/ or $s =~ /disabled/));
                        $values_to_set->{$s} = $new_value;
                        $message .= join('', '<div id="saved">Set ', encode_entities($s), ' to ', encode_entities($display_value), '</div>');

                    }
                }
                catch {
                    $message .= join('',
                        '<div id="error">Invalid value, could not set ',
                        encode_entities($s), ' to ', $settings->{$s}, ' because ', encode_entities($_), '</div>');
                    $has_errors = 1;
                };
            }

            if ($has_errors) {
                $message .= '<div id="error">NOT saving global settings due to data problems.</div>';
            } else {
                try {
                    my $log_content = "";

                    foreach my $key (keys %{$values_to_set}) {

                        my ($value, $display_value) = parse_and_refine_setting($settings->{$key}, $app_config->get_data_type($key));
                        $log_content .= "$key => $display_value ,";

                    }

                    my $staff = BOM::Backoffice::Auth0::get_staffname();
                    BOM::Backoffice::QuantsAuditLog::log($staff, "updatedynamicsettingpage", $log_content);
                    $app_config->set($values_to_set);
                    $message .= '<div id="saved">Saved global settings to environment, offerings updated</div>';
                }
                catch {
                    $message .= "<div id=\"error\">Could not save global settings to environment: $_</div>";
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
                system.suspend.cryptocashier
                system.suspend.cashier
                system.suspend.cryptocurrencies
                system.suspend.cryptocurrencies_deposit
                system.suspend.cryptocurrencies_withdrawal
                system.suspend.new_accounts
                system.suspend.expensive_api_calls
                system.suspend.all_logins
                system.suspend.social_logins
                system.suspend.logins
                system.suspend.transfer_between_accounts
                system.suspend.transfer_currencies
                system.suspend.onfido
                system.suspend.customerio
                system.suspend.otc
                system.mt5.suspend.all
                system.mt5.suspend.deposits
                system.mt5.suspend.withdrawals
                )
        ],
        quant => [qw(
                quants.commission.adjustment.global_scaling
                quants.commission.adjustment.per_market_scaling.forex
                quants.commission.adjustment.per_market_scaling.indices
                quants.commission.adjustment.per_market_scaling.commodities
                quants.commission.adjustment.per_market_scaling.synthetic_index
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
                payments.otc.enabled
                payments.otc.available
                payments.otc.clients
                payments.otc.escrow
                payments.otc.limits.count_per_day_per_client
                payments.otc.limits.maximum_offer
                payments.transfer_between_accounts.limits.between_accounts
                payments.transfer_between_accounts.limits.MT5
                payments.transfer_between_accounts.exchange_rate_expiry.fiat
                payments.transfer_between_accounts.exchange_rate_expiry.fiat_holidays
                payments.transfer_between_accounts.exchange_rate_expiry.crypto
                payments.transfer_between_accounts.minimum.default.fiat
                payments.transfer_between_accounts.minimum.default.crypto
                payments.transfer_between_accounts.minimum.by_currency
                payments.transfer_between_accounts.maximum.default
                payments.experimental_currencies_allowed
                )
        ],
        # these settings are configured in separate pages. No need to reconfure them in Dynamic Settings/Others.
        exclude => [qw(
                payments.transfer_between_accounts.fees.default.fiat_fiat
                payments.transfer_between_accounts.fees.default.fiat_crypto
                payments.transfer_between_accounts.fees.default.fiat_stable
                payments.transfer_between_accounts.fees.default.crypto_fiat
                payments.transfer_between_accounts.fees.default.stable_fiat
                payments.transfer_between_accounts.fees.by_currency
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
        try {
            if (defined $input_value) {
                my $decoded = JSON::MaybeXS->new->decode($input_value);
                $display_value = JSON::MaybeXS->new(
                    pretty    => 1,
                    canonical => 1,
                )->encode($decoded);
            }
        }
        catch {
            die 'JSON string is not well-formatted.';
        }
    } elsif ($type eq 'Num') {
        die "Value '$input_value' is not a valid number." unless Scalar::Util::looks_like_number($input_value);
    }
    return ($input_value, $display_value);
}

# This contains functions to do field-specific validation on the dynamic settings
#   Functions specified should:
#       - Accept one argument (the value being validated)
#       - an optional second argument (the old value)
#       - an optional third argument (configuration key being validated)
#       - If there is a problem die with a message describing the issue.
sub get_extra_validation {
    my $setting = shift;
    state $setting_validators = {
        'cgi.terms_conditions_version'                               => \&validate_tnc_string,
        'payments.transfer_between_accounts.minimum.by_currency'     => \&_validate_transfer_min_by_currency,
        'payments.transfer_between_accounts.minimum.default.fiat'    => \&_validate_transfer_min_default,
        'payments.transfer_between_accounts.minimum.default.crypto'  => \&_validate_transfer_min_default,
        'payments.transfer_between_accounts.limits.between_accounts' => \&_validate_positive_number,
        'payments.transfer_between_accounts.limits.MT5'              => \&_validate_positive_number,
        'payments.transfer_between_accounts.maximum.default'         => \&_validate_positive_number,
        'payments.payment_limits'                                    => \&_validate_payment_min_by_staff,
    };

    return $setting_validators->{$setting};
}

=head2 _validate_positive_number

Validates the amount to be a positive valid number.

=cut

sub _validate_positive_number {
    my $input_data = shift;
    die "Invalid numerical value $input_data" unless Scalar::Util::looks_like_number($input_data);
    die "$input_data is less than or equal to 0" unless $input_data > 0;
    return;
}

sub _validate_transfer_min_default {
    my ($new_value, $old_value, $key) = @_;

    _validate_positive_number($new_value);

    return unless $key =~ /^payments.transfer_between_accounts.minimum.default.(.*)$/;
    my $type = $1;

    my @currencies = LandingCompany::Registry::all_currencies();
    @currencies = grep {
        LandingCompany::Registry::get_currency_definition($_)->{type} eq 'crypto'
            and (not LandingCompany::Registry::get_currency_definition($_)->{stable})
        } @currencies
        if $type eq 'crypto';
    @currencies = grep {
               LandingCompany::Registry::get_currency_definition($_)->{type} eq 'fiat'
            or LandingCompany::Registry::get_currency_definition($_)->{stable}
        } @currencies
        if $type eq 'fiat';

    my $lower_bounds    = BOM::Config::CurrencyConfig::transfer_between_accounts_lower_bounds();
    my @matching_bounds = map { $lower_bounds->{$_} } @currencies;
    my $lower_bound     = List::Util::max(@matching_bounds);

    die "The value $new_value is lower than the lower bound $lower_bound." if ($new_value < $lower_bound);

    return 1;
}

=head2 _validate_payment_min_by_staff

Validates json string containing the minimum payment limit per staff

=cut

sub _validate_payment_min_by_staff {
    my $input_string = shift;

    my $json_config = JSON::MaybeXS->new->decode($input_string);

    foreach my $user_name (keys %$json_config) {
        my $amount = $json_config->{$user_name};
        die "$user_name 's payment limit entered has a value less than or equal to 0" unless $amount > 0;
    }
    return 1;
}

=head2 _validate_transfer_min_by_currency

Validates json string containing the minimum transfer amount per currency.
It validates currency codes (hash keys) to be supported within the system; also
validates the minimum values to be well-frmatted for displaying.

=cut

sub _validate_transfer_min_by_currency {
    my $new_string = shift;

    my $json_config    = JSON::MaybeXS->new->decode($new_string);
    my @all_currencies = LandingCompany::Registry::all_currencies();

    foreach my $currency (keys %$json_config) {
        die "$currency does not match any valid currency"
            unless grep { $_ eq $currency } @all_currencies;

        my $amount           = $json_config->{$currency};
        my $allowed_decimals = Format::Util::Numbers::get_precision_config()->{price}->{$currency};
        my $rounded_amount   = Format::Util::Numbers::financialrounding('price', $currency, $amount);

        die "Minimum value $amount has more than $allowed_decimals decimals allowed for $currency."
            if length($amount) > 12
            or (sprintf('%0.010f', $rounded_amount) ne sprintf('%0.010f', $amount));

        my $lower_bound = BOM::Config::CurrencyConfig::transfer_between_accounts_lower_bounds()->{$currency};
        die "The value $amount for $currency is lower than the lower bound $lower_bound" if $amount < $lower_bound;
    }
    return 1;
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
    my $staff   = BOM::Backoffice::Auth0::get_staffname();
    my @message = "$enable_disable the following offering:";
    push @message, "$disable_type: " . join(",", @different);
    push @message, "By $staff on " . Date::Utility->new->datetime;

    my $brand = request()->brand;
    my $email_list = join ", ", map { $brand->emails($_) } qw(quants compliance cs marketing_x);

    send_email({
        from    => $brand->emails('system'),
        to      => $email_list,
        subject => $subject,
        message => \@message,
    });

    return;
}
1;
