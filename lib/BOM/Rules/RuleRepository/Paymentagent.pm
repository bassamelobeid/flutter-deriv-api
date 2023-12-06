package BOM::Rules::RuleRepository::Paymentagent;

=head1 NAME

BOM::Rules::RuleRepository::Paymentagent

=head1 DESCRIPTION

This modules declares rules and regulations applied on paymentagents and clients who want to use PA.

=cut

use strict;
use warnings;

use List::Util                       qw(none any first sum max);
use ExchangeRates::CurrencyConverter qw/in_usd convert_currency/;
use Format::Util::Numbers            qw(financialrounding formatnumber);
use Date::Utility;
use JSON::MaybeUTF8 qw(:v1);

use BOM::Rules::Registry qw(rule);
use BOM::Config::PaymentAgent;
use BOM::Database::ClientDB;
use BOM::User::Client::PaymentAgent;
use BOM::User::Client;
use BOM::Config;
use BOM::Config::Runtime;

# Some actions are mapped to services restricted for payment agents in BOM::User::Client::PaymentAgent::RESTRICTED_SERVICES.
# If a service is allowed for a payment agent, it's mapping actions will be allowed as well.
use constant PA_ACTION_MAPPING => {
    p2p_advertiser_create     => 'p2p',
    p2p_advert_create         => 'p2p',
    p2p_order_create          => 'p2p',
    buy                       => 'trading',
    withdraw                  => 'cashier_withdraw',
    cashier_withdrawal        => 'cashier_withdraw',
    payment_withdraw          => 'cashier_withdraw',
    doughflow_withdrawal      => 'cashier_withdraw',
    crypto_cashier_withdrawal => 'cashier_withdraw',
    paymentagent_transfer     => 'transfer_to_pa',
    paymentagent_withdraw     => 'transfer_to_pa'
};

rule 'paymentagent.pa_allowed_in_landing_company' => {
    description => "Checks the landing company and dies with PaymentAgentNotAvailable error code.",
    code        => sub {
        my ($self, $context, $args) = @_;

        $self->fail('PaymentAgentNotAvailable')
            unless $context->landing_company_object($args)->allows_payment_agents;

        return 1;
    },
};

rule 'paymentagent.paymentagent_status_can_apply_for_pa' => {

    description => "Checks that paymentagent status allows a new PA application.",
    code        => sub {
        my ($self, $context, $args) = @_;

        my $pa = $context->client($args)->get_payment_agent or return 1;

        return 1 if (!$pa->status) or $pa->status eq 'rejected';

        $self->fail('PaymentAgentAlreadyApplied') if $pa->status eq 'applied';

        $self->fail('PaymentAgentAlreadyExists') if $pa->status =~ /^(authorized|verified)$/;

        $self->fail('PaymentAgentStatusNotEligible');
    },
};

rule 'paymentagent.client_status_can_apply_for_pa' => {

    description => "Checks that client status allows a new PA application.",
    code        => sub {
        my ($self, $context, $args) = @_;

        $self->fail('PaymentAgentClientStatusNotEligible')
            if $context->client($args)->status->has_any(qw(
                cashier_locked
                shared_payment_method
                no_withdrawal_or_trading
                withdrawal_locked
                unwelcome
                duplicate_account
            ));

        return 1;
    },
};

