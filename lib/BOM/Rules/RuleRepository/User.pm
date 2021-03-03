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
                code   => 'SetExistingAccountCurrency',
                params => $loginid_no_curr
            };
        }

        return 1;
    },
};

rule 'user.currency_is_available' => {
    description => "Succeeds if the selected currency is available for a new account",
    code        => sub {
        my ($self, $context, $args) = @_;

        my $currency = $args->{currency};
        my $type     = LandingCompany::Registry::get_currency_type($currency);

        return 1 unless $currency;

        my $siblings = $context->client->real_account_siblings_information(
            exclude_disabled_no_currency => 1,
            landing_company              => $context->landing_company,
            include_self                 => 1
        );

        if ($type eq 'fiat') {
            for my $loginid (keys %$siblings) {
                next if LandingCompany::Registry::get_currency_type($siblings->{$loginid}->{currency}) ne 'fiat';
                die +{code => 'CurrencyTypeNotAllowed'};
            }
        }

        die +{
            code   => 'DuplicateCurrency',
            params => $currency
            }
            if any { $currency eq ($siblings->{$_}->{currency} // '') } keys %$siblings;

        return 1;
    },
};
