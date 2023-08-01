package BOM::DynamicSettings;

use strict;
use warnings;
use Data::Compare;
use Encode;
use HTML::Entities;
use JSON::MaybeXS;
use Text::CSV;
use Text::Trim;
use Syntax::Keyword::Try;
use feature 'state';
use LandingCompany::Registry;
use Format::Util::Numbers qw/formatnumber/;
use Array::Utils          qw(:all);
use Date::Utility;
use Scalar::Util;
use List::Util qw(any max);
use BOM::Backoffice::QuantsAuditLog;
use BOM::Platform::Email qw(send_email);
use BOM::Config::Runtime;
use BOM::Config::Chronicle;
use BOM::Config::CurrencyConfig;
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::Auth0;
use Brands;

=head1 NAME

BOM::DynamicSettings

=cut

# Limiting minimum amount transferable to 1 USD so it would not hit lowerbound
#The background of this (or lower bound) is to cater for the scenario below:
#
# If someones tries to transfer 0.02 USD to EUR, we impose a transfer fee
# of 0.01 (or 1%, whichever is higher) to it. So the transferable amount
# left is 0.01 USD. And when converted, it is 0.008 EUR, which is lower
# than the minimum unit of EUR, and this will cause an error.
use constant MINIMUM_ALLOWABLE_USD_AMOUNT => 1;

use constant AUTHORISATIONS => {
    shutdown_suspend     => ['IT'],
    quant                => ['Quants'],
    it                   => ['IT'],
    others               => ['IT'],
    payments             => ['IT'],
    crypto               => ['IT'],
    compliance           => ['Compliance'],
    payment_agents       => ['IT'],
    terms_and_conditions => ['T&C'],
};

sub _textify_obj {
    my $type  = shift;
    my $value = shift;
    return ($type eq 'ArrayRef') ? join(',', @$value) : $value;
}

=head2 save_settings

Store the given settings.

It expects a HASHREF with the following attributes.

=over 4

=item * C<settings> - A HASHREF.

=item * C<save> - A STRING with the submitted value.

=item * C<settings_in_group> - A HASHREF.

=back

It returns C<1> if stored settings successfully or C<0> otherwise.

=cut

sub save_settings {
    my $args              = shift;
    my $settings          = $args->{settings};
    my $submitted         = $args->{save};
    my $settings_in_group = $args->{settings_in_group};

    my $message = "";
    my $success = 0;

    if ($submitted) {
        my $app_config = BOM::Config::Runtime->instance->app_config;
        # pass in the writer before setting any config
        $app_config->chronicle_writer(BOM::Config::Chronicle::get_audited_chronicle_writer(BOM::Backoffice::Auth0::get_staffname()));

        my $setting_revision   = $app_config->global_revision();
        my $submitted_revision = $settings->{'revision'};
        if ($setting_revision ne $submitted_revision) {
            $message .=
                  '<div class="notify notify--warning">FAILED to save global'
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
                <table id="settings_summary" class="collapsed hover border center">
                    <thead><tr><th>Validation</th><th>Key Name</th><th>New Value</th><th>Remark</th></tr></thead>~;

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
                            '<tbody><tr class="saved"><td class="status">&#10004;</td><td class="key-name">',
                            encode_entities($s),
                            '</td><td class="value">',
                            encode_entities($display_value),
                            '</td><td>-</td></tr>');
                    }
                } catch ($e) {
                    $message .= join('',
                        '<tr class="error"><td class="status">&#10005;</td><td class="key-name">',
                        encode_entities($s), '</td><td class="value">',
                        $settings->{$s},     '</td><td>Invalid value, could not set because ',
                        encode_entities($e), '</td></tr>');
                    $has_errors = 1;
                }

            }
            $message .= '</tbody></table>';

            if ($has_errors) {
                $message .= '<div class="notify notify--warning center">NOT saving global settings due to data problems.</div>';
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
                    $message .= '<p class="notify center">Saved global settings to environment.</p>';
                    $success = 1;
                } catch ($e) {
                    $message .= "<p class='notify notify--warning center'>Could not save global settings to environment: $e</p>";
                }
            }
        } else {
            $message .=
                  "<div class='notify notify--warning center'>Invalid 'submitted' value <span class='value'>"
                . encode_entities($submitted)
                . "</span></div>";
        }

        print $message;
    }

    return $success;
}

