package BOM::Rules::RuleRepository::LandingCompany;

=head1 NAME

BOM::Rules::RuleRepositry::landing_company

=head1 DESCRIPTION

This modules declares rules and regulations pertaining the context landing company.

=cut

use strict;
use warnings;

use List::MoreUtils qw(uniq);
use Brands;

use BOM::Platform::Context qw(request);
use BOM::Rules::Registry qw(rule);

rule 'landing_company.accounts_limit_not_reached' => {
    description => "Succeeds if the number of clients on the context landing company less the limit (if there's any such limit); fails otherwise",
    code        => sub {
        my ($self, $context, $args) = @_;

        my $account_type               = $args->{account_type} // '';
        my $number_of_accounts_limited = ($context->landing_company ne 'svg') && ($account_type ne 'wallet');

        return 1 unless $number_of_accounts_limited;

        # only trading accounts are checked. There is no limit on wallet accounts.
        my @clients = $context->client->user->clients_for_landing_company($context->landing_company);
        @clients = grep { not($_->status->disabled or $_->status->duplicate_account) } @clients;

        return 1 unless scalar @clients;

        die +{error_code => 'FinancialAccountExists'} if $context->landing_company eq 'maltainvest';
        die +{error_code => 'NewAccountLimitReached'};
    },
};

rule 'landing_company.required_fields_are_non_empty' => {
    description => "Succeeds if all required fields of the context landing company are non-empty; fails otherwise",
    code        => sub {
        my ($self, $context, $args) = @_;

        my $client = $context->client_switched;

        my @required_fields = ($context->landing_company_object->requirements->{signup} // [])->@*;
        my @missing = grep { not $args->{$_} // $client->$_ } uniq @required_fields;

        # TODO: better to be configured in landing company config
        if (($args->{account_type} // '') eq 'wallet') {
            my @missing_wallet_fields = grep { not $args->{$_} } (qw/currency payment_method/);
            push @missing, @missing_wallet_fields;
        }

        die +{
            error_code => 'InsufficientAccountDetails',
            details    => {missing => [@missing]},
        } if @missing;

        return 1;
    },
};

rule 'landing_company.currency_is_allowed' => {
    description => "Succeeds if the currency in args is allowed in the context landing company; fails otherwise",
    code        => sub {
        my ($self, $context, $args) = @_;
        return 1 unless $args->{currency};

        my $landing_company_object = $context->landing_company_object;

        my $account_type = $args->{account_type} // '';
        # Allowed currencies for wallet account opening should be figured out by country of residence rather than the context landing company (svg).
        if ($account_type eq 'wallet') {
            my $countries_instance = Brands->new->countries_instance;
            my $company            = $countries_instance->gaming_company_for_country($context->client->residence)
                // $countries_instance->gaming_company_for_country($context->client->residence) // '';

            $landing_company_object = LandingCompany::Registry->new->get($company);
        }

        die +{
            error_code => 'CurrencyNotApplicable',
            params     => $args->{currency},
            }
            unless $landing_company_object->is_currency_legal($args->{currency});

        return 1;
    },
};

rule 'landing_company.p2p_availability' => {
    description => "Checks p2p availablility in the context landing company, if account opening reason is p2p exchange",
    code        => sub {
        my ($self, $context, $args) = @_;

        return 1 unless $args->{account_opening_reason};

        die +{error_code => 'P2PRestrictedCountry'}
            if !$context->landing_company_object->p2p_available && ($args->{account_opening_reason} =~ qr/p2p/i);

        return 1;
    },
};

1;
