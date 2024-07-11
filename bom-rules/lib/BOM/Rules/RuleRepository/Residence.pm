package BOM::Rules::RuleRepository::Residence;

=head1 NAME

BOM::Rules::RuleRepositry::Residence

=head1 DESCRIPTION

This modules declares rules and regulations concerning the context residence.

=cut

use strict;
use warnings;

use List::Util qw(any);

use BOM::Rules::Registry qw(rule);
use Business::Config::Account::Type::Registry;
use Business::Config::Country::Registry;

rule 'residence.account_type_is_available' => {
    description => "The market_type in args should be allowed in the context residence",
    code        => sub {
        my ($self, $context, $args) = @_;

        my $account_type =
            Business::Config::Account::Type::Registry->new()->account_type_by_name($args->{account_type} // Business::Config::Account::Type::LEGACY);

        $self->fail('InvalidAccount', description => 'Market type or landing company is invalid')
            unless $account_type->is_supported($context->residence($args), $context->landing_company($args));

        return 1;
    },
};

rule 'residence.is_country_enabled' => {
    description => "Checks if country of residence is enabled",
    code        => sub {
        my ($self, $context, $args) = @_;
        my $residence = $context->residence($args);

        my $registry = Business::Config::Country::Registry->new();
        my $country  = $registry->by_code($residence);

        $self->fail('InvalidAccount', description => 'Signup is not allowed for country of residence')
            unless $country && $country->signup->{country_enabled};

        return 1;
    },
};

rule 'residence.account_type_is_available_for_real_account_opening' => {
    description => "Checks if the requested account type is enabled in the country of residence configuration.",
    code        => sub {
        my ($self, $context, $args) = @_;
        my $residence       = $context->residence($args);
        my $landing_company = $context->landing_company($args);

        die 'Account type is required' unless $args->{account_type};
        return 1 if $args->{account_type} eq 'binary';
        return 1 if $args->{account_type} eq 'affiliate';
        return 1 if $args->{account_type} eq 'standard';

        my $registry = Business::Config::Country::Registry->new();
        my $country  = $registry->by_code($residence);

        my $wallet_companies_for_country = [];

        $wallet_companies_for_country = $country->wallet_companies('real') if $country;

        $self->fail('InvalidResidence', description => 'Account type is not available for country of residence')
            unless grep { $_ eq $landing_company } $wallet_companies_for_country->@*;

        return 1;
    },
};

rule 'residence.not_restricted' => {
    description => 'Fails if the context residence is restricted; succeeds otherwise',
    code        => sub {
        my ($self, $context, $args) = @_;
        my $residence = $context->residence($args);

        my $registry = Business::Config::Country::Registry->new();
        my $country  = $registry->by_code($residence);

        $self->fail('InvalidResidence', description => 'Residence country is restricted')
            unless $country && !$country->restricted();

        return 1;
    },
};