=head2 generate_settings_branch

Builds dynamic settings structure to be used in templates.

=cut

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

        my $default_text = _textify_obj($data_type, $default);
        my $value_text   = _textify_obj($data_type, $value);

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
        $ds_leaf->{default}       = $value_text eq $default_text if $default_text;
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

=head2 get_settings_by_group

Contains the grouping of chronicle variables for displaying it on the Backoffice.

=cut

sub get_settings_by_group {
    my $group          = shift;
    my $group_settings = {
        shutdown_suspend => [qw(
                system.suspend.trading
                system.suspend.payments
                system.suspend.payments_graceful
                system.suspend.payment_agents
                system.suspend.payment_agent_withdrawal_automation
                system.suspend.cashier
                system.suspend.new_accounts
                system.suspend.expensive_api_calls
                system.suspend.all_logins
                system.suspend.social_logins
                system.suspend.logins
                system.suspend.transfer_between_accounts
                system.suspend.transfer_currencies
                system.suspend.onfido
                system.suspend.p2p
                system.suspend.wallets
                system.suspend.idv
                system.suspend.idv_countries
                system.suspend.idv_providers
                system.suspend.idv_document_types
                system.onfido.global_daily_limit
                system.suspend.access_token_sharing
                system.mt5.load_balance.demo.all.p01_ts01
                system.mt5.load_balance.demo.all.p01_ts02
                system.mt5.load_balance.demo.all.p01_ts03
                system.mt5.load_balance.demo.all.p01_ts04
                system.mt5.load_balance.real.all.p01_ts01
                system.mt5.load_balance.real.europe_synthetic.p01_ts04
                system.mt5.load_balance.real.africa_synthetic.p02_ts02
                system.mt5.load_balance.real.africa_derivez.p02_ts01
                system.mt5.load_balance.real.africa_synthetic.p01_ts02
                system.mt5.load_balance.real.asia_synthetic.p01_ts03
                system.mt5.suspend.all
                system.mt5.suspend.deposits
                system.mt5.suspend.withdrawals
                system.mt5.suspend.auto_Bbook_svg_financial
                system.mt5.suspend.auto_Bbook_bvi_financial
                system.mt5.suspend.demo.p01_ts01.all
                system.mt5.suspend.demo.p01_ts02.all
                system.mt5.suspend.demo.p01_ts03.all
                system.mt5.suspend.demo.p01_ts04.all
                system.mt5.suspend.real.p01_ts01.all
                system.mt5.suspend.real.p01_ts01.deposits
                system.mt5.suspend.real.p01_ts01.withdrawals
                system.mt5.suspend.real.p01_ts02.all
                system.mt5.suspend.real.p01_ts02.deposits
                system.mt5.suspend.real.p01_ts02.withdrawals
                system.mt5.suspend.real.p01_ts03.all
                system.mt5.suspend.real.p01_ts03.deposits
                system.mt5.suspend.real.p01_ts03.withdrawals
                system.mt5.suspend.real.p01_ts04.all
                system.mt5.suspend.real.p01_ts04.deposits
                system.mt5.suspend.real.p01_ts04.withdrawals
                system.mt5.suspend.real.p02_ts01.all
                system.mt5.suspend.real.p02_ts01.deposits
                system.mt5.suspend.real.p02_ts01.withdrawals
                system.mt5.suspend.real.p02_ts02.all
                system.mt5.suspend.real.p02_ts02.deposits
                system.mt5.suspend.real.p02_ts02.withdrawals
                system.suspend.payout_freezing_funds
                system.suspend.universal_password
                system.dxtrade.suspend.all
                system.dxtrade.http_proxy.demo
                system.dxtrade.http_proxy.real
                system.dxtrade.suspend.demo
                system.dxtrade.suspend.real
                system.dxtrade.suspend.user_exceptions
                system.services.fraud_prevention
                system.services.identity_verification
                system.suspend.ctrader_oauth_api
                system.ctrader.suspend.all
                system.ctrader.suspend.demo
                system.ctrader.suspend.real
                system.ctrader.suspend.deposits
                system.ctrader.suspend.withdrawals
                system.ctrader.suspend.user_exceptions
                system.backoffice.disable_auth0_login
            )
        ],
        quant => [qw(
                quants.commission.adjustment.global_scaling
                quants.commission.adjustment.per_market_scaling.forex
                quants.commission.adjustment.per_market_scaling.indices
                quants.commission.adjustment.per_market_scaling.commodities
                quants.commission.adjustment.per_market_scaling.synthetic_index
                quants.commission.adjustment.lookback.stake_percentage_commission
                quants.markets.suspend_buy
                quants.markets.suspend_trades
                quants.markets.suspend_early_sellback
                quants.contract_types.suspend_buy
                quants.contract_types.suspend_trades
                quants.contract_types.suspend_early_sellback
                quants.suspend_deal_cancellation.forex
                quants.suspend_deal_cancellation.synthetic_index
                quants.suspend_deal_cancellation.cryptocurrency
                quants.underlyings.disable_autoupdate_vol
                quants.underlyings.suspend_buy
                quants.underlyings.suspend_trades
                quants.underlyings.suspend_early_sellback
                quants.callputspreads.disable_sellback
                quants.callputspreads.minimum_allowed_sellback_duration
            )
        ],
        it => [qw(
                cgi.allowed_languages
                oauth.ctrader_api.white_listed_networks
            )
        ],
        terms_and_conditions => [qw(
                cgi.terms_conditions_versions
            )

        ],
        payments => [qw(
                payments.payment_limits
                payments.transfer_between_accounts.daily_cumulative_limit.enable
                payments.transfer_between_accounts.daily_cumulative_limit.between_accounts
                payments.transfer_between_accounts.daily_cumulative_limit.MT5
                payments.transfer_between_accounts.daily_cumulative_limit.dxtrade
                payments.transfer_between_accounts.daily_cumulative_limit.derivez
                payments.transfer_between_accounts.daily_cumulative_limit.ctrader
                payments.transfer_between_accounts.limits.between_accounts
                payments.transfer_between_accounts.limits.MT5
                payments.transfer_between_accounts.limits.dxtrade
                payments.transfer_between_accounts.limits.fiat_to_crypto
                payments.transfer_between_accounts.limits.crypto_to_fiat
                payments.transfer_between_accounts.limits.crypto_to_crypto
                payments.transfer_between_accounts.limits.ctrader
                payments.transfer_between_accounts.limits.derivez
                payments.transfer_between_accounts.exchange_rate_expiry.fiat
                payments.transfer_between_accounts.exchange_rate_expiry.fiat_holidays
                payments.transfer_between_accounts.exchange_rate_expiry.crypto
                payments.transfer_between_accounts.minimum.default
                payments.transfer_between_accounts.minimum.MT5
                payments.transfer_between_accounts.minimum.dxtrade
                payments.transfer_between_accounts.minimum.ctrader
                payments.transfer_between_accounts.minimum.derivez
                payments.transfer_between_accounts.maximum.default
                payments.transfer_between_accounts.maximum.MT5
                payments.transfer_between_accounts.maximum.dxtrade
                payments.transfer_between_accounts.maximum.ctrader
                payments.transfer_between_accounts.maximum.derivez
                payments.experimental_currencies_allowed
                payments.reversible_balance_limits.ctc
                payments.reversible_balance_limits.p2p
                payments.reversible_deposits_lookback
                payments.custom_payment_accounts_limit_per_user
                payments.autoapproval.max_pending_total_enabled
                payments.autoapproval.max_pending_total
                payments.autoapproval.grouped_allowed_payment_methods
                payments.autoapproval.check_most_used_payment_method_enabled
                payments.autoapproval.payment_methods_withdrawal_unsupported
                payments.autoapproval.restricted_client_statuses
                payments.autoapproval.max_profit_day_enabled
                payments.autoapproval.max_profit_day
                payments.autoapproval.max_profit_month_enabled
                payments.autoapproval.max_profit_month
                payments.autoapproval.min_pending_total_to_check_rule_5_enabled
                payments.autoapproval.min_pending_total_to_check_rule_5
                payments.autoapproval.min_last_doughflow_deposit_percent_vs_mt5_transfers_enabled
                payments.autoapproval.min_last_doughflow_deposit_percent_vs_mt5_transfers
                payments.autoapproval.min_last_doughflow_deposit_percent_vs_contracts_bought_enabled
                payments.autoapproval.min_last_doughflow_deposit_percent_vs_contracts_bought
                payments.autoapproval.max_mt5_net_transfer_enabled
                payments.autoapproval.max_mt5_net_transfer
                payments.autoapproval.disabled_sportsbooks
                payments.autoapproval.cft.payment_methods
                payments.autoapproval.cft.max_pending_total_enabled
                payments.autoapproval.cft.max_pending_total
                payments.autoapproval.cft.restricted_client_statuses
                payments.autoapproval.cft.max_profit_day_enabled
                payments.autoapproval.cft.max_profit_day
                payments.autoapproval.cft.max_profit_month_enabled
                payments.autoapproval.cft.max_profit_month
                payments.autoapproval.cft.min_last_doughflow_deposit_percent_vs_mt5_transfers_enabled
                payments.autoapproval.cft.min_last_doughflow_deposit_percent_vs_mt5_transfers
                payments.autoapproval.cft.min_last_doughflow_deposit_percent_vs_contracts_bought_enabled
                payments.autoapproval.cft.min_last_doughflow_deposit_percent_vs_contracts_bought
                payments.autoapproval.cft.max_mt5_net_transfer_enabled
                payments.autoapproval.cft.max_mt5_net_transfer
                payments.p2p_withdrawal_limit
                payments.p2p_deposits_lookback
                payments.payment_methods_with_poo
            )
        ],
        crypto => [qw(
                system.suspend.cryptocashier
                system.suspend.cryptocurrencies
                system.suspend.cryptocurrencies_deposit
                system.suspend.cryptocurrencies_withdrawal
                system.suspend.experimental_currencies
                payments.crypto.restricted_countries
                payments.crypto.auto_update.approve
                payments.crypto.auto_update.reject
                payments.crypto.auto_update.stable_payment_methods
                payments.crypto.auto_update.approve_dry_run
                payments.crypto.auto_update.reject_dry_run
                payments.crypto.stablecoin.bounds.min
                payments.crypto.stablecoin.bounds.max
                payments.transfer_between_accounts.limits.fiat_to_crypto
                payments.transfer_between_accounts.limits.crypto_to_crypto
                payments.transfer_between_accounts.limits.crypto_to_fiat
                payments.transfer_between_accounts.exchange_rate_expiry.crypto
            )
        ],
        compliance => [qw(
                compliance.fake_names.corporate_patterns
                compliance.fake_names.accepted_consonant_names
                compliance.payment_agents.standard_risk_level
                compliance.payment_agents.high_risk_level
                compliance.sanctions.hmt_consolidated_url
                compliance.enhanced_due_diligence.auto_lock
                compliance.enhanced_due_diligence.auto_lock_threshold
                compliance.auto_anonymization_daily_limit
                compliance.npj_country_list
            )
        ],
        # these settings are configured in separate pages. No need to reconfigure them in Dynamic Settings/Others.
        exclude => [qw(
                payments.transfer_between_accounts.fees.default.fiat_fiat
                payments.transfer_between_accounts.fees.default.fiat_crypto
                payments.transfer_between_accounts.fees.default.fiat_stable
                payments.transfer_between_accounts.fees.default.crypto_crypto
                payments.transfer_between_accounts.fees.default.crypto_fiat
                payments.transfer_between_accounts.fees.default.crypto_stable
                payments.transfer_between_accounts.fees.default.stable_crypto
                payments.transfer_between_accounts.fees.default.stable_fiat
                payments.transfer_between_accounts.fees.default.stable_stable
                payments.transfer_between_accounts.fees.by_currency
                payments.p2p.create_order_chat
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
                payments.p2p.payment_method_countries
                payments.p2p.archive_ads_days
                payments.p2p.delete_ads_days
                payments.payment_methods.high_risk
                payments.p2p.payment_methods_enabled
                payments.p2p.country_advert_config
                payments.p2p.currency_config
                payments.p2p.float_rate_global_max_range
                payments.p2p.float_rate_order_slippage
                payments.p2p.email_campaign_ids
                payments.p2p.review_period
                payments.p2p.transaction_verification_countries
                payments.p2p.transaction_verification_countries_all
                payments.p2p.feature_level
                payment_agents.initial_deposit_per_country
                payments.payments_limit
                payments.p2p.block_trade.enabled
                payments.p2p.block_trade.maximum_advert
                payments.p2p.cross_border_ads_restricted_countries
                payments.p2p.fiat_deposit_restricted_countries
                payments.p2p.fiat_deposit_restricted_lookback
            )]};

    my $settings;

    if ($group eq 'others') {
        my @grouped_settings = map { @{$group_settings->{$_}} } keys %$group_settings;
        my @all_settings     = BOM::Config::Runtime->instance->app_config->all_keys();

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
        } catch ($e) {
            die 'JSON string is not well-formatted: $e';
        }
    } elsif ($type eq 'Num') {
        die "Value '$input_value' is not a valid number." unless Scalar::Util::looks_like_number($input_value);
    } elsif ($type eq 'Int') {
        die "Value '$input_value' is not a valid integer." unless Scalar::Util::looks_like_number($input_value) && $input_value =~ /^[0-9]+$/;
    }

    $display_value = $input_value /= 1 if $type eq 'Num' || $type eq 'Int';    # cast string into a num scalar.

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
        'cgi.terms_conditions_versions'                              => \&_validate_tnc_string,
        'payments.transfer_between_accounts.minimum.default'         => \&_validate_transfer_min_default,
        'payments.transfer_between_accounts.minimum.MT5'             => \&_validate_transfer_trading_platform,
        'payments.transfer_between_accounts.minimum.dxtrade'         => \&_validate_transfer_trading_platform,
        'payments.p2p.limits.maximum_advert'                         => \&_validate_positive_number,
        'payments.p2p.limits.maximum_order'                          => \&_validate_positive_number,
        'payments.p2p.restricted_countries'                          => \&_validate_countries,
        'payments.p2p.cross_border_ads_restricted_countries'         => \&_validate_countries,
        'payments.p2p.transaction_verification_countries'            => \&_validate_countries,
        'payments.p2p.fiat_deposit_restricted_countries'             => \&_validate_countries,
        'payments.transfer_between_accounts.limits.between_accounts' => \&_validate_positive_number,
        'payments.transfer_between_accounts.limits.MT5'              => \&_validate_positive_number,
        'payments.transfer_between_accounts.limits.dxtrade'          => \&_validate_positive_number,
        'payments.transfer_between_accounts.maximum.default'         => \&_validate_positive_number,
        'payments.transfer_between_accounts.maximum.MT5'             => \&_validate_transfer_trading_platform,
        'payments.transfer_between_accounts.maximum.dxtrade'         => \&_validate_transfer_trading_platform,
        'payments.payment_limits'                                    => \&_validate_payment_min_by_staff,
        'compliance.fake_names.corporate_patterns'                   => \&_validate_corporate_patterns,
        'compliance.fake_names.accepted_consonant_names'             => \&_validate_accepted_consonant_names,
        'compliance.auto_anonymization_daily_limit'                  => \&_validate_positive_number,
    };

    return $setting_validators->{$setting};
}

