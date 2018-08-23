package BOM::Transaction::History;

=head1 BOM::Transaction::History

ABSTRACT: Transaction related functions of bom-transaction

=cut

use strict;
use warnings;

no indirect;

use Date::Utility;
use BOM::Database::DataMapper::Transaction;
use BOM::Transaction;
use Try::Tiny;
use POSIX();

use List::Util qw(min max);
use BOM::Product::ContractFactory qw(produce_contract);
use Format::Util::Numbers qw(formatnumber);

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

    my $currency = $client->default_account->currency_code;

    my $transactions = {
        estimated_profit => 0,
    };
    my (@close_trades, @open_trades, @payments, @transaction_times);

    for my $txn (@$results) {

        $txn->{transaction_id} //= $txn->{id};

        my $txn_time;
        if (exists $txn->{financial_market_bet_id} and $txn->{financial_market_bet_id}) {
            if ($txn->{action_type} eq 'sell') {
                $txn_time = $txn->{sell_time};
            } else {
                $txn_time = $txn->{purchase_time};
            }
        } else {
            $txn_time = $txn->{payment_time};
        }

        $txn_time                = Date::Utility->new($txn_time);
        $txn->{transaction_time} = $txn_time->epoch();
        $txn->{transaction_date} = $txn_time->date_yyyymmdd();
        push @transaction_times, $txn->{transaction_time};

        # an open bet
        if (!$txn->{is_sold} && !$txn->{payment_id}) {
            $txn->{purchase_time} = Date::Utility->new($txn->{purchase_time});
            $txn->{expiry_time}   = Date::Utility->new($txn->{expiry_time});
            $txn->{start_time}    = Date::Utility->new($txn->{start_time});

            my $remaining_time = $txn->{expiry_time}->days_between(Date::Utility->new());
            if ($remaining_time == 0) {
                $remaining_time = POSIX::floor(($txn->{expiry_time}->epoch - Date::Utility->new->epoch) / 3600) . ' Hours';
            } else {
                $remaining_time = $remaining_time . ' Days';
            }

            my $contract = produce_contract($txn->{short_code}, $currency);

            if (defined $txn->{buy_price} and (defined $contract->bid_price or defined $contract->{sell_price})) {
                $txn->{profit} =
                    $contract->{sell_price}
                    ? formatnumber('price', $currency, $contract->{sell_price} - $txn->{buy_price})
                    : formatnumber('price', $currency, $contract->{bid_price} - $txn->{buy_price});

                $txn->{indicative_price} = $txn->{buy_price} + $txn->{profit};
                $transactions->{estimated_profit} += $txn->{profit};
            }

            $txn->{remaining_time} = $remaining_time;
        }

        $transactions->{earliest_transaction} = min @transaction_times;
        $transactions->{latest_transaction}   = max @transaction_times;

        $txn->{short_code} = $txn->{short_code} // '';

        if ($txn->{payment_id}) {
            push(@payments, $txn);
        } elsif ($txn->{is_sold}) {
            push(@close_trades, $txn);
        } elsif (!$txn->{is_sold}) {
            push(@open_trades, $txn);
        }
    }

    $transactions->{payment}     = \@payments;
    $transactions->{close_trade} = \@close_trades;
    $transactions->{open_trade}  = \@open_trades;

    return $transactions;
}
1;
