package BOM::Rules::RuleRepository::Paymentagent;

=head1 NAME

BOM::Rules::RuleRepositry::Paymentagent

=head1 DESCRIPTION

This modules declares rules and regulations applied on paymentagents and clients who want to use PA.

=cut

use strict;
use warnings;

use ExchangeRates::CurrencyConverter qw/in_usd convert_currency/;
use Format::Util::Numbers qw(financialrounding);

use BOM::Rules::Registry qw(rule);
use BOM::Config;
use BOM::Database::ClientDB;

rule 'paymentagent.pa_allowed_in_landing_company' => {
    description => "Checks the landing company and dies with PaymentAgentNotAvailable error code.",
    code        => sub {
        my ($self, $context, $args) = @_;

        $self->fail('PaymentAgentNotAvailable')
            unless $context->landing_company_object($args)->allows_payment_agents;

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
            if $context->client($args)->get_payment_agent;

        return 1;
    },
};

rule 'paymentagent.daily_transfer_limits' => {
    description => "Checks the daily count and amount limits for paymentagent transfer.",
    code        => sub {
        my ($self, $context, $args) = @_;

        for my $field (qw(loginid currency amount action)) {
            die "The required argument <$field> is missing" unless defined $args->{$field};
        }
        my $currency = $args->{currency};
        my $action   = $args->{action};
        my $day      = Date::Utility->new->is_a_weekend ? 'weekend' : 'weekday';

        my $client = $context->client($args);
        my ($amount_transferred, $count) = $client->today_payment_agent_withdrawal_sum_count;

        my $transaction_limit = BOM::Config::payment_agent()->{transaction_limits}->{$action};

        # Transaction limits are different in weekdays and weekends for paymentagent withdrawals
        $transaction_limit = $transaction_limit->{$day} if $action eq 'withdraw';

        my $amount_limit = convert_currency($transaction_limit->{amount_in_usd_per_day}, 'USD', $currency);
        $amount_limit = financialrounding('amount', $currency, $amount_limit);

        $self->fail('PaymentAgentDailyAmountExceeded', params => [$currency, $amount_limit])
            if ($amount_transferred + $args->{amount}) > $amount_limit;
        $self->fail('PaymentAgentDailyCountExceeded') if $count >= $transaction_limit->{transactions_per_day};

        return 1;
    },
};

rule 'paymentagent.accounts_are_not_the_same' => {
    # TODO: This rule should be removed in favor of transfers.same_account_not_allowed
    description => "Fails if client and payment agent loginids are the same",
    code        => sub {
        my ($self, $context, $args) = @_;

        $self->fail('ClientsAreTheSame') if $args->{loginid_pa} eq $args->{loginid_client};

        return 1;
    },
};

rule 'paymentagent.is_authorized' => {
    description => "Payment agent should be authorized (authenticated).",
    code        => sub {
        my ($self, $context, $args) = @_;

        my $client        = $context->client($args);
        my $payment_agent = $client->get_payment_agent or $self->fail('PaymentagentNotFound');

        $self->fail('NotAuthorized', params => $args->{loginid}) unless $payment_agent->status eq 'authorized';

        return 1;
    },
};

rule 'paymentagent.amount_is_within_pa_limits' => {
    description =>
        "The transferred amount should be the minimum and maximum limits of the payment agent (default limits will be used if they are empty).",
    code => sub {
        my ($self, $context, $args) = @_;

        for my $field (qw(loginid_pa amount currency)) {
            die "The required argument <$field> is missing" unless defined $args->{$field};
        }

        my $currency = $args->{currency};
        my $amount   = $args->{amount};
        my $pa       = $context->client({loginid => $args->{loginid_pa}})->get_payment_agent;

        my $min_max = BOM::Config::PaymentAgent::get_transfer_min_max($currency);
        my $min     = financialrounding('amount', $currency, $pa->min_withdrawal || $min_max->{minimum});
        my $max     = financialrounding('amount', $currency, $pa->max_withdrawal || $min_max->{maximum});

        $self->fail('PaymentAgentNotWithinLimits', params => [$min, $max]) if ($amount < $min || $amount > $max);

        return 1;
    },
};

1;
