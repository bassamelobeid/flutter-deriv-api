package BOM::Rules::RuleRepository::P2P;

=head1 NAME

BOM::Rules::RuleRepository::P2P

=head1 DESCRIPTION

This modules declares rules and regulations related to P2P.

=cut

use strict;
use warnings;

use BOM::Rules::Registry qw(rule);
use BOM::Config::Runtime;
use Format::Util::Numbers qw(financialrounding formatnumber);

rule 'p2p.no_open_orders' => {
    description => "Fails if the client has any open P2P orders.",
    code        => sub {
        my ($self, $context, $args) = @_;

        my $client = $context->client($args);

        my $orders = $client->_p2p_orders(
            loginid => $args->{loginid},
            active  => 1,
        );

        $self->fail('OpenP2POrders') if @$orders;

        return 1;
    },
};

rule 'p2p.withdrawal_check' => {
    description => "Fails if the withdrawal amount includes net P2P deposits.",
    code        => sub {
        my ($self, $context, $args) = @_;

        return 1 if ($args->{action} // '') ne 'withdrawal';

        my $client = $context->client($args);
        return 1 if $client->payment_agent and ($client->payment_agent->status // '') eq 'authorized';

        my $amount            = $args->{amount} // die 'Amount is required';
        my $available_balance = $client->p2p_withdrawable_balance;
        my $currency          = $client->currency;

        my $error_code = (($args->{payment_type} // '') eq 'internal_transfer') ? 'P2PDepositsTransfer' : 'P2PDepositsWithdrawal';
        $error_code .= 'Zero' if $available_balance <= 0;

        if (financialrounding('amount', $currency, abs($amount)) > financialrounding('amount', $currency, $available_balance)) {
            my $p2p_excluded = $client->account->balance - $available_balance;
            $self->fail($error_code,
                params => [formatnumber('amount', $currency, $available_balance), formatnumber('amount', $currency, $p2p_excluded), $currency]);
        }

        return 1;
    },
};

1;
