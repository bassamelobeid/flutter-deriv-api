package BOM::Platform::CryptoWebhook::Webhook::PaymentProcessor::Coinspaid;

use strict;
use warnings;
no indirect;

=head1 NAME

BOM::Platform::CryptoWebhook::Webhook::PaymentProcessor::Coinspaid

=head1 DESCRIPTION

Package for handling callbacks from Coinspaid, a third party payment provider

=cut

use Digest::SHA qw(hmac_sha512_hex);
use List::Util  qw( first );

use parent qw(BOM::Platform::CryptoWebhook::Webhook::PaymentProcessor::Base);

use Log::Any qw($log);
use Math::BigFloat;

use constant {
    #mapping coinspaid's transaction status to our system based status
    STATUS_MAPPING => {
        not_confirmed => 'pending',
    },
    #mapping coinspaid's currency_code to our system based
    CURRENCY_MAPPING => {
        USDTT => 'tUSDT',
    },
    #fee types for deposit transactions
    FEE_TYPES_DEPOSIT => {
        fee_crypto_deposit          => 1,
        fee_crypto_deposit_internal => 1
    },
    #fee types for withdrawal transactions
    FEE_TYPES_WITHDRAWAL => {
        fee_crypto_withdrawal          => 1,
        fee_crypto_withdrawal_internal => 1
    }};

=head2 new

The constructor, returns a new instance of this module.

=cut

sub new {
    my ($class) = @_;
    return bless {}, $class;
}

=head2 processor_name

Returns payment processor name

=cut

sub processor_name {
    return "Coinspaid";
}

=head2 validate_signature

Verify the C<X-Processing-Signature> header from request to validate authencity of request

=over 4

=item C<provided_signature>  - signature string taken from request header

=item C<body>            - body passed with request

=back

Returns 1 if valid otherwise 0

=cut

