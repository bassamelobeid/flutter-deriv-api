package BOM::Rules::RuleRepository::FinancialAssessment;

=head1 NAME

BOM::Rules::RuleRepository::FinancialAssessment

=head1 DESCRIPTION

This modules declares rules and regulations applied on financial assessments.

=cut

use strict;
use warnings;

use BOM::Rules::Registry           qw(rule);
use BOM::User::FinancialAssessment qw(is_section_complete appropriateness_tests);

rule 'financial_assessment.required_sections_are_complete' => {
    description => "Checks the financial assessment in action args and dies if any required section is incomplete.",
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client         = $context->client($args);
        my $is_FI_complete = BOM::User::FinancialAssessment::is_section_complete($args, "financial_information", $context->landing_company($args));
        my $is_TE_complete = BOM::User::FinancialAssessment::is_section_complete($args, "trading_experience",    $context->landing_company($args));

        $self->fail('IncompleteFinancialAssessment')
            if ($context->landing_company($args) eq "svg" && !$is_FI_complete);

        my $checks = $is_TE_complete && $is_FI_complete;
        my $keys   = $args->{keys} // undef;

        if ($keys && scalar $keys->@* == 1) {
            $checks = $keys->[0] eq 'financial_information' ? $is_FI_complete : $is_TE_complete;
        }
        $self->fail('IncompleteFinancialAssessment')
            if ($context->landing_company($args) eq "maltainvest" && !$checks);

        return 1;
    },
};

rule 'financial_asssessment.completed' => {
    description => "Checks financial assessment and fails if it's required by client's landing company, but missing.",
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client = $context->client($args);

        my $action = $args->{action} // '';
        $self->fail('FinancialAssessmentRequired') unless $client->is_financial_assessment_complete($action eq 'withdrawal' ? 1 : 0);

        return 1;
    },
};

rule 'financial_asssessment.account_opening_validation' => {
    description => "Checks financial assessment sections are fullfiled on account creation.",
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client = $context->client($args);

        # Affliates account_types bypass FA checks
        return 1 if $args->{account_type} && $args->{account_type} eq 'affiliate';

        my $is_section_complete_te =
            BOM::User::FinancialAssessment::is_section_complete($args, 'trading_experience', $context->landing_company($args));
        my $is_section_complete_fa =
            BOM::User::FinancialAssessment::is_section_complete($args, 'financial_information', $context->landing_company($args));

        $self->fail('IncompleteFinancialAssessment') unless $is_section_complete_te && $is_section_complete_fa;

        return 1;
    },
};

rule 'financial_asssessment.appropriateness_test' => {
    description => "Checks if the client have passed the appropriateness test question and by-pass if the user is not new.",
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client = $context->client($args);
        return 1 if $args->{account_type} && $args->{account_type} eq 'affiliate';
        my $app_test = BOM::User::FinancialAssessment::appropriateness_tests($client, $args);
        if (!$app_test->{result}) {
            if ($app_test->{cooling_off_expiration_date}) {
                $self->fail('AppropriatenessTestFailed', details => {cooling_off_expiration_date => $app_test->{cooling_off_expiration_date}});
            } else {
                $self->fail('AppropriatenessTestFailed');
            }
        }

        return 1;
    },
};

1;
