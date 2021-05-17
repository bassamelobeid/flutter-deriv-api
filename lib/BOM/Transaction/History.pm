package BOM::Transaction::History;

=head1 BOM::Transaction::History
ABSTRACT: Transaction related functions of bom-transaction
=cut

use strict;
use warnings;

no indirect;

use Date::Utility;
use JSON::MaybeXS;
use BOM::Platform::Context qw(localize);
use Format::Util::Numbers qw(formatnumber);

my $json = JSON::MaybeXS->new;

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

    my $clientdb = BOM::Database::ClientDB->new({
        broker_code => $client->broker_code,
        operation   => 'replica',
    });

    my $results = [];
    if ($args->{action_type} and $args->{action_type} eq 'transfer') {
        $results = $clientdb->db->dbic->run(
            fixup => sub {
                $_->selectall_arrayref(
                    'SELECT * FROM transaction.get_account_transfer_details(?, ?, ?, ?, ?)',
                    {Slice => {}},
                    $account->id, $args->@{qw/date_from date_to limit offset/});
            });
    } else {
        $results = $clientdb->db->dbic->run(
            fixup => sub {
                $_->selectall_arrayref(
                    'SELECT * FROM transaction.get_history_details(?, ?, ?, ?, ?, ?)',
                    {Slice => {}},
                    $account->id, $args->@{qw/date_from date_to action_type limit offset/});
            });
    }

    for my $txn (@$results) {
        # Set transaction time for different transaction types
        my $txn_time = _get_txn_time($txn);
        $txn->{transaction_time} = Date::Utility->new($txn_time)->epoch();

        $txn->{details} = $json->decode($txn->{details}) if $txn->{details};

        # Get localized user-friendly payment remark
        $txn->{payment_remark} = _get_txn_remark($txn, $client) // $txn->{payment_remark};

        my $txn_account_transfer_details = get_account_transfer_details($txn, $client);

        if ($txn_account_transfer_details) {
            $txn->{fees} = $txn_account_transfer_details->{fees};
            $txn->{from} = $txn_account_transfer_details->{from};
            $txn->{to}   = $txn_account_transfer_details->{to};
        }
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

=head2 _get_txn_remark

Produces a localized remark for a transaction item using the information in <details>.

=over 4

=item * C<txn> - transaction hashref

=item * C<client> - L<BOM::User::Client> instance of client making request

=back

Returns the remark as string.

=cut

sub _get_txn_remark {
    my ($txn, $client) = @_;

    my $details = $txn->{details}              // return;
    my $gateway = $txn->{payment_gateway_code} // '';

    # MT5
    if (my $mt5_account = $details->{mt5_account}) {
        if ($txn->{action_type} eq 'transfer') {
            if ($txn->{amount} < 0) {
                if ($details->{fees} > 0) {
                    return localize('Transfer to MT5 account [_1]. [_2].', $mt5_account, _get_fee_remark($details));
                }
                return localize('Transfer to MT5 account [_1]', $mt5_account);
            } else {
                if ($details->{fees} > 0) {
                    return localize('Transfer from MT5 account [_1]. [_2].', $mt5_account, _get_fee_remark($details));
                }
                return localize('Transfer from MT5 account [_1]', $mt5_account);
            }
        }
    }

    # Doughflow
    if ($gateway eq 'doughflow') {
        my $method = $details->{payment_method} // $details->{payment_processor};
        if ($details->{transaction_type} eq 'withdrawal_reversal') {
            return localize('Reversal of [_1] trace ID [_2]', $method, $details->{trace_id});
        }
        return localize('[_1] trace ID [_2]', $method, $details->{trace_id});
    }

    # Doughflow fee
    if ($gateway eq 'payment_fee' and $details->{trace_id}) {
        my $method = $details->{payment_method} // $details->{payment_processor};
        if ($txn->{amount} > 0) {
            return localize('Reversal of fee for [_1] trace ID [_2]', $method, $details->{trace_id});
        }
        return localize('Fee for [_1] trace ID [_2]', $method, $details->{trace_id});
    }

    # Crypto
    if ($gateway eq 'ctc') {
        if ($details->{transaction_hash}) {
            return localize('Address: [_1], transaction: [_2]', $details->{address}, $details->{transaction_hash});
        } else {
            return localize('Address: [_1]', $details->{address});
        }
    }

    # Account transfers
    if ($gateway eq 'account_transfer' and $txn->{payment_type_code} eq 'internal_transfer') {
        if ($txn->{action_type} eq 'transfer') {
            if ($txn->{amount} < 0) {
                if ($details->{fees} > 0) {
                    return localize('Account transfer to [_1]. [_2].', $details->{to_login}, _get_fee_remark($details));
                }
                return localize('Account transfer to [_1]', $details->{to_login});
            } else {
                if ($details->{fees} > 0) {
                    return localize('Account transfer from [_1]. [_2].', $details->{from_login}, _get_fee_remark($details));
                }
                return localize('Account transfer from [_1]', $details->{from_login});
            }
        }
    }

    # P2P escrow hold / order create
    if ($txn->{action_type} eq 'hold') {
        if ($client->loginid ne $details->{client_loginid}) {
            return localize(
                'P2P order [_1] created by [_2] ([_3]) - seller funds held',
                $details->{order_id},
                $details->{client_nickname},
                $details->{client_loginid});
        } else {
            return localize('P2P order [_1] created - seller funds held', $details->{order_id});
        }
    }

    # P2P escrow release
    if ($txn->{action_type} eq 'release') {
        my $status = $details->{status};
        if ($status eq 'cancelled') {
            return localize('P2P order [_1] cancelled - seller funds released', $details->{order_id});
        } elsif ($status =~ /^(refunded|dispute-refunded)$/) {
            return localize('P2P order [_1] refunded - seller funds released', $details->{order_id});
        } elsif ($status =~ /^(completed|dispute-completed)$/) {
            return localize('P2P order [_1] completed - seller funds released', $details->{order_id});
        }
    }

    # P2P payments
    if ($gateway eq 'p2p') {
        if ($txn->{amount} > 0) {
            return localize(
                'P2P order [_1] completed - funds received from [_2] ([_3])',
                $details->{order_id},
                $details->{seller_nickname},
                $details->{seller_loginid});
        } else {
            return localize(
                'P2P order [_1] completed - funds transferred to [_2] ([_3])',
                $details->{order_id},
                $details->{buyer_nickname},
                $details->{buyer_loginid});
        }
    }

    # Pruned transactions
    if ($txn->{action_type} eq 'adjustment' and $txn->{referrer_type} eq 'prune') {
        return localize('Balance operation');
    }

    # DXtrader
    if (my $dxtrade_account = $details->{dxtrade_account_id}) {
        if ($txn->{amount} < 0) {
            if ($details->{fees} > 0) {
                return localize('Transfer to Deriv X account [_1]. [_2].', $dxtrade_account, _get_fee_remark($details));
            }
            return localize('Transfer to Deriv X account [_1]', $dxtrade_account);
        } else {
            if ($details->{fees} > 0) {
                return localize('Transfer from Deriv X account [_1]. [_2].', $dxtrade_account, _get_fee_remark($details));
            }
            return localize('Transfer from Deriv X account [_1]', $dxtrade_account);
        }
    }

    return undef;
}

=head2 _get_fee_remark

Procduces a localized remark for a transfer fee.
The logic is mostly the same as get_transfer_fee_remark() in bom-rpc.

Takes a hashref with the following keys:

=over 4

=item * C<fee_calculated_by_percent> - raw calculated fee

=item * C<min_fee> - mimimum fee

=item * C<fees_currency> - currency of fee

=back

Returns the remark as string.

=cut

sub _get_fee_remark {
    my $args = shift;

    if ($args->{fee_calculated_by_percent} >= $args->{min_fee}) {
        return localize(
            'Includes transfer fee of [_1] [_2] ([_3]%)',
            formatnumber('amount', $args->{fees_currency}, $args->{fee_calculated_by_percent}),
            $args->{fees_currency},
            $args->{fees_percent}) if $args->{fee_calculated_by_percent} >= $args->{min_fee};
    }

    return localize(
        'Includes the minimum transfer fee of [_1] [_2]',
        formatnumber('amount', $args->{fees_currency}, $args->{min_fee}),
        $args->{fees_currency});
}

=head2 get_account_transfer_details

Get the account transfer details for the transaction

Takes the following arguments

=over 4

=item * C<txn> - hashref containing details of transaction

=item * C<client> - client object

=back

Returns a hashref with following structure:

    {
        fees => {
            amount => 2,
            minimum => 0.1,
            percentage => 1,
            currency => USD,
        },
        from => {
            loginid => "CR9000",
        },
        to => {
            loginid => "MTR1000",
        }
    }

=cut

sub get_account_transfer_details {
    my ($txn, $client) = @_;

    return undef unless $txn->{details};

    my $gateway = $txn->{payment_gateway_code} // '';

    return undef unless $gateway eq 'account_transfer';

    my $payment_type = $txn->{payment_type_code} // '';

    return undef unless $payment_type =~ /^(?:internal_transfer|mt5_transfer)$/;

    my $details = $txn->{details};

    if ($payment_type eq 'mt5_transfer') {
        my $response = get_mt5_transfer_details($txn, $client);

        if ($response) {
            $details->{from_login} = $response->{from_login};
            $details->{to_login}   = $response->{to_login};
        }
    }

    return {
        fees => {
            percentage => ($details->{fees_percent}  // 0.0),
            minimum    => ($details->{min_fee}       // '0.0'),
            currency   => ($details->{fees_currency} // ''),
            amount => ($details->{fees_currency} and $details->{fees}) ? formatnumber('amount', $details->{fees_currency}, $details->{fees}) : 0.0,
        },
        from => {
            loginid => $details->{from_login},
        },
        to => {
            loginid => $details->{to_login},
        },
    };
}

=head2 get_mt5_transfer_details

Get mt5 details for the transfer transaction.
Populates from and to details as we don't have those
in database.

Takes the following arguments

=over 4

=item * C<txn> - hashref containing details of transaction

=item * C<client> - client object

=back

Returns a hashref with following structure:

    {
        from_login => "CR9000",
        to_login   => "MTR100,
    }

=cut

sub get_mt5_transfer_details {
    my ($txn, $client) = @_;

    return undef unless $txn->{details};

    my $details = $txn->{details};

    my $response;
    # deposit to client account if amount is positive
    if ($txn->{amount} > 0) {
        $response->{to_login}   = $client->loginid;
        $response->{from_login} = 'MTR' . $details->{mt5_account};
    } else {
        # withdraw from client account
        $response->{from_login} = $client->loginid;
        $response->{to_login}   = 'MTR' . $details->{mt5_account};
    }

    return $response;
}

1;