sub validate_signature {
    my ($self, $provided_signature, $body) = @_;
    return 0 unless $provided_signature;
    my $api_secret   = $self->signature_keys->{secret_key} // die 'Coinspaid: api secret is missing';
    my $expected_sig = hmac_sha512_hex($body // '', $api_secret);
    return $provided_signature eq $expected_sig;
}

=head2 transform_status

Transforms the transaction status from Coinspaid to Our system acceptable. Eg not-confirmed should be pending for our system.
Receives the following named parameters:

=over 4

=item C<status> - string, a status of transaction from Coinspaid (processor)

=back

=over 4

Returns transformed status mapped in STATUS_MAPPING, if not found in STATUS_MAPPING mapping, returns the passed status as it is

=back

=cut

sub transform_status {
    my ($self, $status) = @_;
    return undef unless $status;
    return STATUS_MAPPING->{$status} // $status;
}

=head2 transform_currency

Transforms the currency_code from Coinspaid to Our system acceptable. Eg USDTT should be tUSDT for our system.
Receives the following named parameters:

=over 4

=item C<currency_code> - string, currency_code of transaction from Coinspaid (processor)

=back

=over 4

Returns transformed currency mapped in CURRENCY_MAPPING, if not found in CURRENCY_MAPPING mapping, returns the passed currency as it is

=back

=cut

sub transform_currency {
    my ($self, $currency_code) = @_;
    return undef unless $currency_code;
    return CURRENCY_MAPPING->{$currency_code} // $currency_code;
}

=head2 process_deposit

processes deposit request

Receives the following named parameters:

=over 4

=item * C<payload>       - hashRef containes blockchain data as per payment processor

=back


Returns hashRef containing keys success if payload processed successfully along with transactions key containing normalized transactions array.
Otherwise contains error key containing error message

=over 4

=item * C<is_success>     - boolean C<1> if successfully processed C<0>

=item * C<error>          - string, error message.

=item * C<transactions>   - arrayRef containing hashRef of normalized transactions (normalized as per emit_deposit_event)

=back

=cut

sub process_deposit {
    my ($self, $payload) = @_;
    my ($id, $transactions, $fees, $error, $status, $currency_received) = @{$payload}{qw/id transactions fees error status currency_received/};

    #todo proper error code and error message implementation
    my @required_params = qw/id transactions status currency_received/;
    my $missing_param   = first { !defined($payload->{$_}) || (ref $payload->{$_} eq 'ARRAY' && !@{$payload->{$_}}) } @required_params;
    return {error => "$missing_param not found in payload"} if $missing_param;

    defined $currency_received->{$_} or (return {error => "$_ not found in currency_received payload"}) for qw(currency amount amount_minus_fee);

    my ($currency, $amount, $amount_minus_fee) = @{$currency_received}{qw/ currency amount amount_minus_fee/};

    my $fee = Math::BigFloat->new($amount)->bsub($amount_minus_fee);

    $log->warnf("Error processing Coinspaid Deposit Fee. fees: %s, trace_id: %s, tx_id: %s",
        $fees, $id, (ref $transactions eq 'ARRAY' ? $transactions->[0]{txid} : $transactions))
        if $status eq 'confirmed' && $fee->is_negative();

    my @normalized_txns;
    #since coinspaid returns transactions as an array list, we handle each of it
    # if any of transaction parsing fails, we discard all the transactions & return not ok result to coinspaid
    for my $txn ($transactions->@*) {
        defined $txn->{$_} or (return {error => "$_ not found in transactions payload"}) for qw(address currency txid amount);

        return {error => "transaction amount not matching with currency_received amount"}
            if Math::BigFloat->new($txn->{amount})->bne($amount);

        my $normalize_txn = {
            trace_id         => $id,
            status           => $self->transform_status($status),
            error            => $error // '',
            address          => $txn->{address},
            amount           => $txn->{amount},
            amount_minus_fee => $amount_minus_fee,
            currency         => $self->transform_currency($txn->{currency}),
            hash             => $txn->{txid},
            transaction_fee  => $fee->bstr()          // 0,    #for pending transactions, fee is not returned from coinspaid
            confirmations    => $txn->{confirmations} // 0,
        };

        push @normalized_txns, $normalize_txn;
    }

    return {
        is_success   => 1,
        transactions => \@normalized_txns,
    };
}

=head2 process_withdrawal

processes withdrawal request

Receives the following named parameters:

=over 4

=item * C<payload>       - hashRef containes blockchain data as per payment processor

=back


Returns hashRef containing keys success if payload processed successfully along with transactions key containing normalized transactions array.
Otherwise contains error key containing error message

=over 4

=item * C<is_success>     - boolean C<1> if successfully processed C<0>

=item * C<error>          - string, error message.

=item * C<transactions>   - arrayRef containing hashRef of normalized transactions (normalized as per emit_deposit_event)

=back

=cut

sub process_withdrawal {
    my ($self, $payload) = @_;
    my ($id, $foreign_id, $transactions, $fees, $error, $status) = @{$payload}{qw/ id foreign_id transactions fees error status/};

    return {error => 'id not found in payload'}           unless $id;
    return {error => 'foreign_id not found in payload'}   unless $foreign_id;
    return {error => 'transactions not found in payload'} unless $transactions && @{$transactions};
    return {error => 'fees not found in payload'}         unless $fees;
    return {error => 'status not found in payload'}       unless $status;

    #iterate fees and check if withdrawal fees is sent otherwise adds a log
    #fees will be empty for pending(not_confirmed) and cancelled transactions
    my $fee = first { FEE_TYPES_WITHDRAWAL->{($_->{type} // '')} } $fees->@*;

    my @normalized_txns;
    #since coinspaid returns transactions as an array list, we handle each of it
    #if any of transaction parsing fails, we discard all the transactions & return not ok result to coinspaid
    for my $txn ($transactions->@*) {
        defined $txn->{$_} or (return {error => "$_ not found in transactions payload"}) for qw(address currency txid amount);

        my $normalize_txn = {
            trace_id        => $id,
            reference_id    => $foreign_id,
            status          => $self->transform_status($status),
            error           => $error // '',
            address         => $txn->{address},
            amount          => $txn->{amount},
            currency        => $self->transform_currency($txn->{currency}),
            hash            => $txn->{txid},
            transaction_fee => $fee->{amount}        // 0,
            confirmations   => $txn->{confirmations} // 0,
        };

        push @normalized_txns, $normalize_txn;
    }

    return {
        is_success   => 1,
        transactions => \@normalized_txns,
    };
}

1;
