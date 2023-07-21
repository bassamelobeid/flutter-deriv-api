package BOM::Platform::CryptoWebhook::Webhook::PaymentProcessor::Base;

use strict;
use warnings;
no indirect;

=head1 DESCRIPTION

Base abstract package. Will be used/extended by Different Crypto third party payment processors.

=cut

use DataDog::DogStatsd::Helper qw(stats_inc);
use Log::Any                   qw($log);
use Syntax::Keyword::Try;

use BOM::Config;
use BOM::Platform::Event::Emitter;

use constant {
    SYS_NOT_IMPLEMENTED => "Not implemented %s %s %s",
    DD_METRIC_PREFIX    => 'bom_platform.crypto_webhook.',
};

=head2 new

The constructor, returns a new instance of this module.

=cut

sub new {
    my ($class) = @_;
    return bless {}, $class;
}

=head2 config

Builds the config (api secret, token etc) 

=cut

sub config {
    my ($self) = @_;
    return BOM::Config::third_party()->{crypto_webhook} // die 'missing crypto third party payment processors api tokens config';
}

=head2 processor_name

Returns undef from base class.

=cut

sub processor_name {
    return undef;
}

=head2 signature_keys

Returns processor's signature keys/token

=cut

sub signature_keys {
    my $self = shift;
    return $self->config->{lc($self->processor_name // '')} // die 'missing signature keys/token for ' . ($self->processor_name // '');
}

# Required methods
# this methods must been declared in all third party crypto payment processor packages
# or its respective parent, if not implemented we return error.

=head2 validate_signature

Verify the C<X-Processing-Signature> header from request to validate authencity of request

=cut

sub validate_signature {
    die sprintf(SYS_NOT_IMPLEMENTED, caller);
}

=head2 transform_status

Transforms the third party transaction status as per our statuses

=cut

sub transform_status {
    die sprintf(SYS_NOT_IMPLEMENTED, caller);
}

=head2 transform_currency

Transforms the third party currency code as per our.

=cut

sub transform_currency {
    die sprintf(SYS_NOT_IMPLEMENTED, caller);
}

=head2 process_deposit

Process deposit requests received from third party

=cut

sub process_deposit {
    die sprintf(SYS_NOT_IMPLEMENTED, caller);
}

=head2 process_withdrawal

Process withdrawal requests received from third party

=cut

sub process_withdrawal {
    die sprintf(SYS_NOT_IMPLEMENTED, caller);
}

=head2 emit_deposit_event

We need to emit deposit event after processing and validating deposit in 'process_deposit' sub in its respective processor package.
The params used here are agnostic of third party (external payment) processor/providers.

Receives the following named parameters in transaction hashref passed from every processor calling this sub:

=over 4

=item * C<trace_id>          - for reference transaction at processor's side

=item * C<status>            - string, transaction status from processor's side transformed as per our system based status

=item * C<error>             - string, error message

=item * C<address>           - crypto address

=item * C<amount>            - transaction amount

=item * C<amount_minus_fee>  - transaction amount minus fee

=item * C<currency>          - currency code of transaction from processor's side transformed as per our currency code

=item * C<hash>              - transaction hash

=item * C<transaction_fee>   - transaction fee

=back

Return 1 if event emitted successfully otherwise 0

=cut

sub emit_deposit_event {
    my ($self, $transaction) = @_;
    my $processor_name = lc($self->processor_name // '');

    #to enforce derived class must sent these fields else it dies
    defined $transaction->{$_} or die "missing parameter $_" for qw(trace_id status address amount currency hash transaction_fee amount_minus_fee);

    try {
        my $is_emitted = BOM::Platform::Event::Emitter::emit(
            'crypto_notify_external_deposit',
            {
                trace_id         => $transaction->{trace_id},
                status           => $transaction->{status},
                error            => $transaction->{error} // '',
                address          => $transaction->{address},
                amount           => $transaction->{amount},
                currency         => $transaction->{currency},
                hash             => $transaction->{hash},
                transaction_fee  => $transaction->{transaction_fee},
                amount_minus_fee => $transaction->{amount_minus_fee},
            });
        die "event could not be emitter" unless $is_emitted;
        stats_inc(DD_METRIC_PREFIX . 'deposit', {tags => ['currency:' . $transaction->{currency}, 'status:success', 'processor:' . $processor_name]});
    } catch ($e) {
        stats_inc(DD_METRIC_PREFIX . 'deposit', {tags => ['currency:' . $transaction->{currency}, 'status:failed', 'processor:' . $processor_name]});
        $log->warnf('%s : Error while emitting emit_deposit_event. Error: %s', $self->processor_name, $e);
        return 0;
    }
    return 1;
}

=head2 emit_withdrawal_event

Same as 'emit_deposit_event', we need to emit withdrawal event after processing and validating withdrawal in 'process_withdrawal' sub in its respective processor package.
The params used here are agnostic of third party (external payment) processor/providers.

Receives the following named parameters in transaction hashref passed from every processor calling this sub:

=over 4

=item * C<trace_id>          - for reference transaction at processor's side

=item * C<reference_id>      - The withdrawal request DB row ID that was sent to the third party as foreign_id

=item * C<status>            - string, transaction status from processor's side transformed as per our system based status

=item * C<error>             - string, error message

=item * C<address>           - crypto address

=item * C<amount>            - transaction amount

=item * C<currency>          - currency code of transaction from processor's side transformed as per our currency code

=item * C<hash>              - transaction hash

=item * C<transaction_fee>   - transaction fee

=back

Return 1 if event emitted successfully otherwise 0

=cut

sub emit_withdrawal_event {
    my ($self, $transaction) = @_;
    my $processor = lc($self->processor_name // '');

    #to enforce derived class must sent these fields else it dies
    defined $transaction->{$_} or die "missing parameter $_" for qw(trace_id reference_id status address amount currency hash transaction_fee);

    try {
        my $is_emitted = BOM::Platform::Event::Emitter::emit(
            'crypto_notify_external_withdrawal',
            {
                trace_id        => $transaction->{trace_id},
                reference_id    => $transaction->{reference_id},
                status          => $transaction->{status},
                error           => $transaction->{error} // '',
                address         => $transaction->{address},
                amount          => $transaction->{amount},
                currency        => $transaction->{currency},
                hash            => $transaction->{hash},
                transaction_fee => $transaction->{transaction_fee},
            });
        die "event could not be emitter" unless $is_emitted;
        stats_inc(DD_METRIC_PREFIX . 'withdrawal', {tags => ['currency:' . $transaction->{currency}, 'status:success', 'processor:' . $processor]});
    } catch ($e) {
        stats_inc(DD_METRIC_PREFIX . 'withdrawal', {tags => ['currency:' . $transaction->{currency}, 'status:failed', 'processor:' . $processor]});
        $log->warnf('%s : Error while emitting emit_deposit_event. Error: %s', $self->processor_name, $e);
        return 0;
    }
    return 1;
}

1;
