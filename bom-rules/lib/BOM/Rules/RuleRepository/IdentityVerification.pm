package BOM::Rules::RuleRepository::IdentityVerification;

=head1 NAME

BOM::Rules::RuleRepository::IdentityVerification

=head1 DESCRIPTION

A collection of rules and conditions related to the IDV processes

=cut

use strict;
use warnings;
use utf8;

use BOM::User::IdentityVerification;
use BOM::Rules::Comparator::Text;
use BOM::Rules::Registry qw(rule);

use Brands::Countries;

rule 'idv.check_expiration_date' => {
    description => "Checks is the document expired or not based on expiration date",
    code        => sub {
        my ($self, $context, $args) = @_;

        $self->fail('IDVResultMissing') unless my $result   = $args->{result}   and ref $args->{result} eq 'HASH';
        $self->fail('DocumentMissing')  unless my $document = $args->{document} and ref $args->{document} eq 'HASH';

        my $countries_config = Brands::Countries->new();
        my $is_lifetime_valid =
            $countries_config->get_idv_config(lc $document->{issuing_country})->{document_types}->{lc $document->{document_type}}->{lifetime_valid};

        return undef if $is_lifetime_valid;

        my $expiration_date = eval { Date::Utility->new($result->{expiry_date}) };

        $self->fail('Expired') unless $expiration_date and $expiration_date->is_after(Date::Utility->new);

        return undef;
    },
};

rule 'idv.check_name_comparison' => {
    description => "Checks if the context client first and last names match with the reported data by IDV provider",
    code        => sub {
        my ($self, $context, $args) = @_;

        $self->fail('ClientMissing')    unless my $client = $context->client($args);
        $self->fail('IDVResultMissing') unless my $result = $args->{result} and ref $args->{result} eq 'HASH';

        my @fields = qw/first_name last_name/;

        my $actual_full_name   = join ' ', map { $client->$_ // '' } @fields;
        my $expected_full_name = $result->{full_name} // join ' ', map { $result->{$_} // '' } @fields;

        $self->fail('NameMismatch') unless BOM::Rules::Comparator::Text::check_words_similarity($actual_full_name, $expected_full_name);

        return undef;
    },
};

rule 'idv.check_age_legality' => {
    description => "Checks whether the context client's age has been reached minimum legal age or not",
    code        => sub {
        my ($self, $context, $args) = @_;

        $self->fail('ClientMissing')    unless my $client = $context->client($args);
        $self->fail('IDVResultMissing') unless my $result = $args->{result} and ref $args->{result} eq 'HASH';

        return undef unless $result->{birthdate};

        my $date_of_birth = eval { Date::Utility->new($result->{birthdate}) };

        return undef unless $date_of_birth;

        my $countries_config = Brands::Countries->new();
        my $min_legal_age    = $countries_config->minimum_age_for_country($client->residence);

        $self->fail('UnderAge') unless $date_of_birth->is_before(Date::Utility->new->_minus_years($min_legal_age));

        return undef;
    }
};

rule 'idv.check_dob_conformity' => {
    description => "Checks whether the context client's date of birth is matched to reported one or not",
    code        => sub {
        my ($self, $context, $args) = @_;

        $self->fail('ClientMissing')    unless my $client = $context->client($args);
        $self->fail('IDVResultMissing') unless my $result = $args->{result} and ref $args->{result} eq 'HASH';

        my $reported_dob = eval { Date::Utility->new($result->{birthdate}) };
        my $profile_dob  = eval { Date::Utility->new($client->date_of_birth) };

        $self->fail('DobMismatch') unless $reported_dob and $profile_dob and $profile_dob->is_same_as($reported_dob);

        return undef;
    }
};

rule 'idv.check_verification_necessity' => {
    description => "Checks various parameters to evaluate that whether verification is required for client or not",
    code        => sub {
        my ($self, $context, $args) = @_;

        $self->fail('ClientMissing') unless my $client = $context->client($args);

        my $idv_model      = BOM::User::IdentityVerification->new(user_id => $client->binary_user_id);
        my $expired_bypass = $client->get_idv_status eq 'expired' && $idv_model->has_expired_document_chance();

        $self->fail('AlreadyAgeVerified') if $client->status->age_verification && !$expired_bypass;

        $self->fail('IdentityVerificationDisallowed') if BOM::User::IdentityVerification::is_idv_disallowed({client => $client});

        return undef;
    }
};

rule 'idv.check_service_availibility' => {
    description => "Checks whether the identity verification service is available to provide data or not",
    code        => sub {
        my ($self, $context, $args) = @_;

        $self->fail('ClientMissing')         unless my $client          = $context->client($args);
        $self->fail('IssuingCountryMissing') unless my $issuing_country = $args->{issuing_country};
        $self->fail('DocumentTypeMissing')   unless my $document_type   = $args->{document_type};

        my $countries = Brands::Countries->new;
        my $configs   = $countries->get_idv_config($issuing_country);
        my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->binary_user_id);

        my $qq_bypass = BOM::Config::on_qa() && $issuing_country eq 'qq';

        unless ($qq_bypass) {
            $self->fail('NotSupportedCountry') unless $countries->is_idv_supported($issuing_country);
            $self->fail('InvalidDocumentType')
                unless exists $configs->{document_types}->{$document_type} && $configs->{document_types}->{$document_type};
            $self->fail('IdentityVerificationDisabled')
                unless BOM::Platform::Utility::has_idv(
                country       => $issuing_country,
                document_type => $document_type
                );
        }

        my $expired_bypass = $client->get_idv_status eq 'expired' && $idv_model->has_expired_document_chance();

        $self->fail('NoSubmissionLeft') if $idv_model->submissions_left($client) == 0 && !$expired_bypass;

        return undef;
    }
};