=head2 _validate_corporate_patterns

Only aphabetic characters, . and % (wildcard) are acceptable for corporate name patterns.

=cut

sub _validate_corporate_patterns {
    my $values = shift;

    for my $value (@$values) {
        die "Invalid keyword '$value' found. No alphabetic character was found."                                 unless $value =~ qr/\p{L}/;
        die "Invalid keyword '$value' found. Only alphabetic characters, . and % (wildcard) are allowed"         unless $value =~ qr/^[\p{L}\.%]+$/;
        die "Invalid keyword '$value' found. Each keyword should begin either with an alphabetic character or %" unless $value =~ qr/^[\p{L}%]/;
        die "Invalid keyword '$value' found. % is only allowed at the beginning or the end of a keyword" if $value =~ qr/.+%.+/;
    }
    return;
}

=head2 _validate_accepted_consonant_names

Only alphabetic characters are allowed for accepted consonant names.

=cut

sub _validate_accepted_consonant_names {
    my $values = shift;

    # remove redundant spaces
    $values = [map { trim($_ =~ s/\s+/ /gr) } @$values];

    for my $value (@$values) {
        die "Invalid keyword '$value' found. Only alphabetic characters and space are allowed" unless $value =~ qr/^[\p{L} ]+$/;
    }

    return;
}

