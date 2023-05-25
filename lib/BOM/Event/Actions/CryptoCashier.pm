package BOM::Event::Actions::CryptoCashier;

use strict;
use warnings;

=head1 NAME

BOM::Event::Actions::CryptoCashier

=head1 DESCRIPTION

Provides event handlers for the events received from the crypto cashier system.

=cut

use BOM::Config::Redis;
use BOM::Platform::Event::Emitter;

use JSON::MaybeUTF8 qw(encode_json_utf8);
use Log::Any        qw($log);
use Syntax::Keyword::Try;

use constant {
    REDIS_TRANSACTION_NAMESPACE => "CASHIER::PAYMENTS::",
};

use constant TRANSACTION_HANDLERS => {
    withdrawal => {
        REJECTED  => \&withdrawal_rejected_handler,
        SENT      => \&withdrawal_handler,
        LOCKED    => \&withdrawal_handler,
        CANCELLED => \&withdrawal_handler,
    },
    deposit => {
        PENDING   => \&deposit_handler,
        CONFIRMED => \&deposit_handler,
    },
};

my %currency_code_mapper = (
    UST => 'USDT',
);

=head2 crypto_cashier_transaction_updated

A crypto transaction has been updated.

The transaction data contains the following:

=over 4

=item * C<id>                 - The crypto cashier unique transaction ID

=item * C<address_hash>       - The destination crypto address

=item * C<address_url>        - The URL of the address on blockchain

=item * C<amount>             - [Optional] The transaction amount. Not present when deposit transaction still unconfirmed.

=item * C<currency_code>      - The currency code of the transaction.

=item * C<is_valid_to_cancel> - [Optional] Boolean value: 1 or 0, indicating whether the transaction can be cancelled. Only applicable for C<withdrawal> transactions

=item * C<status_code>        - The status code of the transaction

=item * C<status_message>     - The status message of the transaction

=item * C<submit_date>        - The epoch of the transaction date

=item * C<transaction_hash>   - [Optional] The transaction hash

=item * C<transaction_type>   - The type of the transaction. C<deposit> or C<withdrawal>

=item * C<transaction_url>    - [Optional] The URL of the transaction on blockchain

=item * C<confirmations>      - [Optional] number of confirmations for the pending transactions

=item * C<metadata>           - The client app metadata e.g: loginid, send_client_email (optional)

=over 4

=item * C<loginid>           - The client's loginid

=item * C<send_client_email> - [Optional] bool variable to prevent processing TRANSACTION_HANDLERS.

=back

=back

=cut

sub crypto_cashier_transaction_updated {
    my $txn_info = shift;

    my $tx_metadata       = delete $txn_info->{metadata};
    my $loginid           = $tx_metadata->{loginid};
    my $send_client_email = $tx_metadata->{send_client_email};

    my $redis     = BOM::Config::Redis->redis_transaction_write();
    my $redis_key = REDIS_TRANSACTION_NAMESPACE . $loginid;
    $redis->publish(
        $redis_key,
        encode_json_utf8({
                crypto         => [$txn_info],
                client_loginid => $loginid,
            }));

    return if defined $send_client_email && $send_client_email == 0;
    my $tx_status_handler = TRANSACTION_HANDLERS->{$txn_info->{transaction_type}}{$txn_info->{status_code}};
    $tx_status_handler->($txn_info, $tx_metadata) if $tx_status_handler;
}

=head2 withdrawal_handler

Handler for the withdrawal transaction with SENT status.

=over 4

=item * C<txn_info>     - A hashref of the transaction information.

=item * C<txn_metadata> - A hashref of the transaction metadata.

=back

=cut

sub withdrawal_handler {
    my ($txn_info, $txn_metadata) = @_;
    if ($txn_info->{status_code} eq 'SENT') {
        try {
            BOM::Platform::Event::Emitter::emit(
                'payment_withdrawal',
                {
                    loginid  => $txn_metadata->{loginid},
                    amount   => $txn_info->{amount},
                    currency => $txn_metadata->{currency_code},
                });
        } catch ($e) {
            $log->warnf("Failed to emit payment_withdrawal event for %s: %s", $txn_metadata->{loginid}, $e);
        }
    }

    try {
        BOM::Platform::Event::Emitter::emit(
            'crypto_withdrawal_email',
            {
                amount             => $txn_info->{amount},
                loginid            => $txn_metadata->{loginid},
                currency           => $currency_code_mapper{$txn_metadata->{currency_code}} // $txn_metadata->{currency_code},
                transaction_hash   => $txn_info->{transaction_hash},
                transaction_url    => $txn_info->{transaction_url},
                reference_no       => $txn_info->{id},
                transaction_status => $txn_info->{status_code},
            },
        );
    } catch ($e) {
        $log->warnf("Failed to emit crypto_withdrawal_%s\_email event for %s: %s", lc $txn_info->{status_code}, $txn_metadata->{loginid}, $e);
    }
}

=head2 deposit_handler

Handler for the deposit transaction with PENDING or CONFIRMED status.

=over 4

=item * C<txn_info>     - A hashref of the transaction information.

=item * C<txn_metadata> - A hashref of the transaction metadata.

=back

=cut

sub deposit_handler {
    my ($txn_info, $txn_metadata) = @_;

    try {
        BOM::Platform::Event::Emitter::emit(
            'crypto_deposit_email',
            {
                loginid            => $txn_metadata->{loginid},
                amount             => $txn_info->{amount},
                currency           => $currency_code_mapper{$txn_metadata->{currency_code}} // $txn_metadata->{currency_code},
                transaction_hash   => $txn_info->{transaction_hash},
                transaction_status => $txn_info->{status_code},
                transaction_url    => $txn_info->{transaction_url},
            },
        );
    } catch ($e) {
        $log->warnf("Failed to emit crypto_deposit_%s\_email event for %s: %s", lc $txn_info->{status_code}, $txn_metadata->{loginid}, $e);
    }
}

=head2 withdrawal_rejected_handler

Handler for the withdrawal transaction with REJECTED status.

=over 4

=item * C<$txn_info>     - A hashref of the transaction information.

=item * C<$txn_metadata> - A hashref of the transaction metadata.

=back

=cut

sub withdrawal_rejected_handler {
    my ($txn_info, $txn_metadata) = @_;

    try {
        BOM::Platform::Event::Emitter::emit(
            'crypto_withdrawal_rejected_email_v2',
            {
                amount        => $txn_info->{amount},
                loginid       => $txn_metadata->{loginid},
                currency      => $currency_code_mapper{$txn_metadata->{currency_code}} // $txn_metadata->{currency_code},
                reference_no  => $txn_info->{id},
                reject_code   => $txn_metadata->{reason_code},
                reject_remark => (($txn_metadata->{reason} && $txn_metadata->{reason_code} eq 'other')) ? $txn_metadata->{reason} : '',
            },
        );
    } catch ($e) {
        $log->warnf("Failed to emit crypto_withdrawal_rejected_email_v2 event for %s: %s", $txn_metadata->{loginid}, $e);
    }
}

1;
