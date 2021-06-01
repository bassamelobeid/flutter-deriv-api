package BOM::Rules::RuleRepository::Transfers;

=head1 NAME

BOM::Rules::RuleRepositry::Transfers

=head1 DESCRIPTION

This modules declares rules and regulations concerning transfers between accounts

=cut

use strict;
use warnings;
use BOM::Platform::Context qw(request);
use BOM::Rules::Registry qw(rule);
use BOM::Config::Runtime;
use Format::Util::Numbers qw/formatnumber financialrounding/;
use BOM::Config::CurrencyConfig;
use Syntax::Keyword::Try;
use List::Util qw/any/;

rule 'transfers.currency_should_match' => {
    description => "The currency of the account given should match the currency param when defined",
    code        => sub {
        my ($self, $context, $action_args) = @_;

        # only transfer_between_accounts sends this param, trading_platform_* do not send it
        my $currency = $action_args->{currency} // return 1;

        my $action = $action_args->{action} // '';
        my $account_currency;

        if ($action eq 'deposit') {
            $account_currency = $context->client->account->currency_code;
        } elsif ($action eq 'withdrawal') {
            $account_currency = $action_args->{platform_currency};
        } else {
            die +{
                code => 'InvalidAction',
            };
        }

        die +{
            code => 'CurrencyShouldMatch',
        } unless ($account_currency // '') eq $currency;

        return 1;
    },
};

rule 'transfers.daily_limit' => {
    description => "Validates the daily transfer limits for the context client",
    code        => sub {
        my ($self, $context, $action_args) = @_;
        my $platform                  = $action_args->{platform} // '';
        my $daily_transfer_limit      = BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->$platform;
        my $user_daily_transfer_count = $context->client->user->daily_transfer_count($platform);

        die +{
            code           => 'MaximumTransfers',
            message_params => [$daily_transfer_limit]} unless $user_daily_transfer_count < $daily_transfer_limit;

        return 1;
    },
};

rule 'transfers.limits' => {
    description => "Validates the minimum and maximum limits for transfers on the given platform",
    code        => sub {
        my ($self, $context, $action_args) = @_;
        my $brand_name      = request()->brand->name;
        my $platform        = $action_args->{platform} // '';
        my $action          = $action_args->{action}   // '';
        my $amount          = $action_args->{amount}   // '';
        my $transfer_limits = BOM::Config::CurrencyConfig::platform_transfer_limits($platform, $brand_name);
        my $source_currency;

        # limit currency / source currency is always the sending account
        if ($action eq 'deposit') {
            $source_currency = $context->client->account->currency_code;
        } elsif ($action eq 'withdrawal') {
            $source_currency = $action_args->{platform_currency};
        } else {
            die +{code => 'InvalidAction'};
        }

        my $min = $transfer_limits->{$source_currency}->{min};
        my $max = $transfer_limits->{$source_currency}->{max};

        die +{
            code           => 'InvalidMinAmount',
            message_params => [formatnumber('amount', $source_currency, $min), $source_currency]}
            if $amount < financialrounding('amount', $source_currency, $min);

        die +{
            code           => 'InvalidMaxAmount',
            message_params => [formatnumber('amount', $source_currency, $max), $source_currency]}
            if $amount > financialrounding('amount', $source_currency, $max);

        return 1;
    },
};

rule 'transfers.experimental_currency_email_whitelisted' => {
    description => "Validate experimental currencies for whitelisted emails",
    code        => sub {
        my ($self, $context, $action_args) = @_;
        my $client = $context->client;

        if (   BOM::Config::CurrencyConfig::is_experimental_currency($client->account->currency_code)
            or BOM::Config::CurrencyConfig::is_experimental_currency($action_args->{platform_currency}))
        {
            my $allowed_emails = BOM::Config::Runtime->instance->app_config->payments->experimental_currencies_allowed;

            die +{
                code => 'CurrencyTypeNotAllowed',
            } if not any { $_ eq $client->email } @$allowed_emails;
        }

        return 1;
    },
};

1;
