package BOM::Rules::RuleRepository::FinancialAssessment;

=head1 NAME

BOM::Rules::RuleRepositry::FinancialAssessment

=head1 DESCRIPTION

This modules declares rules and regulations applied on financial assessments.

=cut

use strict;
use warnings;

use BOM::Rules::Registry qw(rule);
use BOM::User::FinancialAssessment qw(is_section_complete);

rule 'financial_assessment.required_sections_are_complete' => {
    description => "Checks the financial assessment in action args and dies if any required section is incomplete.",
    code        => sub {
        my ($self, $context, $args) = @_;

        my $is_FI_complete = is_section_complete($args, "financial_information");
        my $is_TE_complete = is_section_complete($args, "trading_experience");

        die +{
            error_code => 'IncompleteFinancialAssessment',
            }
            unless ($context->landing_company eq "maltainvest" ? $is_TE_complete && $is_FI_complete : $is_FI_complete);

        return 1;
    },
};

1;
