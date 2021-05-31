package BOM::Rules::RuleRepository::Currency;

=head1 NAME

BOM::Rules::RuleRepositry::Currency

=head1 DESCRIPTION

This modules declares rules and regulations concerning client's account currency.

=cut

use strict;
use warnings;

use Syntax::Keyword::Try;
use List::Util qw(any);

use LandingCompany::Registry;
use BOM::Platform::Context qw(request);
use BOM::Rules::Registry qw(rule);
use BOM::Config::CurrencyConfig;

rule 'currency.is_currency_suspended' => {
    description => "Fails if currency is suspended or invalid; otherwise passes.",
    code        => sub {
        my ($self, $context, $args) = @_;

        return 1 unless $args->{currency};
        my $currency = $args->{currency};

        my $type = LandingCompany::Registry::get_currency_type($currency);

        return 1 if $type eq 'fiat';

        my $error;
        try {
            $error = 'CurrencySuspended'
                if BOM::Config::CurrencyConfig::is_crypto_currency_suspended($currency);
        } catch {
            $error = 'InvalidCryptoCurrency';
        };

        die +{
            code   => $error,
            params => $currency,
        } if $error;

        return 1;
    },
};

rule 'currency.experimental_currency' => {
    description => "Fails the currency is experimental and the client's email is not whitlisted for experimental currencies.",
    code        => sub {
        my ($self, $context, $args) = @_;

        return 1 unless exists $args->{currency};

        if (BOM::Config::CurrencyConfig::is_experimental_currency($args->{currency})) {
            my $allowed_emails = BOM::Config::Runtime->instance->app_config->payments->experimental_currencies_allowed;
            my $client_email   = $context->client->email;
            die +{code => 'ExperimentalCurrency'} if not any { $_ eq $client_email } @$allowed_emails;
        }

        return 1;
    },
};
