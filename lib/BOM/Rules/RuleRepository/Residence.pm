package BOM::Rules::RuleRepository::Residence;

=head1 NAME

BOM::Rules::RuleRepositry::Residence

=head1 DESCRIPTION

This modules declares rules and regulations concerning the context residence.

=cut

use strict;
use warnings;

use List::Util;
use Brands;

use BOM::Rules::Registry qw(rule);

rule 'residence.market_type_is_available' => {
    description => "The market_type in args should be allowed in the context residence",
    code        => sub {
        my ($self, $context, $action_args) = @_;
        my $market_type  = $action_args->{market_type}  // '';
        my $account_type = $action_args->{account_type} // '';

        my $countries_instance = Brands->new->countries_instance;

        my $companies = {
            synthetic => $countries_instance->gaming_company_for_country($context->residence),
            financial => $countries_instance->financial_company_for_country($context->residence),
        };

        if ($account_type eq 'wallet') {
            die {code => 'InvalidAccount'} unless List::Util::any { $_ } values %$companies;
        } else {
            die {code => 'InvalidAccount'} if $context->landing_company ne ($companies->{$market_type} // '');
        }

        return 1;
    },
};

rule 'residence.is_signup_allowed' => {
    description => "Checks if signup is allowed in the country of residence",
    code        => sub {
        my ($self, $context, $action_args) = @_;

        my $countries_instance = Brands->new->countries_instance;

        die {code => 'InvalidAccount'} unless $countries_instance->is_signup_allowed($context->residence);

        return 1;
    },
};

rule 'residence.not_restricted' => {
    description => 'Fails if the context residence is restricted; succeeds otherwise',
    code        => sub {
        my ($self, $context) = @_;

        my $countries_instance = Brands->new->countries_instance;
        die +{code => 'InvalidResidence'} if $countries_instance->restricted_country($context->residence);
        return 1;
    },
};
