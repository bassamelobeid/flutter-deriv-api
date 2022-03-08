package BOM::Rules::RuleRepository::Cashier;

=head1 NAME

BOM::Rules::RuleRepositry::Cashier

=head1 DESCRIPTION

Contains rules pertaining client's cashier.

=cut

use strict;
use warnings;

use LandingCompany::Registry;

use BOM::Rules::Registry qw(rule);
use BOM::Config::Runtime;

#  TODO: devendency to bom-transaction looks incorrect. It should be removed by moving `allow_paymentagent_withdrawal` implementation to the current module
# It should be done after the PA automation task is released: https://redmine.deriv.cloud/issues/10688
use BOM::Transaction::Validation;

rule 'cashier.is_not_locked' => {
    description => "Checks the cashier-lock status. If will fail if cashier is locked.",
    code        => sub {
        my ($self, $context, $args) = @_;

        $self->fail('CashierLocked') if $context->client($args)->status->cashier_locked;

        return 1;
    },
};

rule 'cashier.profile_requirements' => {
    description => "Checks if any cashier-required info is missing in client's profile.",
    code        => sub {
        my ($self, $context, $args) = @_;

        my $action = $args->{action};
        die 'Action is required for checking cashier requirements' unless $action;

        if (my @missing_fields = $context->client($args)->missing_requirements($action)) {
            $self->fail('CashierRequirementsMissing', details => {fields => \@missing_fields});
        }

        return 1;
    },
};

rule 'cashier.paymentagent_withdrawal_allowed' => {
    description => "Checks if client is allowed to perform payment agent withdrawal.",
    code        => sub {
        my ($self, $context, $args) = @_;

        my $client = $context->client($args);

        # TODO: we will copy `allow_paymentagent_withdrawal` code here after the Redmine card #10688 is merged and will remove rependency to bom-transaction.
        $self->fail('PAWithdrawalNotAllowed')
            unless ($args->{source_bypass_verification}
            or BOM::Transaction::Validation->new({clients => [$client]})->allow_paymentagent_withdrawal($client));

        return 1;
    },
};

1;
