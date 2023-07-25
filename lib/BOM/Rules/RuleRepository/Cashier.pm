package BOM::Rules::RuleRepository::Cashier;

=head1 NAME

BOM::Rules::RuleRepository::Cashier

=head1 DESCRIPTION

Contains rules pertaining client's cashier.

=cut

use strict;
use warnings;

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

rule 'cashier.is_account_type_allowed' => {
    description => "Checks if cashier transactions are allowed by the account type.",
    code        => sub {
        my ($self, $context, $args) = @_;
        my $client = $context->client($args);

        # DF and crypto cashier send these payment_types for validate_payment.
        # Callers of BOM::Platform::Client::CashierValidation::validate set is_cashier=1 for external cashiers.
        return 1 unless ($args->{payment_type} // '') =~ /^(doughflow|crypto_cashier)$/ or $args->{is_cashier};
        return 1 if $client->is_legacy && !$client->is_virtual;
        return 1 if $client->get_account_type->is_cashier;

        $self->fail('CashierNotAllowed');
    },
};

1;
