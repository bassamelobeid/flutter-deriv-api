package await;

use strict;
use warnings;

use Encode;
use JSON::MaybeXS;
use IO::Async::Loop;
use Test::More;

use constant AWAIT_DEBUG => $ENV{BINARY_AWAIT_DEBUG};

=head2 <wsapi_wait_for>

my $data =  wsapi_wait_for( $t, 'proposal', sub{ send_request.... }, sub{ check_result.... (optional) }, {timeout => 4, wait_max => 100}});

Perform action and wait for the response ( you need to set message type for it ).
It's a blocking operation.
Working with Test::Mojo based tests

=cut

our $req_id = 999999;    # desparately trying to avoid conflicts

sub wsapi_wait_for {
    my ($t, $wait_for, $action_sub, $params, $messages_without_accidens) = @_;
    $params                    //= {};
    $messages_without_accidens //= 0;

    my $ioloop = IO::Async::Loop->new;

    my $f = $ioloop->new_future;

    my $id = $ioloop->watch_time(
        after => ($params->{timeout} || 2),
        code  => sub {
            if ($messages_without_accidens == ($params->{wait_max} || 10)) {
                ok(0, 'Timeout');
                return $f->fail("timeout");
            }
            $f->cancel();
        },
    );

    $f->on_ready(sub { shift->loop->unwatch_time($id) });

    $action_sub->();

    my $data = get_data($t, $params);

    if ($data->{msg_type} eq $wait_for or $data->{msg_type} eq 'error') {
        $f->done($data) if !$f->is_ready;
    } else {
        diag "Got >>" . ($data->{msg_type} // 'nothing') . "<< instead >>$wait_for<<";
        $f->cancel();
    }

    $f = $ioloop->await($f);
    return wsapi_wait_for($t, $wait_for, sub { note "Cancelled. Trying again" }, $params, ++$messages_without_accidens)
        if $f->is_cancelled;

    return $f->get;
}

our $AUTOLOAD;
our $used;

sub AUTOLOAD {
    my ($self, $payload, $params) = @_;

    note "non-matched messages are silently dropped. Please, set BINARY_AWAIT_DEBUG=1 to see all messages (including skipped ones) in the test"
        unless AWAIT_DEBUG or $used++;

    return unless ref $self;

    my $payload_copy = ref $payload eq 'HASH' ? {%{$payload}} : $payload;
    my $params_copy  = $params                ? {%{$params}}  : {};

    if (ref $payload_copy eq 'HASH') {
        $payload_copy->{req_id} //= ++$req_id;
        $params_copy->{req_id} = $payload_copy->{req_id};
    }

    my ($goal_msg) = ($AUTOLOAD =~ /::([^:]+)/);

    return wsapi_wait_for(
        $self,
        $goal_msg,
        sub {
            $self->send_ok({json => $payload_copy}) if $payload_copy;
        },
        $params_copy,
    );
}

sub get_data {
    my ($t, $params) = @_;
    $params //= {};

    while (1) {
        $t = $t->message_ok;
        unless ($t->message) {
            die "Socket was closed while waiting for response (timeout)";
        }
        my $msg  = $t->message->[1];
        my $data = JSON::MaybeXS->new->decode(Encode::decode_utf8($msg));

        return $data if not exists($params->{req_id}) or (exists($data->{req_id}) and $data->{req_id} == $params->{req_id});

        note "We're looking for this req_id: " . $params->{req_id} . ", skipping $msg" if AWAIT_DEBUG;
    }

    return undef;
}

1;