=head2 _validate_positive_number

Validates the amount to be a positive valid number.

=cut

sub _validate_positive_number {
    my $input_data = shift;
    die "Invalid numerical value $input_data"    unless Scalar::Util::looks_like_number($input_data);
    die "$input_data is less than or equal to 0" unless $input_data > 0;
    return;
}

=head2 _validate_countries

Check if country code provided is valid.

=cut

sub _validate_countries {
    my ($new_value, undef, $key) = @_;
    my %counter;
    die "duplicate values added to $key" if grep { ++$counter{$_} == 2 } $new_value->@*;
    die "invalid format of country code added to $key. Make sure it is a 2 letter lower case country code"
        if any { ($_ !~ m/^[a-z]{2}$/) } $new_value->@*;
    my $countries = Brands->new->countries_instance->countries_list;
    die "non-existent country code added to $key" if any { (!$countries->{$_}) } $new_value->@*;
    return 1;
}

sub _validate_transfer_min_default {
    my ($new_value, $old_value, $key) = @_;

    _validate_positive_number($new_value);

    return unless $key eq 'payments.transfer_between_accounts.minimum.default';

    die "The value $new_value is lower than the minimum amount allowed by the system " . MINIMUM_ALLOWABLE_USD_AMOUNT . " USD."
        if ($new_value < MINIMUM_ALLOWABLE_USD_AMOUNT);

    return 1;
}

