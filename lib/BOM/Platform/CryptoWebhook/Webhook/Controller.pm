package BOM::Platform::CryptoWebhook::Webhook::Controller;

use strict;
use warnings;
no indirect;

use DataDog::DogStatsd::Helper qw(stats_inc);
use Log::Any                   qw($log);

use BOM::Platform::CryptoWebhook::Webhook::PaymentProcessor;

use parent qw(Mojolicious::Controller);

use constant {
    DD_METRIC_PREFIX     => 'bom_platform.crypto_webhook.',
    DD_INVALID_SIGNATURE => 'invalid_signature',
    DD_INVALID_REQUEST   => 'invalid_req',
    DD_INVALID_PAYLOAD   => 'invalid_payload',
    TYPE_DEPOSIT         => 'deposit',
    TYPE_WITHDRAWAL      => 'withdrawal',
};

=head2 processor_coinspaid

Process Coinspaid requests

=cut

sub processor_coinspaid {
    my ($self) = @_;
    my $coinspaid = BOM::Platform::CryptoWebhook::Webhook::PaymentProcessor->new(processor_name => 'Coinspaid');

    my $signature = $self->req->headers->header('X-Processing-Signature');

    my $processor_name = lc $coinspaid->processor_name;

    return $self->render_request_with_dd(401, $processor_name, DD_INVALID_SIGNATURE)
        unless $coinspaid->validate_signature($signature, $self->req->body);

    my $json = $self->req->json;
    return $self->render_request_with_dd(200, $processor_name, DD_INVALID_REQUEST) unless $json;

    my $payload_type = $json->{type};
    return $self->render_request_with_dd(200, $processor_name, DD_INVALID_REQUEST)
        unless $payload_type && ($payload_type eq TYPE_DEPOSIT || $payload_type eq TYPE_WITHDRAWAL);

    my $result = $payload_type eq TYPE_DEPOSIT ? $coinspaid->process_deposit($json) : $coinspaid->process_withdrawal($json);

    if ($result->{error}) {
        #logging this may be omitted
        $log->infof("Error processing Coinspaid %s. Error: %s, trace_id: %s, tx_id: %s",
            $payload_type, $result->{error}, $json->{id},
            (ref $json->{transactions} eq 'ARRAY' ? $json->{transactions}->[0]{txid} : $json->{transactions}));
        return $self->render_request_with_dd(200, $processor_name, DD_INVALID_PAYLOAD);
    }

    #here we have validated and proper transactions to emit
    #chances are unlikely that we would recieve more than one transaction in the $result->{transactions} array
    my $emitted = 0;
    if ($result->{is_success} && $payload_type eq TYPE_DEPOSIT) {

        $emitted += $coinspaid->emit_deposit_event($_) for $result->{transactions}->@*;

        #there is a possiblity that for one transaction, event emit_deposit_event/emit_withdrawal_event emitted successfully but for other it failed
        #though error happend at our end, no harm to return 401 to Coinspaid to receive the same transactions notification again from them
        return $self->rendered(401) unless $emitted == scalar(@{$result->{transactions}});
        return $self->rendered(200);
    } elsif ($result->{is_success} && $payload_type eq TYPE_WITHDRAWAL) {
        $emitted += $coinspaid->emit_withdrawal_event($_) for $result->{transactions}->@*;
        return $self->rendered(401) unless $emitted == scalar(@{$result->{transactions}});
        return $self->rendered(200);
    }

    #ideally should not reach here
    return $self->render_request_with_dd(200, $processor_name, DD_INVALID_REQUEST);
}

=head2 render_request_with_dd

Renders reqeust with dd logging

=over 4

=item * C<response_code>  - number (default 401), a response code in the request's response.

=item * C<processor_name> - string (optional), used in datadog tags

=item * C<dd_key> - string (optional), used in datadog metric key

=back

=cut

sub render_request_with_dd {
    my ($self, $response_code, $processor_name, $dd_key) = @_;
    stats_inc(DD_METRIC_PREFIX . $dd_key, {tags => ['proccessor:' . $processor_name]}) if $dd_key && $processor_name;
    return $self->rendered($response_code // 401);
}

=head2 invalid_request

Renders 401 status code

=cut

sub invalid_request {
    my ($self) = @_;
    return $self->rendered(401);
}

1;
