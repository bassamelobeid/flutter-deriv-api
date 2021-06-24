package BOM::Rules::RuleRepository::User;

=head1 NAME

BOM::Rules::RuleRepositry::User

=head1 DESCRIPTION

Contains rules pertaining the context user.

=cut

use strict;
use warnings;

use LandingCompany::Registry;
use List::Util qw(any);

use BOM::Platform::Context qw(localize);
use BOM::Rules::Registry qw(rule);

rule 'user.has_no_real_clients_without_currency' => {
    description => "Succeeds if currency of all ennabled real accounts of the context landing company are set",
    code        => sub {
        my ($self, $context) = @_;

        die 'Client is missing' unless $context->client;

        my $siblings = $context->client->real_account_siblings_information(
            exclude_disabled_no_currency => 1,
            landing_company              => $context->landing_company,
            include_self                 => 1
        );

        if (my ($loginid_no_curr) = grep { not $siblings->{$_}->{currency} } keys %$siblings) {
            die +{
                error_code => 'SetExistingAccountCurrency',
                params     => $loginid_no_curr
            };
        }

        return 1;
    },
};

rule 'user.currency_is_available' => {
    description => "Succeeds if the selected currency is available for a new account",
    code        => sub {
        my ($self, $context, $args) = @_;

        my $currency       = $args->{currency};
        my $currency_type  = LandingCompany::Registry::get_currency_type($currency);
        my $account_type   = $args->{account_type};
        my $payment_method = $args->{payment_method} // '';

        return 1 unless $currency;

        my @siblings = values $context->client->real_account_siblings_information(
            exclude_disabled_no_currency => 1,
            # TODO: we should not include 'self' when editing a client
            include_self => 1
        )->%*;

        for my $sibling (@siblings) {
            next if $account_type ne $sibling->{account_type};

            # Note: Landing company is matched for trading acccounts only.
            #       Wallet landing company is skipped to keep compatible with with switching from samoa to svg.
            next if $account_type eq 'trading' and $sibling->{landing_company_name} ne $context->landing_company;

            # Only one fiat trading account is allowed
            if ($account_type eq 'trading' && $currency_type eq 'fiat') {
                my $sibling_currency_type = LandingCompany::Registry::get_currency_type($sibling->{currency});
                die +{error_code => 'CurrencyTypeNotAllowed'} if $sibling_currency_type eq 'fiat';
            }

            my $error_code = $sibling->{account_type} eq 'trading' ? 'DuplicateCurrency' : 'DuplicateWallet';
            # Account type, currency and payment method should match
            my $sibling_payment_method = $sibling->{payment_method} // '';
            die +{
                error_code => $error_code,
                params     => $currency
                }
                if $account_type eq $sibling->{account_type}
                and $currency eq ($sibling->{currency} // '')
                and $payment_method eq $sibling_payment_method;
        }

        return 1;
    },
};

rule 'user.email_is_verified' => {
    description => "Checks if email address is verified",
    code        => sub {
        my ($self, $context, $args) = @_;

        die +{
            error_code => 'email unverified',
            }
            unless $context->client->user->email_verified;

        return 1;
    },
};

1;
