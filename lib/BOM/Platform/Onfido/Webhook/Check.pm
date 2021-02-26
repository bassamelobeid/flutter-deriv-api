package BOM::Platform::Onfido::Webhook::Check;

use strict;
use warnings;

use parent qw(Mojolicious::Controller);

use Syntax::Keyword::Try;
use Log::Any qw($log);
use BOM::Platform::Event::Emitter;
use Digest::HMAC;
use Digest::SHA1;
use BOM::Config;
use DataDog::DogStatsd::Helper qw/stats_inc/;

=head2 check

Onfido webhook Entrypoint for checks
Validates the C<X-Signature> from the request
Compares the $check's payload{action} to be check.completed & emit client_verification event otherwise returns ok

Returns Mojolicious http response to onfido with `failed` or `ok`.

=cut

sub check {
    my ($self) = @_;
    try {
        my $req       = $self->req;
        my $validated = $self->validate_signature($req);
        # Mostly this happens when we manually check webhook from onfido end. in that case signatures are missing.
        unless ($validated) {
            $self->render(text => 'failed');
            return;
        }

        my $check = $self->req->json;
        $log->debugf('Received check %s from Onfido', $check);

        unless ($check->{payload}{action} eq 'check.completed') {
            $log->warnf('Unexpected check action, ignoring: %s', $check->{payload}{action});
            return $self->render(text => 'ok');
        }

        my $obj = $check->{payload}{object};
        $log->debugf('Emitting client_verification event for %s (status %s)', $obj->{href}, $obj->{status},);
        BOM::Platform::Event::Emitter::emit(
            client_verification => {
                check_url => $obj->{href},
                status    => $obj->{status},
            });
        $self->render(text => 'ok');
    } catch ($e) {
        $log->errorf('Failed - %s', $e);
        $self->render(text => 'failed');
    }
}

=head2 validate_signature

Compares the C<X-Signature> header from a request with the HMAC-SHA1 expected
header based on our secret key.

Will throw an exception if this does not match, returns true if everything is
okay.

=over 4

=item C<Mojo::Message::Request> request object from onfido

=back

Returns 1 or 0

=cut

sub validate_signature {
    my ($self, $req) = @_;
    my $sig = $req->headers->header('X-Signature');
    # Mostly this happens when we manually check webhook from onfido end. in that case signatures are missing.
    unless ($sig) {
        $log->debugf('no signature header found');
        stats_inc("bom.platform", {tags => ['onfido.signature.header.notfound']});
        return 0;
    }
    my $config        = BOM::Config::third_party();
    my $webhook_token = $config->{onfido}->{webhook_token};
    $log->debugf('Signature is %s', $sig);
    my $expected = do {
        my $digest = Digest::HMAC->new(($webhook_token // die 'Onfido webhook token is not defined'), 'Digest::SHA1');
        $digest->add($req->body);
        $digest->hexdigest;
    };
    die 'Signature mismatch' unless lc($sig) eq lc($expected);
    return 1;
}

1;
