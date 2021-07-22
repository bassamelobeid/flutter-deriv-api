package BOM::Rules::RuleRepository::Paymentagent;

=head1 NAME

BOM::Rules::RuleRepositry::Paymentagent

=head1 DESCRIPTION

This modules declares rules and regulations applied on paymentagents and clients who want to use PA.

=cut

use strict;
use warnings;

use BOM::Rules::Registry qw(rule);

rule 'paymentagent.pa_allowed_in_landing_company' => {
    description => "Checks the landing company and dies with PaymentAgentNotAvailable error code.",
    code        => sub {
        my ($self, $context, $args) = @_;
        die +{
            error_code => 'PaymentAgentNotAvailable',
            }
            unless $context->landing_company->allows_payment_agents;

        return 1;
    },
};

rule 'paymentagent.paymentagent_shouldnt_already_exist' => {
    description => "Checks that paymentagent exists if so dies with PaymentAgentAlreadyExists error code.",
    code        => sub {
        my ($self, $context, $args) = @_;
        die +{
            error_code => 'PaymentAgentAlreadyExists',
            }
            if $context->client->get_payment_agent;

        return 1;
    },
};

1;
