package BOM::Rules::RuleRepository::Profile;

=head1 NAME

BOM::Rules::RuleRepositry::profile

=head1 DESCRIPTION

Contains rules pertaining client's profile info.

=cut

use strict;
use warnings;

use Locale::Country;
use Text::Trim qw(trim);

use BOM::Platform::Context qw(localize request);
use BOM::Rules::Registry   qw(rule);

rule 'profile.date_of_birth_complies_minimum_age' => {
    description => "Fails if the date of birth (read from args, falling back to context client's) complies with the minimum age of residence country",
    code        => sub {
        my ($self, $context, $args) = @_;
        my $residence = $context->residence($args);

        my $dup_dob;
        my $client     = $context->client($args);
        my $duplicated = $client->duplicate_sibling_from_vr;

        $dup_dob = $duplicated->date_of_birth if $duplicated;
        $self->fail('InvalidDateOfBirth', description => 'Date of birth is missing') unless $args->{date_of_birth} // $dup_dob;

        my $dob_date = eval { Date::Utility->new($args->{date_of_birth} // $dup_dob) };
        $self->fail('InvalidDateOfBirth', description => 'Date of birth is invalid') unless $dob_date;

        my $country = Business::Config::Country::Registry->new()->by_code($residence);
        # Get the minimum age from the client's residence
        my $min_age = $country && $country->signup->{minimum_age};
        $self->fail('InvalidResidence', description => 'Minimum age is not configured for residence') unless $min_age;

        my $minimum_date = Date::Utility->new->minus_time_interval($min_age . 'y');
        $self->fail('BelowMinimumAge', description => 'Date of birth is below minimum age') if $dob_date->is_after($minimum_date);

        return 1;
    },
};

rule 'profile.both_secret_question_and_answer_required' => {
    description => "Secret question must always come with an answer and vice versa",
    code        => sub {
        my ($self, $context, $args) = @_;

        my $client = $context->client($args);
        my $dup_secret_answer;
        my $dup_secret_question;

        my $duplicated = $client->duplicate_sibling_from_vr;

        if ($duplicated) {
            $dup_secret_answer   = $duplicated->secret_answer;
            $dup_secret_question = $duplicated->secret_question;
        }

        $self->fail("NeedBothSecret", description => 'Missing secret question or secret answer')
            if !($args->{secret_question} // $dup_secret_question) ^ !($args->{secret_answer} // $dup_secret_answer);

        return 1;
    },
};

rule 'profile.valid_profile_countries' => {
    description => "Place of birth, residence and citizenship must be valid countries.",
    code        => sub {
        my ($self, $context, $args) = @_;

        $self->fail("InvalidPlaceOfBirth", description => "place_of_birth $args->{place_of_birth} is invalid")
            if $args->{place_of_birth} && !$context->get_country($args->{place_of_birth});

        $self->fail("InvalidCitizenship", description => "citizen $args->{citizen} is invalid")
            if $args->{citizen} && !$context->get_country($args->{citizen});

        $self->fail("InvalidResidence", description => "residence $args->{residence} is invalid")
            if $args->{residence} && !$context->get_country($args->{residence});

        return 1;
    },
};

rule 'profile.address_postcode_mandatory' => {
    description => "Checks if there's a postalcode in action args or in the context client (for gb residents only)",
    code        => sub {
        my ($self, $context, $args) = @_;

        $self->fail('PostcodeRequired') unless $args->{address_postcode} // $context->client($args)->address_postcode;

        return 1;
    },
};

rule 'profile.no_pobox_in_address' => {
    description => "Succeeds if there's no pobox in address args (for eu residents only)",
    code        => sub {
        my ($self, undef, $args) = @_;

        $self->fail('PoBoxInAddress')
            if (($args->{address_line_1} // '') =~ /p[\.\s]?o[\.\s]+box/i
            or ($args->{address_line_2} // '') =~ /p[\.\s]?o[\.\s]+box/i);

        return 1;
    },
};

rule 'profile.valid_promo_code' => {
    description => "If promo_code_status flag is on, promo_code cannot be empty.",
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client = $context->client($args);

        $self->fail("No promotion code was provided", description => 'Promo code is missing')
            if (trim($args->{promo_code_status}) and not(trim($args->{promo_code}) // $client->promo_code));

        return 1;
    },
};

rule 'profile.valid_non_pep_declaration_time' => {
    description => "Non-pep declaration time cannot be after current time.",
    code        => sub {
        my ($self, undef, $args) = @_;

        $self->fail("InvalidNonPepTime", description => 'Non-pep declaration is missing')
            unless $args->{non_pep_declaration_time};

        my $non_pep_date = eval { Date::Utility->new($args->{non_pep_declaration_time}) };
        $self->fail("InvalidNonPepTime", description => 'Non-pep declaration is invalid')
            unless $non_pep_date;

        $self->fail("TooLateNonPepTime", description => 'Non-pep declaration is after current time')
            if $non_pep_date->epoch > time;

        return 1;
    },
};

rule 'profile.residence_cannot_be_changed' => {
    description => "Residence cannot be set to a new value, unless the context client is a virtual account with no residence",
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client = $context->client($args);

        return 1 unless exists $args->{residence};

        return 1 if $client->is_virtual and not $client->residence;

        $self->fail('PerimissionDenied', description => 'Residence cannot be updated')
            if $client->residence ne ($args->{residence} // '');

        return 1;
    },
};

rule 'profile.immutable_fields_cannot_change' => {
    description => 'Immutable fields of real accounts cannot be changed.',
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client = $context->client($args);

        return 1 if $client->is_virtual;

        for my $field ($client->immutable_fields) {
            next unless defined($args->{$field});
            next unless $client->$field;
            next if $args->{$field} eq $client->$field;

            $self->fail(
                'ImmutableFieldChanged',
                details => {field => $field},
            );
        }

        return 1;
    },
};

rule 'profile.copier_cannot_allow_copiers' => {
    description => "No one is allowed to copy from a copier.",
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client = $context->client($args);

        return 1 unless $args->{allow_copiers};

        my $traders = BOM::Database::DataMapper::Copier->new(
            broker_code => $client->broker_code,
            operation   => 'replica'
        )->get_traders({copier_id => $client->loginid}) // [];

        $self->fail('AllowCopiersError') if scalar @$traders;

        return 1;
    },
};

rule 'profile.tax_information_is_not_cleared' => {
    description => 'Tax information cannot be cleared if they are already set.',
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client = $context->client($args);

        foreach my $field (qw(tax_residence tax_identification_number)) {
            if ($client->$field and exists $args->{$field} and not $args->{$field}) {
                $self->fail(
                    'TaxInformationCleared',
                    details => {
                        field => $field,
                    },
                );
            }
        }
        return 1;
    }
};

rule 'profile.tax_information_is_mandatory' => {
    description => 'Tax information is mandatory for some landing companies (maltainvest)',
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client = $context->client($args);

        my $tax_residence             = $args->{'tax_residence'}             // $client->tax_residence             // '';
        my $tax_identification_number = $args->{'tax_identification_number'} // $client->tax_identification_number // '';
        my $is_tin_manually_approved  = $args->{'is_tin_manually_approved'}  // $client->is_tin_manually_approved;
        return 1 if $tax_residence && ($tax_identification_number || $client->is_tin_manually_approved);

        $self->fail('TINDetailsMandatory');
    },
};

rule 'profile.professional_request_allowed' => {
    description => 'If professional status requested, it should be supported by landing company.',
    code        => sub {
        my ($self, $context, $args) = @_;
        my $landing_company = $context->landing_company_legacy($args);

        return 1 unless $args->{request_professional_status};

        $self->fail('ProfessionalNotAllowed') unless $landing_company->support_professional_client;

        return 1;
    },
};

rule 'profile.professional_request_is_not_resubmitted' => {
    description => 'If professional request is already made, it will be rejected.',
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client = $context->client($args);

        return 1 unless $args->{request_professional_status};

        $self->fail('ProfessionalAlreadySubmitted')
            if $client->status->professional
            or $client->status->professional_requested;

        return 1;
    },
};

rule 'profile.fields_allowed_to_change' => {
    description => 'Changeable fields are different between real and virtual accounts.',
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client = $context->client($args);

        return 1 unless $client->is_virtual;

        # Ideally, I think we should refactor this part instead of hard-coding it. We have $client->immutable_fields logic in place.
        # The logic for fields allowed to be changed should be !$client->immutable_fields. But, I do not have a 100% understanding of
        # client profile rules.
        my $allowed_fields_for_virtual =
            qr/set_settings|loginid|email_consent|residence|allow_copiers|preferred_language|feature_flag|citizen|trading_hub/;
        for (keys %$args) {
            $self->fail(
                'PermissionDenied',
                details => {field => $_},
            ) if !/$allowed_fields_for_virtual/;
        }

        return 1;
    },
};

1;
