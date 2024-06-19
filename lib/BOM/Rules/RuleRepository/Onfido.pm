package BOM::Rules::RuleRepository::Onfido;

=head1 NAME

BOM::Rules::RuleRepository::Onfido

=head1 DESCRIPTION

Contains rules related to Onfido check ups

=cut

use strict;
use warnings;
use utf8;

use JSON::MaybeUTF8 qw(:v1);

use BOM::Platform::Context qw(localize);
use BOM::Rules::Comparator::Text;
use BOM::Rules::Registry qw(rule);
use Text::Unidecode;
use Text::Trim qw(trim);

rule 'onfido.check_name_comparison' => {
    description => "Checks if the context client first and last names match with the last Onfido report data",
    code        => sub {
        my ($self, $context, $args) = @_;

        my $client = $context->client($args);
        die 'Onfido report is missing' unless my $report = $args->{report};
        die 'Onfido report api_name is invalid' unless ($report->{api_name} // '') eq 'document';

        my $properties        = eval { decode_json_utf8($report->{properties} // '{}') };
        my $client_first_name = lc unidecode(trim($client->first_name       // ''));
        my $client_last_name  = lc unidecode(trim($client->last_name        // ''));
        my $onfido_first_name = lc unidecode(trim($properties->{first_name} // ''));
        my $onfido_last_name  = lc unidecode(trim($properties->{last_name}  // ''));
        my $client_full_name  = $client_first_name . ' ' . $client_last_name;
        my $onfido_full_name  = $onfido_first_name . ' ' . $onfido_last_name;

        if ($onfido_last_name eq '' || lc($onfido_last_name) eq 'null') {
            return undef if $onfido_first_name eq $client_first_name;

            $self->fail('NameMismatch') unless BOM::Rules::Comparator::Text::check_words_similarity($client_full_name, $onfido_full_name);

        } else {
            return undef if $onfido_full_name eq $client_full_name;

            $self->fail('NameMismatch')
                unless BOM::Rules::Comparator::Text::check_words_similarity($client_first_name, $onfido_first_name)
                && BOM::Rules::Comparator::Text::check_words_similarity($client_last_name, $onfido_last_name);
        }

        #additionaly first words must match

        my ($first_word_actual)   = split(/\s+/, $client_first_name);
        my ($first_word_expected) = split(/\s+/, $onfido_first_name);

        $self->fail('NameMismatch') unless $first_word_actual eq $first_word_expected;

        return undef;
    },
};

rule 'onfido.check_dob_conformity' => {
    description => "Checks if the context client dob matches the Onfido report dob",
    code        => sub {
        my ($self, $context, $args) = @_;

        my $client = $context->client($args);
        die 'Onfido report is missing' unless my $report = $args->{report};
        die 'Onfido report api_name is invalid' unless ($report->{api_name} // '') eq 'document';

        my $properties   = eval { decode_json_utf8($report->{properties} // '{}') };
        my $actual_dob   = eval { Date::Utility->new($client->date_of_birth) };
        my $expected_dob = eval { Date::Utility->new($properties->{date_of_birth}) };

        $self->fail('DobMismatch') unless $expected_dob && $actual_dob && $actual_dob->date eq $expected_dob->date;

        return undef;
    },
};
