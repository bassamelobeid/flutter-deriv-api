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

rule 'idv.check_name_comparison' => {
    description => "Checks if the context client first and last names match with the reported data by IDV provider",
    code        => sub {
        my ($self, $context, $args) = @_;

        die 'Client is missing'     unless $context->client;
        die 'IDV result is missing' unless my $result = $args->{result} and ref $args->{result} eq 'HASH';

        my @fields = qw/first_name last_name/;

        my $actual_full_name   = join ' ', map { $context->client->$_ // '' } @fields;
        my $expected_full_name = $result->{full_name} // join ' ', map { $result->{$_} // '' } @fields;

        die +{code => 'NameMismatch'} unless BOM::Rules::Comparator::Text::check_words_similarity($actual_full_name, $expected_full_name);

        return undef;
    },
};

rule 'idv.check_age_legality' => {
    description => "Checks whether the context client's age has been reached minimum legal age or not",
    code        => sub {
        my ($self, $context, $args) = @_;

        die 'Client is missing'     unless my $client = $context->client;
        die 'IDV result is missing' unless my $result = $args->{result} and ref $args->{result} eq 'HASH';
        die 'IDV date_of_birth is not present in result' unless $result->{date_of_birth};

        my $date_of_birth = $result->{date_of_birth};

        my $countries_config = Brands::Countries->new();
        my $min_legal_age    = $countries_config->minimum_age_for_country($client->residence);

        die +{code => 'UnderAge'} unless Date::Utility->new($date_of_birth)->is_before(Date::Utility->new->_minus_years($min_legal_age));

        return undef;
    }
    }
