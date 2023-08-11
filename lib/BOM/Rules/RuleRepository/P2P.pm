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

        my $config = BOM::Config::Runtime->instance->app_config->payments;
        my $limit  = $config->p2p_withdrawal_limit;
        return 1 if $limit >= 100;    # setting is a percentage

        my $amount   = $args->{amount} // die 'Amount is required';
        my $client   = $context->client($args);
        my $currency = $client->currency;
        my $days     = $config->p2p_deposits_lookback;

        return 1 if $client->payment_agent and ($client->payment_agent->status // '') eq 'authorized';

        return 1 unless BOM::Config::P2P::available_countries()->{$client->residence};

        my ($net_p2p) = $client->db->dbic->run(
            fixup => sub {
                return $_->selectrow_array('SELECT payment.aggregate_payments_by_type(?,?,?)', undef, $client->account->id, 'p2p', $days);
            }) // 0;

        return 1 if $net_p2p <= 0;

        my $p2p_excluded     = $net_p2p * (1 - ($limit / 100));
        my $availble_balance = $client->account->balance - $p2p_excluded;

        my $error_code = (($args->{payment_type} // '') eq 'internal_transfer') ? 'P2PDepositsTransfer' : 'P2PDepositsWithdrawal';
        $error_code .= 'Zero' if $availble_balance <= 0;

        $self->fail($error_code,
            params => [formatnumber('amount', $currency, $availble_balance), formatnumber('amount', $currency, $p2p_excluded), $currency])
            if financialrounding('amount', $currency, abs($amount)) > financialrounding('amount', $currency, $availble_balance);

        return 1;
    },
};

1;