rule 'paymentagent.client_has_mininum_deposit' => {

    description => "Checks that client meets minimum deposit requirement for PA application.",
    code        => sub {
        my ($self, $context, $args) = @_;

        my $client        = $context->client($args);
        my $limits        = decode_json_utf8(BOM::Config::Runtime->instance->app_config->payment_agents->initial_deposit_per_country);
        my $deposit_limit = $limits->{$client->residence} // $limits->{default};

        return 1 unless defined $deposit_limit;

        $deposit_limit = convert_currency($deposit_limit, 'USD', $client->currency);

        my $non_reversible = $client->balance_for_cashier('pa_deposit');

        my ($net_p2p) = $client->db->dbic->run(
            fixup => sub {
                return $_->selectrow_array('SELECT payment.aggregate_payments_by_type(?,?,?)', undef, $client->account->id, 'p2p', 120);
            });

        my $balance = financialrounding('amount', $client->currency, $non_reversible - max($net_p2p // 0, 0));

        $self->fail('PaymentAgentInsufficientDeposit', params => [$client->currency, formatnumber('amount', $client->currency, $deposit_limit)])
            if $balance < financialrounding('amount', $client->currency, $deposit_limit);

        return 1;
    },
};

rule 'paymentagent.action_is_allowed' => {
    description => "Some services are not allowed for payment agents (trading, p2p, cashier withdrawal, ...), unless they allowed by the PAs tier.",
    code        => sub {
        my ($self, $context, $args) = @_;

        my $action = $args->{underlying_action} // $context->{action} or die 'Action name is required';

        my $pa_client;

        if ($action eq 'account_transfer') {
            if ($args->{transfer_type} eq 'internal') {
                my $loginid_to = $args->{loginid_to};

                # a PA can transfer to a sibling account, if the sibling is also a payment agent;
                $pa_client = $context->client({loginid => $args->{loginid_from}});
                my $client_to = $context->client({loginid => $loginid_to});
                my $pa_to     = $client_to->get_payment_agent;

                return 1 if $pa_to and $pa_to->status eq 'authorized';

                $action = 'transfer_to_non_pa_sibling';
            } else {    # mt5, dxtrade, ctrader
                        # transfer in from trading account is always allowed
                return 1 if $context->user->loginid_details->{$args->{loginid_from}}->{is_external};

                $pa_client = $context->client({loginid => $args->{loginid_from}});
                $action    = 'trading';
            }
        } elsif ($action eq 'paymentagent_transfer') {
            $pa_client = $context->client({loginid => $args->{loginid_pa}});
            my $client = $context->client({loginid => $args->{loginid_client}});

            return 1 if !$client->get_payment_agent;
            return 1 if ($client->get_payment_agent->status // '') ne 'authorized';
        } elsif ($action eq 'paymentagent_withdraw') {
            $pa_client = $context->client({loginid => $args->{loginid_client} // $args->{loginid}});
        } else {
            my $loginid = $args->{loginid} or die 'loginid is required';
            $pa_client = $context->client({loginid => $loginid});
        }

        my $pa = $pa_client->get_payment_agent;
        return 1 unless $pa && ($pa->status // '') eq 'authorized';

        my $service = PA_ACTION_MAPPING->{$action} // $action;
        return 1 unless any { $_ eq $service } BOM::User::Client::PaymentAgent::RESTRICTED_SERVICES()->@*;
        return 1 if $pa->tier_details->{$service};

        if ($service eq 'cashier_withdraw') {
            my $limits = $pa->cashier_withdrawable_balance;

            my $available = financialrounding('amount', $pa_client->currency, $limits->{available});

            return 1 if $available > 0 && abs($args->{amount} // 0) <= $available;
            $self->fail('PACommisionWithdrawalLimit', params => [$pa_client->currency, $available])
                if ($limits->{commission} // 0) > 0;
        }

        my %error_mapping = (
            transfer_to_pa             => 'TransferToOtherPA',
            paymentagent_withdraw      => 'TransferToOtherPA',
            transfer_to_non_pa_sibling => 'TransferToNonPaSibling',
        );

        $self->fail($error_mapping{$service} // 'ServiceNotAllowedForPA');
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

rule 'paymentagent.paymentagent_withdrawal_allowed' => {
    description => "Checks if client is allowed to perform payment agent withdrawal.",
    code        => sub {
        my ($self, $context, $args) = @_;

        my $client = $context->client($args);

        my $pa_automation_flag = BOM::Config::Runtime->instance->app_config->system->suspend->payment_agent_withdrawal_automation;

        if ($pa_automation_flag == 1) {

            $self->fail('PaymentagentWithdrawalNotAllowed')
                unless $args->{source_bypass_verification}
                or not $client->allow_paymentagent_withdrawal_legacy;

        } else {

            my $allow_paymentagent_withdrawal = $client->allow_paymentagent_withdrawal;

            $self->fail($allow_paymentagent_withdrawal)
                unless $args->{source_bypass_verification} or not $allow_paymentagent_withdrawal;
        }
        return 1;
    },
};

1;
