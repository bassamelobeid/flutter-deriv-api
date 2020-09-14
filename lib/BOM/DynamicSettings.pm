package BOM::DynamicSettings;

use strict;
use warnings;

use Data::Compare;
use Encode;
use HTML::Entities;
use JSON::MaybeXS;
use Text::CSV;
use Syntax::Keyword::Try;
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

# Limiting minimum amount transferable to 1 USD so it would not hit lowerbound
#The background of this (or lower bound) is to cater for the scenario below:
#
# If someones tries to transfer 0.02 USD to EUR, we impose a transfer fee
# of 0.01 (or 1%, whichever is higher) to it. So the transferable amount
# left is 0.01 USD. And when converted, it is 0.008 EUR, which is lower
# than the minimum unit of EUR, and this will cause an error.
use constant MINIMUM_ALLOWABLE_USD_AMOUNT => 1;

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
                  '<div class="error">FAILED to save global'
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

            $message .= qq~
                <table id="settings_summary" class="collapsed hover" border="1">
                    <tr><th>Validation</th><th>Key Name</th><th>New Value</th><th>Remark</th></tr>~;

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
                        $extra_validation->($new_value, $old_value, $s)     if $extra_validation;
                        send_email_notification($new_value, $old_value, $s) if ($s =~ /quants/ and ($s =~ /suspend/ or $s =~ /disabled/));
                        $values_to_set->{$s} = $new_value;
                        $message .= join('',
                            '<tr class="saved"><td class="status">&#10004;</td><td class="key-name">',
                            encode_entities($s),
                            '</td><td class="value">',
                            encode_entities($display_value),
                            '</td><td>-</td></tr>');
                    }
                } catch {
                    $message .= join('',
                        '<tr class="error"><td class="status">&#10005;</td><td class="key-name">',
                        encode_entities($s), '</td><td class="value">',
                        $settings->{$s},     '</td><td>Invalid value, could not set because <b>',
                        encode_entities($@), '</b></td></tr>');
                    $has_errors = 1;
                }
            }
            $message .= '</table>';

            if ($has_errors) {
                $message .= '<div class="error">NOT saving global settings due to data problems.</div>';
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
                    $message .= '<div class="saved">Saved global settings to environment.</div>';
                } catch {
                    $message .= "<div class='error'>Could not save global settings to environment: $@</div>";
                }
            }
        } else {
            $message .= "<div class='error'>Invalid 'submitted' value <span class='value'>" . encode_entities($submitted) . "</span></div>";
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
                system.suspend.cashier
                system.suspend.new_accounts
                system.suspend.expensive_api_calls
                system.suspend.all_logins
                system.suspend.social_logins
                system.suspend.logins
                system.suspend.transfer_between_accounts
                system.suspend.transfer_currencies
                system.suspend.onfido
                system.suspend.customerio
                system.suspend.p2p
                system.mt5.suspend.all
                system.mt5.suspend.deposits
                system.mt5.suspend.withdrawals
                system.mt5.suspend.auto_Bbook_svg_financial
                )
        ],
        quant => [qw(
                quants.commission.adjustment.global_scaling
                quants.commission.adjustment.per_market_scaling.forex
                quants.commission.adjustment.per_market_scaling.indices
                quants.commission.adjustment.per_market_scaling.commodities
                quants.commission.adjustment.per_market_scaling.synthetic_index
                quants.markets.suspend_buy
                quants.markets.suspend_trades
                quants.contract_types.suspend_buy
                quants.contract_types.suspend_trades
                quants.suspend_deal_cancellation.forex
                quants.suspend_deal_cancellation.synthetic_index
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
                payments.transfer_between_accounts.limits.between_accounts
                payments.transfer_between_accounts.limits.MT5
                payments.transfer_between_accounts.limits.fiat_to_crypto
                payments.transfer_between_accounts.exchange_rate_expiry.fiat
                payments.transfer_between_accounts.exchange_rate_expiry.fiat_holidays
                payments.transfer_between_accounts.exchange_rate_expiry.crypto
                payments.transfer_between_accounts.minimum.default
                payments.transfer_between_accounts.minimum.by_currency
                payments.transfer_between_accounts.maximum.default
                payments.transfer_between_accounts.maximum.MT5
                payments.experimental_currencies_allowed
                )
        ],
        crypto => [qw(
                system.suspend.cryptocashier
                system.suspend.cryptocurrencies
                system.suspend.cryptocurrencies_deposit
                system.suspend.cryptocurrencies_withdrawal
                system.suspend.experimental_currencies
                payments.crypto.deposit_required_confirmations
                payments.crypto.restricted_countries
                payments.crypto.sweep_reserve_balance.BTC
                payments.crypto.sweep_reserve_balance.LTC
                payments.crypto.sweep_reserve_balance.ETH
                payments.crypto_withdrawal_approvals_required
                payments.crypto.withdrawal_processing_max_duration
                payments.transfer_between_accounts.limits.fiat_to_crypto
                payments.transfer_between_accounts.exchange_rate_expiry.crypto
                )
        ],
        # these settings are configured in separate pages. No need to reconfigure them in Dynamic Settings/Others.
        exclude => [qw(
                payments.transfer_between_accounts.fees.default.fiat_fiat
                payments.transfer_between_accounts.fees.default.fiat_crypto
                payments.transfer_between_accounts.fees.default.fiat_stable
                payments.transfer_between_accounts.fees.default.crypto_fiat
                payments.transfer_between_accounts.fees.default.stable_fiat
                payments.transfer_between_accounts.fees.by_currency
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
                payments.p2p.refund_timeout
                )]};

    my $app_config = BOM::Config::Runtime->instance->app_config;

    # Add all `payments.crypto.minimum_safe_amount.*` keys to `crypto`
    my @safe_amount_list = keys $app_config->payments->crypto->minimum_safe_amount->{definition}->{contains}->%*;
    push $group_settings->{crypto}->@*, (map { "payments.crypto.minimum_safe_amount.$_" } @safe_amount_list);

    # Add all `payments.crypto.fee_limit_usd.*` keys to `crypto`
    my @fee_limit_usd_list = keys $app_config->payments->crypto->fee_limit_usd->{definition}->{contains}->%*;
    push $group_settings->{crypto}->@*, (map { "payments.crypto.fee_limit_usd.$_" } @fee_limit_usd_list);

    my $settings;

    if ($group eq 'others') {
        my @grouped_settings = map { @{$group_settings->{$_}} } keys %$group_settings;
        my @all_settings     = $app_config->all_keys();

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
            $input_value   = [@{$input_value}];
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
            $input_value   = [split(/\s+/, $input_value)];
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
        } catch {
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
        'payments.transfer_between_accounts.minimum.default'         => \&_validate_transfer_min_default,
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

    return unless $key eq 'payments.transfer_between_accounts.minimum.default';

    die "The value $new_value is lower than the minimum amount allowed by the system " . MINIMUM_ALLOWABLE_USD_AMOUNT . " USD."
        if ($new_value < MINIMUM_ALLOWABLE_USD_AMOUNT);

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
validates the minimum values to be well-formatted for displaying.

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

        die "The value $amount for $currency is lower " . MINIMUM_ALLOWABLE_USD_AMOUNT . " USD." if $amount < MINIMUM_ALLOWABLE_USD_AMOUNT;
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
    die 'New date is older than previous'    if $new_date->is_before(Date::Utility->new($old_date));

    # No errors
    return;
}

sub send_email_notification {
    my $new_value = shift;
    my $old_value = shift;
    my $for       = shift;

    return if ref $new_value ne 'ARRAY' or ref $old_value ne 'ARRAY';

    my $enable_disable = scalar(@$new_value) > scalar(@$old_value) ? 'Disable' : 'Enable';

    my $subject = "$enable_disable Asset/Product Notification. ";

    my @different = array_diff(@$new_value, @$old_value);

    my $disable_type =
          ($for =~ /quants\.contract_types\.suspend_(?:buy|trades)/) ? 'Contract_type'
        : ($for =~ /quants\.markets\.suspend_(?:buy|trades)/)        ? 'Market'
        :                                                              'Underlying';
    my $staff   = BOM::Backoffice::Auth0::get_staffname();
    my @message = "$enable_disable the following offering:";
    push @message, "$disable_type: " . join(",", @different);
    push @message, "By $staff on " . Date::Utility->new->datetime;

    my $brand      = request()->brand;
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
