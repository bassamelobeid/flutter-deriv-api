package BOM::Platform::Webhook::IDV;

use strict;
use warnings;
use Log::Any qw($log);
use Syntax::Keyword::Try;
use Digest::SHA qw(sha256_hex);
use BOM::Config;
use DataDog::DogStatsd::Helper qw(stats_inc);
use BOM::Platform::Event::Emitter;
use MIME::Base64;

use parent qw(Mojolicious::Controller);

=head2 collect

Entrypoint for IDV webhook.

=cut

sub collect {
    my ($self) = @_;
    try {
        $self->send_event;
        return $self->render(json => 'ok');
    } catch ($error) {
        stats_inc('bom_platform.idv.webhook.bogus_payload');
        return $self->rendered(400);
    }
}

=head2 send_event

Emits the events sending the whole payload from IDV.

Returns the C<1> value

=cut

sub send_event {
    my ($self) = @_;
    my $json = $self->req->json;
    die 'malformed json' unless $json;

    BOM::Platform::Event::Emitter::emit(
        'idv_webhook',
        {
            headers => $self->req->headers->to_hash,
            body    => {
                json => $json,
                raw  => encode_base64($self->req->body)
            },
        });

    stats_inc('bom_platform.webhook.idv_webhook_received');
    return 1;
}

1;
