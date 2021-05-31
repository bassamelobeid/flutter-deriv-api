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
use ExchangeRates::CurrencyConverter qw/convert_currency/;
use List::Util qw/any/;

rule 'transfers.currency_required' => {
    description => "Should contain a currency in the arguments",
    code        => sub {
        my ($self, $context, $action_args) = @_;

        $action_args->{currency} || die +{
            code => 'CurrencyRequired',
        };

        return 1;
    },
};

rule 'transfers.currency_should_match' => {
    description => "The currency of the account given should match the currency param given",
    code        => sub {
        my ($self, $context, $action_args) = @_;

        my $action = $action_args->{action} // '';
        my $currency;

        if ($action eq 'deposit') {
            $currency = $action_args->{from_currency} // '';
        } elsif ($action eq 'withdrawal') {
            $currency = $action_args->{to_currency} // '';
        } else {
            die +{
                code => 'InvalidAction',
            };
        }

        die +{
            code => 'CurrencyShouldMatch',
        } unless $currency eq $context->client->account->currency_code;

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
        my $brand_name        = request()->brand->name;
        my $platform          = $action_args->{platform} // '';
        my $action            = $action_args->{action}   // '';
        my $platform_currency = $action_args->{currency} // '';
        my $amount            = $action_args->{amount}   // '';
        my $transfer_limits   = BOM::Config::CurrencyConfig::platform_transfer_limits($platform, $brand_name);
        my $min;
        my $max;
        my $local_currency;
        my $source_currency;
        my $rate_expiry;

        try {
            if ($action eq 'deposit') {
                $local_currency  = $action_args->{from_currency};
                $source_currency = $local_currency;
                $rate_expiry     = BOM::Config::CurrencyConfig::rate_expiry($local_currency, $platform_currency);
                $min = convert_currency($transfer_limits->{$platform_currency}->{min}, $platform_currency, $local_currency, $rate_expiry) || die;
                $max = convert_currency($transfer_limits->{$platform_currency}->{max}, $platform_currency, $local_currency, $rate_expiry) || die;
            } elsif ($action eq 'withdrawal') {
                $local_currency  = $action_args->{to_currency};
                $source_currency = $platform_currency;
                $min             = $transfer_limits->{$platform_currency}->{min};
                $max             = $transfer_limits->{$platform_currency}->{max};
            } else {
                die +{code => 'InvalidAction'};
            }
        } catch ($error) {
            die $error if (ref($error) // '') eq 'HASH' && defined $error->{code};
            die +{code => 'PlatformTransferTemporarilyUnavailable'};
        }

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
        my ($self, $context, $args) = @_;
        my $client = $context->client;
        my $action = $args->{action} // '';
        my $currency;

        if ($action eq 'deposit') {
            $currency = $args->{from_currency};
        } elsif ($action eq 'withdrawal') {
            $currency = $args->{to_currency};
        } else {
            die +{code => 'InvalidAction'};
        }

        if (BOM::Config::CurrencyConfig::is_experimental_currency($currency)) {
            my $allowed_emails = BOM::Config::Runtime->instance->app_config->payments->experimental_currencies_allowed;
            my $client_email   = $client->email;

            die +{
                code => 'CurrencyTypeNotAllowed',
            } if not any { $_ eq $client_email } @$allowed_emails;
        }

        return 1;
    },
};

1;
