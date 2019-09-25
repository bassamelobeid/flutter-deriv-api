package BOM::RPC::Feed::Reader;

use strict;
use warnings;

use parent qw(IO::Async::Notifier);

=head1 NAME

BOM::RPC::Feed::Reader - service for providing binary feed data

=head1 DESCRIPTION

=cut

no indirect;

use curry;
use IO::Async::Stream;
use Future::AsyncAwait;
use Log::Any qw($log);
use JSON::MaybeUTF8 qw(:v1);
use Syntax::Keyword::Try;
use DataDog::DogStatsd::Helper qw(stats_inc stats_timing stats_gauge stats_event);

use BOM::RPC::Feed::Sendfile;

# Anything larger than this indicates a protocol error, since
# our requests are expected to be tiny
use constant MAX_INCOMING_MESSAGE_SIZE => 16384;

=head2 on_stream

Called when we have an L<IO::Async::Stream> instance that
we can listen for requests on.

Takes a single parameter:

=over 4

=item * C<$stream> - the L<IO::Async::Stream> instance

=back

Resolves when processing is done for this stream.

=cut

async sub on_stream {
    my ($self, $stream, $connection_time) = @_;
    my $client_info = join ':', map { $stream->read_handle->$_ } qw(peerhost peerport);

    $log->debugf('Reading data from client %s', $client_info);
    my $request_symbol;
    try {
        while (my $count = unpack N1 => await $stream->read_exactly(4)) {
            $log->tracef('Expecting %d byte message from %s', $count, $client_info);
            die 'Excessively-large message, refusing to process' if $count > MAX_INCOMING_MESSAGE_SIZE;
            my $msg    = await $stream->read_exactly($count);
            my $params = decode_json_utf8($msg);
            $log->debugf('Have %d byte message from %s: %s', $count, $client_info, $msg);
            $request_symbol = $params->{underlying};
            await $self->sendfile->stream_tick_range(
                %$params,
                stream => $stream,
            );
        }
    }
    catch {
        $log->errorf('Exception while handling stream requests from %s: %s', $client_info, $@);
        stats_event('Exception while handling stream requests', "from $client_info | $@", {alert_type => 'error'});
        stats_inc('local_feed.reader.request_exception');
    }

    $log->debugf('Closing client %s', $client_info);
    stats_timing(
        'local_feed.reader.request_serve_time',
        int($connection_time->delta_milliseconds(Time::Moment->now)),
        {tags => ['symbol:' . $request_symbol]});
    try {
        # There should be no possibility of pending outgoing data here,
        # and if we did have invalid/incomplete data then it's important
        # not to allow anything further to reach the outgoing stream,
        # since the receiver may try it as valid tick data...
        $stream->close_now;
    }
    catch {
        $log->errorf('Failed to close stream from %s: %s', $client_info, $@);
        stats_event('Failed to close stream', "from $client_info | $@", {alert_type => 'error'});
    }
    return;
}

=head2 on_accept

Accepts incoming requests from clients.

Will be called with a single parameter:

=over 4

=item * C<$sock> - the L<IO::Socket::IP> instance

=back

Returns nothing of interest.

=cut

sub on_accept {
    my ($self, $sock) = @_;
    $log->debugf("New client from %s", join(':', $sock->peerhost, $sock->peerport));
    my $connection_time = Time::Moment->now;
    stats_inc('local_feed.reader.new_connection', {tags => ['port:' . $sock->peerport]});
    $self->add_child(
        my $stream = IO::Async::Stream->new(
            handle  => $sock,
            on_read => sub { }));
    $self->on_stream($stream, $connection_time)->retain;
}

=head2 listener

Sets up the TCP listener.

=cut

async sub listener {
    my ($self) = @_;
    return await $self->{listener} //= $self->loop->listen(
        addr => {
            family   => "inet",
            socktype => "stream",
            port     => $self->port,
        },
        on_accept => $self->curry::weak::on_accept,
    );
}

=head1 METHODS - Accessors

=cut

sub port      { shift->{port} }
sub base_path { shift->{base_path} }
sub sendfile  { shift->{sendfile} }

sub configure {
    my ($self, %args) = @_;
    for (qw(port base_path)) {
        $self->{$_} = delete $args{$_} if exists $args{$_};
    }
    return $self->next::method(%args);
}

sub _add_to_loop {
    my ($self) = @_;

    $self->add_child(
        $self->{sendfile} = BOM::RPC::Feed::Sendfile->new(
            base_path => $self->base_path,
        ));
    $self->listener->retain;
}

1;
