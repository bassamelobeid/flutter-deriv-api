package await;

use strict;
use warnings;

use JSON::XS qw| decode_json |;
use IO::Async::Loop;
use Test::More;

=head2 <wsapi_wait_for>

my $data =  wsapi_wait_for( $t, 'proposal', sub{ send_request.... }, sub{ check_result.... (optional) }, {timeout => 4, wait_max => 100}});

Perform action and wait for the response ( you need to set message type for it ).
It's a blocking operation.
Working with Test::Mojo based tests

=cut

sub wsapi_wait_for {
    my ($t, $wait_for, $action_sub, $params, $messages_without_accidens) = @_;
    $params //= {};
    $messages_without_accidens //= 0;

    my $ioloop = IO::Async::Loop->new;

    my $f = $ioloop->new_future;

    my $id = $ioloop->watch_time(
        after => ($params->{timeout} || 2),
        code => sub {
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

sub AUTOLOAD {
    my ($self, $payload, $params) = @_;
    $params //= {};

    return unless ref $self;
    my ($goal_msg) = ($AUTOLOAD =~ /::([^:]+)/);

    my $req_id = exists($payload->{req_id}) ? {req_id => $payload->{req_id}} : {};

    return wsapi_wait_for(
        $self,
        $goal_msg,
        sub {
            $self->send_ok({json => $payload}) if $payload;
        },
        {%{$params}, %{$req_id}},
    );
}

sub get_data {
    my ($t, $params) = @_;
    $params //= {};

    while (1) {
        $t = $t->message_ok;
        my $msg  = $t->message->[1];
        my $data = decode_json($msg);

        return $data if !exists($params->{req_id}) or $data->{req_id} == $params->{req_id};
    }
}

1;
