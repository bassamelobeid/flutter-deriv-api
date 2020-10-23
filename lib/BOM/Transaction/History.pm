package BOM::Transaction::History;

=head1 BOM::Transaction::History
ABSTRACT: Transaction related functions of bom-transaction
=cut

use strict;
use warnings;

no indirect;

use Date::Utility;

use Exporter qw(import);
our @EXPORT_OK = qw(get_transaction_history);

# maximum number of transaction history items to return
use constant HISTORY_LIMIT => 1000;

=head2 get_transaction_history

Get transactions of any given client

=over 4

=item * client - client to get transaction history for

=item * args - see below

=back

C<args> contains:

=over 4

=item * action_type of transaction.transaction table: 'buy', 'sell', 'withdrawal', 'deposit', 'escrow' etc. (optional parameter)

=item * limit - limit of transactions (optional parameter). There is an upper limit of 1000.

=item * offset - skip transactions by offset amount (optional parameter)

=item * date_from - get transaction history from (optional parameter)

=item * date_to - get transaction history top (optional parameter)

=back

Returns a hashref of structured transactions.

=cut

sub get_transaction_history {
    my $params = shift;

    my ($client, $args) = $params->@{qw/client args/};

    my $account = $client->default_account;

    return unless $account;

    for my $dt (qw/date_to date_from/) {
        $args->{$dt} = Date::Utility->new($args->{$dt})->datetime if defined $args->{$dt};
    }

    $args->{limit} = HISTORY_LIMIT unless defined $args->{limit} and $args->{limit} < HISTORY_LIMIT;

    my $results = $client->db->dbic->run(
        fixup => sub {
            $_->selectall_arrayref(
                'SELECT * FROM transaction.get_transaction_history(?, ?, ?, ?, ?, ?)',
                {Slice => {}},
                $account->id, $args->@{qw/date_from date_to action_type limit offset/});
        });

    # Set transaction time for different transaction types
    for my $txn (@$results) {
        my $txn_time = _get_txn_time($txn);
        $txn->{transaction_time} = Date::Utility->new($txn_time)->epoch();
    }

    return $results;
}

sub _get_txn_time {
    my $txn = shift;

    # Financial market bet
    my $time_type = $txn->{action_type} eq 'sell' ? 'sell_time' : 'purchase_time';
    return $txn->{$time_type} if $txn->{financial_market_bet_id};

    # Payment
    return $txn->{payment_time} if $txn->{payment_id};

    # P2P escrow
    return $txn->{escrow_time} if $txn->{referrer_type} eq 'p2p';

    # Other
    return $txn->{transaction_time};
}

1;
