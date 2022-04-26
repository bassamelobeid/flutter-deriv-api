package BOM::Rules::RuleRepository::LandingCompany;

=head1 NAME

BOM::Rules::RuleRepositry::landing_company

=head1 DESCRIPTION

This modules declares rules and regulations pertaining the context landing company.

=cut

use strict;
use warnings;

use List::MoreUtils qw(uniq);

use LandingCompany::Registry;
use BOM::Rules::Registry qw(rule);

rule 'landing_company.accounts_limit_not_reached' => {
    description => "Only one account (enabled or disabled) is allowed on regulated landing companies. Duplicate account are ignored.",
    code        => sub {
        my ($self, $context, $args) = @_;

        # landing company should not be extracted from context client here
        die 'landing_company is required' unless $args->{landing_company};

        my $client          = $context->client($args);
        my $landing_company = $context->landing_company_object($args);

        my $account_type = $args->{account_type} // '';
        # Regulated landing companies and trading accounts are limitted.
        # Landing companies for affiliates are also limited.
        my $number_of_accounts_limited = ($landing_company->is_eu && ($account_type ne 'wallet')) || $landing_company->is_for_affiliates;

        return 1 unless $number_of_accounts_limited;

        # duplicate should be ignored here; because we want to let new accounts created with a duplicate account existing
        # (it's a common workaround for currency change after deposit).
        my @clients         = grep { not($_->status->duplicate_account) } $client->user->clients_for_landing_company($args->{landing_company});
        my @enabled_clients = grep { not($_->status->disabled) } @clients;

        return 1 unless scalar @clients;

        $self->fail('FinancialAccountExists') if @enabled_clients && $args->{landing_company} eq 'maltainvest';
        $self->fail('NewAccountLimitReached');
    },
};

rule 'landing_company.required_fields_are_non_empty' => {
    description => "Succeeds if all required fields of the context landing company are non-empty; fails otherwise",
    code        => sub {
        my ($self, $context, $args) = @_;

        my $client          = $context->get_real_sibling($args);
        my $landing_company = $context->landing_company_object($args);

        my @required_fields = ($landing_company->requirements->{signup} // [])->@*;

        my @missing = grep { not($args->{$_} // $client->$_) } uniq @required_fields;

        # TODO: better to be configured in landing company config
        if (($args->{account_type} // '') eq 'wallet') {
            my @missing_wallet_fields = grep { not $args->{$_} } (qw/currency payment_method/);
            push @missing, @missing_wallet_fields;
        }

        # Affiliate Landing Company requires extra info
        push @missing, 'affiliate_plan' if $landing_company->is_for_affiliates and not $args->{affiliate_plan};

        $self->fail('InsufficientAccountDetails', details => {missing => [@missing]}) if @missing;

        return 1;
    },
};

rule 'landing_company.currency_is_allowed' => {
    description => "Succeeds if the currency in args is allowed in the context landing company; fails otherwise",
    code        => sub {
        my ($self, $context, $args) = @_;

        my $landing_company_object = $context->landing_company_object($args);
        my $client                 = $context->client($args);

        return 1 unless $args->{currency};

        $self->fail('CurrencyNotApplicable', params => $args->{currency})
            unless $landing_company_object->is_currency_legal($args->{currency});

        return 1;
    },
};

rule 'landing_company.p2p_availability' => {
    description => "Checks p2p availablility in the context landing company, if account opening reason is p2p related",
    code        => sub {
        my ($self, $context, $args) = @_;
        my $landing_company = $context->landing_company_object($args);

        return 1 unless $args->{account_opening_reason};

        $self->fail('P2PRestrictedCountry')
            if !$landing_company->p2p_available
            && ($args->{account_opening_reason} =~ qr/p2p/i or $args->{account_opening_reason} eq 'Peer-to-peer exchange');

        return 1;
    },
};

1;
