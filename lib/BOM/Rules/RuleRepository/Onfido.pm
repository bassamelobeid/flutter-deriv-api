package BOM::Rules::RuleRepository::Onfido;

=head1 NAME

BOM::Rules::RuleRepositry::Onfido

=head1 DESCRIPTION

Contains rules related to Onfido check ups

=cut

use strict;
use warnings;
use utf8;

use JSON::MaybeUTF8 qw(:v1);
use LandingCompany::Registry;

use BOM::Platform::Context qw(localize);
use BOM::Rules::Comparator::Text;
use BOM::Rules::Registry qw(rule);

rule 'onfido.check_name_comparison' => {
    description => "Checks if the context client first and last names match with the last Onfido report data",
    code        => sub {
        my ($self, $context, $args) = @_;

        die 'Client is missing'                 unless $context->client;
        die 'Onfido report is missing'          unless my $report = $args->{report};
        die 'Onfido report api_name is invalid' unless ($report->{api_name} // '') eq 'document';

        my @fields = qw/first_name last_name/;

        my $properties = eval { decode_json_utf8($report->{properties} // '{}') };

        my $actual_full_name   = join ' ', map { $context->client->$_ // '' } @fields;
        my $expected_full_name = join ' ', map { $properties->{$_}    // '' } @fields;

        die +{error_code => 'NameMismatch'} unless BOM::Rules::Comparator::Text::check_words_similarity($actual_full_name, $expected_full_name);

        return undef;
    },
};