rule 'idv.valid_document_number' => {
    description => "Checks the document number against the standard regex of a valid document number",
    code        => sub {
        my ($self, $context, $args) = @_;

        $self->fail('IssuingCountryMissing') unless my $issuing_country = $args->{issuing_country};
        $self->fail('DocumentTypeMissing')   unless my $document_type   = $args->{document_type};
        $self->fail('DocumentNumberMissing') unless my $document_number = $args->{document_number};

        my $countries = Brands::Countries->new;
        my $configs   = $countries->get_idv_config($issuing_country);
        my $regex     = $configs->{document_types}->{$document_type}->{format};

        my $qq_bypass = BOM::Config::on_qa() && $issuing_country eq 'qq';

        unless ($qq_bypass) {
            $self->fail('InvalidDocumentNumber') if $document_number !~ m/$regex/;

            my $additional_config = $configs->{document_types}->{$document_type}->{additional};
            if ($additional_config) {
                my $additional = $args->{document_additional} // '';
                $regex = $additional_config->{format};
                $self->fail('InvalidDocumentAdditional') if $additional !~ m/$regex/;
            }
        }

        return undef;
    }
};

rule 'idv.check_document_acceptability' => {
    description => 'Checks whether the provided document is acceptable or not, considers if the document is already being used',
    code        => sub {
        my ($self, $context, $args) = @_;

        $self->fail('ClientMissing') unless my $client = $context->client($args);
        $self->fail('IssuingCountryMissing')
            unless my $issuing_country = $args->{result} ? $args->{document}->{issuing_country} : $args->{issuing_country};
        $self->fail('DocumentTypeMissing') unless my $document_type = $args->{result} ? $args->{document}->{document_type} : $args->{document_type};
        $self->fail('DocumentNumberMissing')
            unless my $document_number = $args->{result} ? $args->{document}->{document_number} : $args->{document_number};

        my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->binary_user_id);

        my $underage_user_id = $idv_model->is_underage_blocked({
            issuing_country => $issuing_country,
            type            => $document_type,
            number          => $document_number,
        });

        $self->fail('UnderageBlocked', params => {underage_user_id => $underage_user_id}) if $underage_user_id;

        my $qq_bypass = BOM::Config::on_qa() && $issuing_country eq 'qq';

        unless ($qq_bypass) {
            my $claimed_documents = $idv_model->get_claimed_documents({
                    issuing_country => $issuing_country,
                    type            => $document_type,
                    number          => $document_number,
                }) // [];

            for my $claimed_doc (@$claimed_documents) {
                # Claimed document refers to when there is a document same as
                # given document which is already verified or verification
                # status still needs to be determined (pending) so that
                # no one else should be able to use the same again
                $self->fail('ClaimedDocument')
                    if $claimed_doc->{status} eq 'verified'
                    or $claimed_doc->{status} eq 'pending';
            }
        }

        return undef;
    }
};

rule 'idv.check_opt_out_availability' => {
    description => "Checks whether the country is an IDV supported country or not",
    code        => sub {
        my ($self, $context, $args) = @_;

        $self->fail('ClientMissing')         unless my $client          = $context->client($args);
        $self->fail('IssuingCountryMissing') unless my $issuing_country = $args->{issuing_country};

        my $countries = Brands::Countries->new;
        my $idv_model = BOM::User::IdentityVerification->new(user_id => $client->binary_user_id);

        my $qq_bypass = BOM::Config::on_qa() && $issuing_country eq 'qq';

        my $expired_bypass = $client->get_idv_status eq 'expired' && $idv_model->has_expired_document_chance();

        $self->fail('NoSubmissionLeft') if $idv_model->submissions_left($client) == 0 && !$expired_bypass;

        unless ($qq_bypass) {
            $self->fail('NotSupportedCountry') unless $countries->is_idv_supported($issuing_country);
        }

        return undef;
    }
};

1;
