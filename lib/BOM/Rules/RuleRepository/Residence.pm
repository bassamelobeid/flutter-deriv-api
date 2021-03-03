package BOM::Rules::RuleRepository::Residence;

=head1 NAME

BOM::Rules::RuleRepositry::Residence

=head1 DESCRIPTION

This modules declares rules and regulations concerning the context residence.

=cut

use strict;
use warnings;

use BOM::Platform::Context qw(request);
use BOM::Rules::Registry qw(rule);

rule 'residence.account_type_is_allowed' => {
    description => "The account_type in args should be allowed in the context residence",
    code        => sub {
        my ($self, $context, $action_args) = @_;
        my $account_type = $action_args->{account_type} // '';

        my $countries_instance = request()->brand->countries_instance;

        my $failure = {code => 'InvalidAccount'};

        my $companies = {
            real      => $countries_instance->gaming_company_for_country($context->residence),
            financial => $countries_instance->financial_company_for_country($context->residence),
        };

        die $failure unless $companies->{$account_type};
        die $failure if $account_type eq 'financial' and $companies->{'financial'} ne 'maltainvest';
        return 1;
    },
};

rule 'residence.is_signup_allowed' => {
    description => "Checks if signup is allowed in the country of residence",
    code        => sub {
        my ($self, $context, $action_args) = @_;

        my $countries_instance = request()->brand->countries_instance;
        die {code => 'InvalidAccount'} unless $countries_instance->is_signup_allowed($context->residence);

        return 1;
    },
};

rule 'residence.not_restricted' => {
    description => 'Fails if the context residence is restricted; succeeds otherwise',
    code        => sub {
        my ($self, $context) = @_;

        my $countries_instance = request()->brand->countries_instance;
        die +{code => 'InvalidResidence'} if $countries_instance->restricted_country($context->residence);
        return 1;
    },
};

rule 'residence.date_of_birth_complies_minimum_age' => {
    description => "Fails if the date of birth (read from args, falling back to context client's) complies with the minimum age of residence country",
    code        => sub {
        my ($self, $context, $args) = @_;

        die +{code => 'InvalidDateOfBirth'} unless $args->{date_of_birth};
        my $dob_date = eval { Date::Utility->new($args->{date_of_birth}) };
        die +{code => 'InvalidDateOfBirth'} unless $dob_date;

        my $countries_instance = request()->brand->countries_instance;
        # Get the minimum age from the client's residence
        my $min_age = $countries_instance && $countries_instance->minimum_age_for_country($context->residence);
        die +{code => "InvalidResidence"} unless $min_age;

        my $minimum_date = Date::Utility->new->minus_time_interval($min_age . 'y');
        die +{code => 'BelowMinimumAge'} if $dob_date->is_after($minimum_date);

        return 1;
    },
};