=head2 _validate_transfer_trading_platform

Validates json string containing the maximum/minimum trading platform transfer limit per brand

=cut

sub _validate_transfer_trading_platform {
    my $input_string = shift;

    my $json_config    = JSON::MaybeXS->new->decode($input_string);
    my @all_currencies = LandingCompany::Registry::all_currencies();

    foreach my $brand (keys %$json_config) {
        my $brand_config = $json_config->{$brand};
        die "$brand should be an object contain the currency and the amount." unless ref $brand_config eq 'HASH';

        my $amount = $brand_config->{amount};
        die "The amount is less or equal to 0 for $brand config." unless $amount && $amount > 0;

        my $currency = $brand_config->{currency};
        die "$currency does not match any valid currency" unless any { $_ eq $currency } @all_currencies;
    }
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

sub _validate_tnc_string {
    my ($new_string, $old_string) = @_;

    my $new_config = JSON::MaybeXS->new->decode($new_string);
    my $old_config = JSON::MaybeXS->new->decode($old_string);

    state $tnc_string_format = qr/^Version ([0-9\.]+) ([0-9]{4}-[0-9]{2}-[0-9]{2})$/;

    for my $brand (keys %$new_config) {
        my $new_val = $new_config->{$brand};

        # Check expected date format
        die "incorrect format for $brand (must be Version X yyyy-mm-dd)\n"
            unless my ($version, $date) = $new_val =~ $tnc_string_format;

        # Date needs to be valid (will die if not)
        my $new_date = Date::Utility->new($date);

        # Date shouldn't be in the future
        die "date for $brand is in the future\n" if $new_date->is_after(Date::Utility::today);

        if (my $old_val = $old_config->{$brand}) {
            # Shouldn't go backward from old
            die "existing version for $brand failed validation. Please raise with IT.\n"
                unless my ($old_version, $old_date) = $old_val =~ $tnc_string_format;

            die "new date for $brand is older than previous\n" if $new_date->is_before(Date::Utility->new($old_date));

            # Break down each version by dot and compare each correspondant chunk
            my @new = split(/\./, $version);
            my @old = split(/\./, $old_version);

            # This let migrate boring integer versions into funny semantic versioning
            return if scalar @new > scalar @old;

            my $is_valid = sub {
                my $args = shift;
                my @new  = $args->{new}->@*;
                my @old  = $args->{old}->@*;
                my $len  = max(scalar @new, scalar @old);

                # The leading numbers are always the most relevant regardless of array length
                for my $i (0 .. $len) {
                    my $new = $new[$i] // 0;
                    my $old = $old[$i] // 0;
                    # If the leading numbers are different we can take an early decision
                    return 1 if $old < $new;
                    return 0 if $old > $new;
                }

                # Equal versions should pass
                return 1;
            };

            die "version for $brand is lower than previous\n" unless $is_valid->({
                old => \@old,
                new => \@new,
            });
        }
    }

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
    my $email_list = join ", ", map { $brand->emails($_) } qw(quants compliance_regs cs marketing_x);

    send_email({
        from    => $brand->emails('system'),
        to      => $email_list,
        subject => $subject,
        message => \@message,
    });

    return;
}

1;
