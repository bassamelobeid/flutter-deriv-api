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

=head2 check

Entrypoint for checks.

=cut

sub check {
    my ($self) = @_;
    try {
        my $req = $self->req;
        $self->validate_signature($req);

        my $check = $self->req->json;
        $log->debugf('Received check %s from Onfido', $check);

        unless($check->{payload}{action} eq 'check.completed') {
            $log->warnf('Unexpected check action, ignoring: %s', $check->{payload}{action});
            return $self->render(text => 'ok');
        }

       my $obj = $check->{payload}{object};
        $log->warnf('Emitting client_verification event for %s (status %s)',
            $obj->{href},
            $obj->{status},
        );
        BOM::Platform::Event::Emitter::emit(
            client_verification => {
                check_url => $obj->{href},
                status    => $obj->{status},
            }
        );
        $self->render(text => 'ok');
    } catch {
        $log->errorf('Failed - %s', $@);
        $self->render(text => 'failed');
    }
}

=head2 validate_signature

Compares the C<X-Signature> header from a request with the HMAC-SHA1 expected
header based on our secret key.

Will throw an exception if this does not match, returns true if everything is
okay.

=cut

sub validate_signature {
    my ($self, $req) = @_;
    my $sig = $req->headers->header('X-Signature') or die 'no signature header found';
    my $config = BOM::Config::third_party();
    my $webhook_token = $config->{onfido}->{webhook_token};
    $log->debugf('Signature is %s', $sig);
    my $expected = do {
        my $digest = Digest::HMAC->new(
            ($webhook_token // die 'Onfido webhook token is not defined'),
            'Digest::SHA1'
        );
        $digest->add($req->body);
        $digest->hexdigest;
    };
    die 'Signature mismatch' unless lc($sig) eq lc($expected);
    return 1;
}

1;
