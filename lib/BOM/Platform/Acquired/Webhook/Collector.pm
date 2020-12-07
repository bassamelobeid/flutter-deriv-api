package BOM::Platform::Acquired::Webhook::Collector;

use strict;
use warnings;
use Log::Any qw($log);
use Log::Any::Adapter qw(Stderr), log_level => $ENV{ACQUIRED_LOG_LEVEL} // 'info';
use Syntax::Keyword::Try;
use Digest::SHA qw(sha256_hex);
use BOM::Config;
use DataDog::DogStatsd::Helper qw(stats_inc);
use BOM::Platform::Event::Emitter;

use parent qw(Mojolicious::Controller);

=head2 collect

Entrypoint for acquired webhook.

=cut

sub collect {
    my ($self) = @_;

    try {
        die 'not a valid acquired request' unless $self->validates;
        $self->send_event;
        return $self->render(json => 'ok');
    } catch ($error) {
        $log->errorf('Request failure: %s', $error);
        return $self->rendered(401);
    }
}

=head2 send_event

Emits the events sending the whole validated payload from acquired.

Returns the C<1> value

=cut

sub send_event {
    my ($self)   = @_;
    my $json     = $self->req->json;
    my $event    = $json->{event};
    my $provider = 'acquired';
    BOM::Platform::Event::Emitter::emit(
        dispute_notification => {
            provider => $provider,
            data     => $json
        });
    stats_inc("bom_platform.$provider.webhook.$event");
    return 1;
}

=head2 validates

Determines whether the request is a valid acquired webhook push.
https://developer.acquired.com/integrations/webhooks

Although the documentation from acquired is a bit confusing, we stick
with their code snippets.

Returns,
    true for a valid hash, false when the computed hash does not match the
    hash we got in the paylod for this request. Note we are talking about 
    a cryptographic sha256 hash.

=cut

sub validates {
    my ($self)           = @_;
    my $config           = BOM::Config::third_party();
    my $company_hashcode = $config->{acquired}->{company_hashcode} // 'dummy';
    my $json             = $self->req->json;
    # We are talking about a cryptographic hash not a perlish hash
    my $hash       = $json->{hash}       // die 'we expected a hash value in the body';
    my $id         = $json->{id}         // die 'we expected an id value in the body';
    my $timestamp  = $json->{timestamp}  // die 'we expected a timestamp value in the body';
    my $company_id = $json->{company_id} // die 'we expected a company_id value in the body';
    my $event      = $json->{event}      // die 'we expected a event value in the body';
    my $plain        = join '', ($id, $timestamp, $company_id, $event);
    my $temp         = sha256_hex($plain);
    my $expected     = join '', ($temp, $company_hashcode);
    my $sha_expected = sha256_hex($expected);

    return 1 if $hash eq $sha_expected;

    $log->errorf('Hash verification failed: expected [%s] seen [%s]', $sha_expected, $hash);
    return 0;
}

1;
