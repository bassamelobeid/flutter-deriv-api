package BOM::Platform::Webhook::ISignThis;

use strict;
use warnings;
use Syntax::Keyword::Try;
use Digest::SHA qw(hmac_sha256_base64);
use BOM::Config;
use DataDog::DogStatsd::Helper qw(stats_inc);
use BOM::Platform::Event::Emitter;

use parent qw(Mojolicious::Controller);

=head2 collect

Entrypoint for the ISignThis webhook.

=cut

sub collect {
    my ($self) = @_;

    try {
        die 'not a valid isignthis request' unless $self->validates;
        $self->send_event;
        return $self->render(json => 'ok');
    } catch ($error) {
        stats_inc('bom_platform.isignthis.webhook.missing_checksum_header') if $error =~ /no checksum header found/;
        stats_inc('bom_platform.isignthis.webhook.bogus_payload')           if $error =~ /we expected/;
        return $self->rendered(401);
    }

    return $self->render(json => 'ok');
}

=head2 send_event

Emits the events sending the whole validated payload from ISignThis.

Returns the C<1> value

=cut

sub send_event {
    my ($self)   = @_;
    my $json     = $self->req->json;
    my $event    = $json->{event};
    my $provider = 'isignthis';
    BOM::Platform::Event::Emitter::emit(
        dispute_notification => {
            provider => $provider,
            data     => $json
        });
    stats_inc("bom_platform.$provider.webhook.$event");
    return 1;
}

=head2 validates

Determines whether the request is a valid ISignThis webhook notification.
https://docs.api.isignthis.com/notification/

Check the X-ISX-Checksum value which should match the HMAC of the request body.

Returns,
    true for a valid body, false when the body does not match the expected
    cryptographic hash

=cut

sub validates {
    my ($self) = @_;
    my $req    = $self->req;
    my $json   = $self->req->json;

    die 'we expected an event' unless defined $json->{event};

    my $sig      = $req->headers->header('x-isx-checksum') or die 'no checksum header found';
    my $config   = BOM::Config::third_party();
    my $token    = $config->{isignthis}->{notification_token} // 'dummy';
    my $expected = hmac_sha256_base64($req->body, $token);

    # pad the base64
    while (length($expected) % 4) {
        $expected .= '=';
    }

    return 1 if $sig eq $expected;

    stats_inc('bom_platform.isignthis.webhook.checksum_mismatch');
    return 0;
}

1;
