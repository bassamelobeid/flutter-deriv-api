package BOM::Transaction::History;

=head1 BOM::Transaction::History
ABSTRACT: Transaction related functions of bom-transaction
=cut

use strict;
use warnings;

no indirect;

use Date::Utility;
use BOM::Database::DataMapper::Transaction;

use Exporter qw(import);
our @EXPORT_OK = qw(get_transaction_history);

=head2 get_transaction_history

Get transactions of any given client

=over 4

=item * client - client to get transaction history for

=item * args - see below

=back

C<args> contains:

=over 4

=item * {args}->{action_type} - enum ('buy', 'sell', 'withdrawal', 'deposit') (optional parameter)

=item * {args}->{limit} - limit of transactions (optional parameter)

=item * {args}->{offset} - skip transactions by offset amount (optional parameter)

=item * {args}->{date_from} - get transaction history from (optional parameter)

=item * {args}->{date_to} - get transaction history top (optional parameter)

=back

Returns a hashref of structured transactions.

=cut

sub get_transaction_history {
    my $params = shift;

    my $client = $params->{client};

    my $account = $client->default_account;

    return {} unless $account;

    # get all transactions
    my $results = BOM::Database::DataMapper::Transaction->new({db => $account->db})->get_transactions_ws($params->{args}, $account);
    return {} unless (scalar @{$results});

    my (@close_trades, @open_trades, @payments, @escrow);

    for my $txn (@$results) {
        $txn->{transaction_id} //= $txn->{id};

        # set transaction_time for different action types
        my $txn_time = _get_txn_time($txn);

        $txn->{transaction_time} = Date::Utility->new($txn_time)->epoch();
        $txn->{short_code}       = $txn->{short_code} // '';

        if ($txn->{payment_id}) {
            push(@payments, $txn);
        } elsif ($txn->{financial_market_bet_id}) {
            if ($txn->{is_sold}) {
                push(@close_trades, $txn);
            } else {
                push(@open_trades, $txn);
            }
        } else {
            # no payment_id or financial_market_bet_id is assumed to be escrow
            push(@escrow, $txn);
        }
    }

    return {
        payment     => \@payments,
        close_trade => \@close_trades,
        open_trade  => \@open_trades,
        escrow      => \@escrow,
    };
}

sub _get_txn_time {
    my $txn = shift;

    # Time for financial market bet
    my $time_type = $txn->{action_type} eq 'sell' ? 'sell_time' : 'purchase_time';
    return $txn->{$time_type}   if $txn->{financial_market_bet_id};
    return $txn->{payment_time} if $txn->{payment_id};

    return $txn->{escrow_time} if $txn->{action_type} =~ /^(hold|release)$/;

    return $txn->{transaction_time};
}

1;
