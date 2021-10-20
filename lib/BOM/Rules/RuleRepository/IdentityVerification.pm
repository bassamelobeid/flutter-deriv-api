package BOM::Rules::RuleRepository::IdentityVerification;

=head1 NAME

BOM::Rules::RuleRepositry::IdentityVerification

=head1 DESCRIPTION

A collection of rules and conditions related to the IDV processes

=cut

use strict;
use warnings;
use utf8;

use BOM::Rules::Comparator::Text;
use BOM::Rules::Registry qw(rule);

rule 'idv.check_expiration_date' => {
    description => "Checks is the document expired or not based on expiration date",
    code        => sub {
        my ($self, $context, $args) = @_;

        die 'IDV result is missing' unless my $result   = $args->{result}   and ref $args->{result} eq 'HASH';
        die 'document is missing'   unless my $document = $args->{document} and ref $args->{document} eq 'HASH';

        my $countries_config = Brands::Countries->new();
        my $is_lifetime_valid =
            $countries_config->get_idv_config(lc $document->{issuing_country})->{document_types}->{lc $document->{document_type}}->{lifetime_valid};

        return undef if $is_lifetime_valid;

        my $expiration_date = eval { Date::Utility->new($result->{expiration_date}) };

        $self->fail('Expired') unless $expiration_date and $expiration_date->is_after(Date::Utility->new);

        return undef;
    },
};

rule 'idv.check_name_comparison' => {
    description => "Checks if the context client first and last names match with the reported data by IDV provider",
    code        => sub {
        my ($self, $context, $args) = @_;

        my $client = $context->client($args);

        die 'Client is missing'     unless $client;
        die 'IDV result is missing' unless my $result = $args->{result} and ref $args->{result} eq 'HASH';

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

        my $client = $context->client($args);

        die 'Client is missing'     unless $client;
        die 'IDV result is missing' unless my $result = $args->{result} and ref $args->{result} eq 'HASH';

        my $date_of_birth = eval { Date::Utility->new($result->{date_of_birth}) };

        my $countries_config = Brands::Countries->new();
        my $min_legal_age    = $countries_config->minimum_age_for_country($client->residence);

        $self->fail('UnderAge') unless $date_of_birth and $date_of_birth->is_before(Date::Utility->new->_minus_years($min_legal_age));

        return undef;
    }
};

rule 'idv.check_dob_conformity' => {
    description => "Checks whether the context client's date of birth is matched to reported one or not",
    code        => sub {
        my ($self, $context, $args) = @_;

        die 'Client is missing'     unless my $client = $context->client($args);
        die 'IDV result is missing' unless my $result = $args->{result} and ref $args->{result} eq 'HASH';

        my $reported_dob = eval { Date::Utility->new($result->{date_of_birth}) };
        my $profile_dob  = eval { Date::Utility->new($client->{date_of_birth}) };

        $self->fail('DobMismatch') unless $reported_dob and $profile_dob and $profile_dob->is_same_as($reported_dob);

        return undef;
    },
};

1;
