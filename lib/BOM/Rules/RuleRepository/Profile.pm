package BOM::Rules::RuleRepository::Profile;

=head1 NAME

BOM::Rules::RuleRepositry::profile

=head1 DESCRIPTION

Contains rules pertaining client's profile info.

=cut

use strict;
use warnings;

use LandingCompany::Registry;
use Locale::Country;
use Text::Trim qw(trim);

use BOM::Platform::Context qw(localize);
use BOM::Rules::Registry qw(rule);
use BOM::Platform::Context qw(request);

rule 'profile.date_of_birth_complies_minimum_age' => {
    description => "Fails if the date of birth (read from args, falling back to context client's) complies with the minimum age of residence country",
    code        => sub {
        my ($self, $context, $args) = @_;

        die +{error_code => 'InvalidDateOfBirth'} unless $args->{date_of_birth};
        my $dob_date = eval { Date::Utility->new($args->{date_of_birth}) };
        die +{error_code => 'InvalidDateOfBirth'} unless $dob_date;

        my $countries_instance = request()->brand->countries_instance;
        # Get the minimum age from the client's residence
        my $min_age = $countries_instance && $countries_instance->minimum_age_for_country($context->residence);
        die +{error_code => "InvalidResidence"} unless $min_age;

        my $minimum_date = Date::Utility->new->minus_time_interval($min_age . 'y');
        die +{error_code => 'BelowMinimumAge'} if $dob_date->is_after($minimum_date);

        return 1;
    },
};

rule 'profile.secret_question_with_answer' => {
    description => "Secret question must always come with an answer",
    code        => sub {
        my ($self, $context, $args) = @_;

        die +{error_code => "NeedBothSecret"}
            if ($args->{secret_question} && !($args->{secret_answer} // ''));

        return 1;
    },
};

rule 'profile.valid_profile_countries' => {
    description => "Place of birth, residence and citizenship must be valid countries.",
    code        => sub {
        my ($self, $context, $args) = @_;

        my $brand = request()->brand;

        die {error_code => "InvalidPlaceOfBirth"}
            if $args->{place_of_birth} && !$brand->countries_instance->countries->country_from_code($args->{place_of_birth});

        die {error_code => "InvalidCitizenship"}
            if $args->{citizen} && !$brand->countries_instance->countries->country_from_code($args->{citizen});

        die {error_code => "InvalidResidence"} if $args->{residence} && !$brand->countries_instance->countries->country_from_code($args->{residence});

        return 1;
    },
};

rule 'profile.address_postcode_mandatory' => {
    description => "Checks if there's a postalcode in action args or in the context client (for gb residents only)",
    code        => sub {
        my ($self, $context, $args) = @_;

        die +{error_code => 'PostcodeRequired'} unless $args->{address_postcode} // $context->client->address_postcode;

        return 1;
    },
};

rule 'profile.no_pobox_in_address' => {
    description => "Succeeds if there's no pobox in address args (for eu residents only)",
    code        => sub {
        my ($self, undef, $args) = @_;

        die +{error_code => 'PoBoxInAddress'}
            if (($args->{address_line_1} || '') =~ /p[\.\s]?o[\.\s]+box/i
            or ($args->{address_line_2} || '') =~ /p[\.\s]?o[\.\s]+box/i);

        return 1;
    },
};

rule 'profile.valid_promo_code' => {
    description => "If promo_code_status flag is on, promo_code cannot be empty.",
    code        => sub {
        my ($self, $context, $args) = @_;

        die {error_code => "No promotion code was provided"}
            if (trim($args->{promo_code_status}) and not(trim($args->{promo_code}) // $context->client->promo_code));

        return 1;
    },
};

rule 'profile.valid_non_pep_declaration_time' => {
    description => "Non-pep declaration time cannot be after current time.",
    code        => sub {
        my ($self, undef, $args) = @_;

        die {error_code => "InvalidNonPepTime"} unless $args->{non_pep_declaration_time};

        my $non_pep_date = eval { Date::Utility->new($args->{non_pep_declaration_time}) };
        die {error_code => "InvalidNonPepTime"} unless $non_pep_date;

        die {error_code => "TooLateNonPepTime"} if $non_pep_date->epoch > time;

        return 1;
    },
};
