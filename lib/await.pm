package await;

use strict;
use warnings;

use JSON::XS qw| decode_json |;
use IO::Async::Loop;

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

    $t->tx->once(
        message => sub {
            my ($tx, $msg) = @_;
            return $tx unless $wait_for;
            my $data = decode_json($msg);

            return $tx unless ($wait_for && $data->{msg_type} eq $wait_for);
            $wait_for = '';
            $f->done($data) if !$f->is_ready;
        });

    my $id = $ioloop->watch_time(
        after => ($params->{timeout} || 2),
        code => sub {
            if ($messages_without_accidens == ($params->{wait_max} || 10)) {
                return $f->fail("timeout");
            }
            $f->cancel();
        },
    );
    $f->on_ready(sub { shift->loop->unwatch_time($id) });

    $action_sub->();

    $f = $ioloop->await($f);

    return wsapi_wait_for($t, $wait_for, sub { $t->message_ok }, $params, ++$messages_without_accidens)
        if $f->is_cancelled;

    return $f->get;
}

our $AUTOLOAD;

sub AUTOLOAD {
    my ($self, $params, $timeouts) = @_;

    return unless ref $self;
    my ($goal_msg) = ($AUTOLOAD =~ /::([^:]+)/);

    return wsapi_wait_for(
        $self,
        $goal_msg,
        sub {
            $self->send_ok({json => $params}) if $params;
            $self->message_ok();
        },
        $timeouts
    );
}

1;
