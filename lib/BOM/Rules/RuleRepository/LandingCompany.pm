package BOM::Rules::RuleRepository::LandingCompany;

=head1 NAME

BOM::Rules::RuleRepositry::landing_company

=head1 DESCRIPTION

This modules declares rules and regulations pertaining the context landing company.

=cut

use strict;
use warnings;

use BOM::Platform::Context qw(request);
use BOM::Rules::Registry qw(rule);

rule 'landing_company.accounts_limit_not_reached' => {
    description => "Succeeds if the number of clients on the context landing company less the limit (if there's any such limit); fails otherwise",
    code        => sub {
        my ($self, $context) = @_;

        my $number_of_accounts_limit = $context->landing_company ne 'svg';

        my @clients = $context->client->user->clients_for_landing_company($context->landing_company);
        @clients = grep { not($_->status->disabled or $_->status->duplicate_account) } @clients;

        return 1 unless $number_of_accounts_limit;
        return 1 if scalar @clients < $number_of_accounts_limit;

        die +{code => 'FinancialAccountExists'} if $context->landing_company eq 'maltainvest';
        die +{code => 'NewAccountLimitReached'};
    },
};

rule 'landing_company.required_fields_are_non_empty' => {
    description => "Succeeds if all required fields of the context landing company are non-empty; fails otherwise",
    code        => sub {
        my ($self, $context, $args) = @_;

        my @missing = grep { !$args->{$_} } $context->landing_company_object->requirements->{signup}->@*;
        die +{
            code    => 'InsufficientAccountDetails',
            details => {missing => [@missing]},
        } if @missing;

        return 1;
    },
};

rule 'landing_company.currency_is_allowed' => {
    description => "Succeeds if the currency in args is allowed in the context landing company; fails otherwise",
    code        => sub {
        my ($self, $context, $args) = @_;
        return 1 unless $args->{currency};

        die +{
            code   => 'CurrencyTypeNotAllowed',
            params => $args->{currency},
            }
            unless $context->landing_company_object->is_currency_legal($args->{currency});

        return 1;
    },
};

rule 'landing_company.p2p_account_opening_reason' => {
    description => "Checks p2p availablility in the context landing company, if account opening reason is p2p exchange",
    code        => sub {
        my ($self, $context, $args) = @_;

        return 1 unless $args->{account_opening_reason};

        die +{code => 'P2PRestrictedCountry'} if !$context->landing_company_object->p2p_available && ($args->{account_opening_reason} =~ qr/p2p/i);

        return 1;
    },
};

