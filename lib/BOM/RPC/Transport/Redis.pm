package BOM::RPC::Transport::Redis;

use strict;
use warnings;

=head1 NAME

BOM::RPC::Transport::Redis

The consumer part of RPC handler over synchronized queue

=head1 DESCRIPTION

Initialize worker to start reading Redis stream depending on the
specified category, start the process of reading requests 
which coming as messages over the stream, dispatch RPC
requests, collect some statistics and return the
result to the channel specified by Producer.

=head1 METHODS

=cut

use JSON::MaybeUTF8 qw( encode_json_utf8 decode_json_utf8 );
use List::Util qw( pairmap );
use Carp qw( croak );
use Syntax::Keyword::Try;

use Algorithm::Backoff;
use DataDog::DogStatsd::Helper qw( stats_timing stats_inc );
use Log::Any qw( $log );
use Net::Domain qw( hostname );
use Path::Tiny;
use RedisDB;
use Time::HiRes qw( sleep );
use Time::Moment;

use BOM::Platform::Context qw( localize );
use BOM::RPC ();
use BOM::RPC::Registry;

use constant CONSUMER_GROUP        => 'processors';
use constant READ_BLOCK_TIME       => 2500;
use constant SHIFT_INTERVAL        => 300;
use constant BACKOFF_INITIAL_DELAY => 0.3;
use constant BACKOFF_MAX_DELAY     => 10;
use constant DEFAULT_ERROR_CODE    => 'WrongResponse';

use constant ERROR_MESSAGE_MAPPING => {
    RequestTimeout      => 'Request timed out',
    InternalServerError => 'Sorry, an error occurred while processing your request.',
    WrongResponse       => 'Sorry, an error occurred while processing your request.',
};

use constant REQUIRED_MESSAGE_PARAMETERS => ('who', 'rpc');

# wrap RPC methods into a hash
my %services = map {
    my $method = $_->name;
    $method => {
        rpc_sub => BOM::RPC::wrap_rpc_sub($_),
        }
} BOM::RPC::Registry::get_service_defs();

=head2 new

Creates object instance of the class

=over 4

=item * C<redis_uri> - Redis connection string. will be ignored if 'redis' argument passed

=item * C<redis> - a L<RedisDB> object

=item * C<worker_index> - The worker index is always between 0 to number of workers -1

=item * C<pid> - Optional, The child process id, default is current process's id 

=item * C<category> - Optional, the category of requests which it should consume over the Redis stream, default is 'general'

=item * C<host> - Optional, the host name, default is machine name

=back

return blessed object

=cut

sub new {
    my ($class, %args) = @_;

    croak 'Neither redis nor redis_uri is defined' unless $args{redis_uri} || $args{redis};
    croak 'worker_index is required' unless defined $args{worker_index};

    $args{request_counter} = 0;
    $args{pid} ||= $$;

    return bless \%args, $class;
}

=head2 backoff

Returns L<Algorithm::Backoff> instance if exists otherwise creates one

=cut

sub backoff {
    my $self = shift;

    return $self->{backoff} //= Algorithm::Backoff->new(
        min => BACKOFF_INITIAL_DELAY,
        max => BACKOFF_MAX_DELAY
    );
}

=head2 redis

Returns L<RedisDB> instance if exists otherwise creates one using given uri

=cut

sub redis {
    my $self = shift;

    return $self->{redis} //= RedisDB->new(
        url         => $self->{redis_uri},
        raise_error => 0,                    # returns errors as object
    );
}

=head2 stream_name

Returns stream/category name if defined otherwise returns B<general> by default

=cut

sub stream_name {
    my $self = shift;

    return $self->{category} //= 'general';
}

=head2 host_name

Returns host name if defined otherwise returns machine's name 
by default using L<Net::Domain>'s B<hostname> sub

=cut

sub host_name {
    my $self = shift;

    return $self->{host} //= hostname;
}

=head2 consumer_name

Returns consumer name if defined otherwise returns combination:

    $host_name-$worker_index

=cut

sub consumer_name {
    my $self = shift;

    return $self->{consumer_name} //= join '-', $self->host_name, $self->{worker_index};
}

=head2 connection_name

Returns connection name if defined otherwise returns combination:

    $stream_name-$host_name-$pid

=cut

sub connection_name {
    my $self = shift;

    return $self->{connection_name} //= join '-', $self->stream_name, $self->host_name, $self->{pid};
}

=head2 start

Start consuming of Redis stream messages which belong to defined category,
handle pending messages at first then waiting for the new messages.

Returns undef

=cut

sub run {
    my $self = shift;

    $self->{is_running} = 1;

    local $SIG{TERM} = local $SIG{INT} = sub {
        local $SIG{ALRM} = sub {
            $log->errorf("Tooks too long to shutting down, exited forcibly.\n");
            exit 1;
        };
        alarm 4;

        $self->stop;
    };

    $self->initialize_connection;

    $self->_resolve_pending_messages;
    $self->_setup_stream_reader;

    return undef;
}

=head2 stop

Setting stop flag for graceful shutdown.

Returns undef

=cut

sub stop {
    my $self = shift;

    $self->{is_running} = 0;

    return undef;
}

=head2 initialize_connection

Initializing connection by:

=over 2

=item * Assigning Redis client name

=item * Trying to create consumer group

=back

Returns undef

=cut

sub initialize_connection {
    my $self = shift;

    try {
        $self->_exec_redis_command(CLIENT => (SETNAME => $self->connection_name));

        $self->_exec_redis_command(
            XGROUP => (
                CREATE => $self->stream_name,
                CONSUMER_GROUP, '$', 'MKSTREAM'
            ));
    }
    catch {
        my $err = $@;

        if ($self->_is_redis_exception($err)) {
            if ($err->{redis}->{message} =~ qr/Consumer Group name already exists/) {
                # Consumer group exists error will always occurred after first init
                # so since we may use more than 1 worker, we have to ignore it.
                return undef;
            }

            $log->errorf('Failed while initializing Redis connection: %s', $err->{redis}->{message});
        } else {
            $log->errorf('An error occurred while initializing connection: %s', $err);
        }

        die "InternalServerError\n";
    }

    return undef;
}

=head2 _setup_stream_reader

Setup a stream reader and waiting for a random time and 
then re-setup again (until B<is_running> is true), to 
getting new messages which streamed from Producer.

Here, we use L<Algorithm::Backoff> to keep trying reconnect
to the Redis in case of occurring any kind of exceptions

=cut

sub _setup_stream_reader {
    my ($self) = @_;

    while ($self->{is_running}) {
        try {
            # We generate random timeout to prevent attempts at the same time
            # also fixed base READ_BLOCK_TIME for preventing Redis DDoS
            my $timeout = READ_BLOCK_TIME + int(rand(SHIFT_INTERVAL));

            my $message = $self->_exec_redis_command(
                XREADGROUP => (
                    BLOCK => $timeout,
                    COUNT => 1,
                    GROUP => CONSUMER_GROUP,
                    $self->consumer_name,
                    STREAMS => $self->stream_name,
                    '>'    # > is Redis special ID which retrieve last id of group's messages
                ));

            next unless $message;

            $self->_process_message($message);
            $self->backoff->reset_value;
        }
        catch {
            my $err = $@;

            if ($self->_is_redis_exception($err)) {
                $log->errorf('Failed while reading from Redis stream consumer group: %s', $err->{redis}->{message});
            } else {
                $log->errorf('An exception occurred while processing RPC request: %s', $err);
            }

            last if $self->backoff->limit_reached;
            sleep $self->backoff->next_value;
        }

    }

    exit 0;
}

=head2 _resolve_pending_messages

Acknowledge all pending message unconditionally.

- Since we have no idea about safety of messages reprocessing,
every time new worker started, we try to mark all pending
messages which have same consumer name as acknowledged.

- In future phases we will support retrying mechanism for all 
one-way request which expect no response from server-side.

Returns undef

=cut

sub _resolve_pending_messages {
    my $self = shift;

    try {
        my $result = $self->_exec_redis_command(XPENDING => ($self->stream_name, CONSUMER_GROUP, '-', '+', '1000', $self->consumer_name));

        for ($result->@*) {
            $self->_ack_message($_->[0]);
        }
    }
    catch {
        my $err = $@;

        $log->errorf('Failed while resolving pending messages in (%s) stream: %s',
            $self->stream_name, $self->_is_redis_exception($err) ? $err->{redis}->{message} : $err);
    }

    return undef;
}

=head2 _process_message

Handle received message over stream, check processing 
feasibility, parse message and dispatch request.

=over 4

=item * C<$raw_msg> - The original message (an arrayref) which received from Redis

=back

Returns undef

=cut

sub _process_message {
    my ($self, $raw_msg) = @_;

    my ($msg_id, $params, $result);

    try {
        my $parsed = $self->_parse_message($raw_msg);

        $msg_id = $parsed->{message_id};
        $params = $parsed->{payload};

        if ($params->{deadline} && $params->{deadline} <= time) {
            $self->_ack_message($msg_id);

            DataDog::DogStatsd::Helper::stats_inc('bom_rpc.v_3.call.hit_deadline', {tags => [sprintf("rpc:%s", $params->{rpc})]});

            return undef;
        }

        $result = $self->_dispatch_request($params);
    }
    catch {
        my $err = $@;
        chomp($err);

        my $err_code = ERROR_MESSAGE_MAPPING->{$err} ? $err : DEFAULT_ERROR_CODE;
        $result = {
            error => {
                code              => $err_code,
                message_to_client => localize ERROR_MESSAGE_MAPPING->{$err_code},
            }};
    }

    $params->{response} = {result => $result};
    $self->_publish_response($params->{who}, encode_json_utf8($params));
    $self->_ack_message($msg_id);

    return undef;
}

=head2 _dispatch_request

Validate JSON-type arguments, trying to dispatch request
and collecting statistics about usage of resources.

=over 4

=item * C<$params> - hashref of arguments associated with RPC call passed from producer

=back

Returns a hashref containing RPC response

=cut

sub _dispatch_request {
    my ($self, $params) = @_;

    my $result;

    # PRE-DISPATCH
    $0 = sprintf("bom-rpc: %s", $params->{rpc});    ## no critic (RequireLocalizedPunctuationVars)

    my $request_start = [Time::HiRes::gettimeofday];
    my $vsz_start     = _current_virtual_mem_size();

    DataDog::DogStatsd::Helper::stats_inc('bom_rpc.v_3.call.count', {tags => [sprintf("rpc:%s", $params->{rpc})]});

    # DISPATCH
    try {
        $result = $services{$params->{rpc}}{rpc_sub}->($params->{args});
    }
    catch {
        $log->errorf("An error occurred while RPC requesting for '%s', ERROR: %s", $params->{rpc}, $@);
        DataDog::DogStatsd::Helper::stats_inc('bom_rpc.v_3.call_failure.count', {tags => [sprintf("rpc:%s", $params->{rpc})]});

        die "InternalServerError\n";
    }

    # POST-DISPATCH
    BOM::Database::Rose::DB->db_cache->finish_request_cycle;
    $self->{request_counter}++;

    my @recent;
    my $request_end     = [Time::HiRes::gettimeofday];
    my $last_request_at = Time::Moment->now_utc->strftime("%Y-%m-%d %H:%M:%S%3f");

    # Track whether we have any change in memory usage
    my $vsz_increase = _current_virtual_mem_size() - $vsz_start;
    # Anything more than 100 MB is probably something we should know about,
    # residence_list and ticks can take >64MB so we can't have this limit set
    # too low.
    $log->warnf("Large VSZ increase for %d - %d bytes, %s\n", $$, $vsz_increase, $params->{rpc})
        if $vsz_increase > (100 * 1024 * 1024);

    # We use timing for the extra statistics (min/max/avg) it provides
    DataDog::DogStatsd::Helper::stats_timing(
        'bom_rpc.v_3.call.timing',
        (1000 * Time::HiRes::tv_interval($request_start)),
        {tags => [sprintf("rpc:%s", $params->{rpc})]});

    push @recent, [$request_start, Time::HiRes::tv_interval($request_end, $request_start)];
    shift @recent if @recent > 50;

    my $usage = 0;
    $usage += $_->[1] for @recent;
    $usage = sprintf('%.2f', 100 * $usage / Time::HiRes::tv_interval($request_end, $recent[0]->[0]));

    $0 = sprintf(    ## no critic (RequireLocalizedPunctuationVars)
        "bom-rpc: %s category (idle since %s #req=%s us=%s%%)",
        $self->stream_name, $last_request_at, $self->{request_counter}, $usage
    );

    return $result;
}

=head2 _parse_message

Validates the original message and parses it to the expected 
items also converts arguments to hash for fixed accessing.

The example of original message:

    [
        [
            'general', # stream name
            [
                [
                    '123123123-0',                  # message_id
                    [                               # payload
                        'who'       => 'd11221d',
                        'rpc'       => 'ping',
                        'args'      => '{json}',
                        'deadline'  => '999',
                        'stash'     => '{json}'
                    ]
                ]
            ]
        ]
    ]

=over 4

=item * C<$msg> - The original message

=back

Returns hashref.

=cut

sub _parse_message {
    my ($self, $msg) = @_;

    my $pith = $msg->[0][1][0];    # Peel the message to reaching pith

    my $message_id = $pith->[0];
    my %params     = $pith->[1]->@*;

    for my $key (REQUIRED_MESSAGE_PARAMETERS) {
        if (!exists $params{$key}) {
            $log->errorf("Failed while parsing message: The required parameter (%s) doesn't exist in the message (%s).", $key, $message_id);

            die "InternalServerError\n";
        }
    }

    my $decoded_args;
    my $decoded_stash;

    try {
        $decoded_args  = decode_json_utf8($params{args})  if $params{args};
        $decoded_stash = decode_json_utf8($params{stash}) if $params{stash};
    }
    catch {
        my $troubled_param = 'unknown';
        if ($params{args} && !$decoded_args) {
            $troubled_param = 'args';
        } elsif ($params{stash} && !$decoded_stash) {
            $troubled_param = 'stash';
        }

        # remove sensitive data before log if was in production
        if (!$log->is_debug && $troubled_param ne 'unknown') {
            my $sensitive_keys_pattern = join "|", ('loginid', 'client_loginid');
            my $troubled_value = $params{$troubled_param};
            $troubled_value =~ s/(?:"($sensitive_keys_pattern)")(?:\s*?:\s*?)(?:"([a-zA-Z0-9\s]*)")/"$1":"HIDDEN"/gm;
            $params{$troubled_param} = $troubled_value;
        }

        $log->errorf("A decoding exception occurred on JSON value of '%s', PARAMS: %s", $troubled_param, \%params);
        DataDog::DogStatsd::Helper::stats_inc('bom_rpc.v_3.call.encoding_failure', {tags => [sprintf("rpc:%s", $params{rpc})]});

        die "InternalServerError\n";
    }

    $params{args}  = $decoded_args  if defined $decoded_args;
    $params{stash} = $decoded_stash if defined $decoded_stash;

    return {
        message_id => $message_id,
        payload    => \%params,
    };
}

=head2 _ack_message

Mark message as acknowledged by consumer group

=over 4

=item * C<$id> - The message id

=back

Returns undef

=cut

sub _ack_message {
    my ($self, $id) = @_;

    try {
        $self->_exec_redis_command(XACK => ($self->stream_name, CONSUMER_GROUP, $id));
    }
    catch {
        my $err = $@;

        $log->errorf('Failed while marking message (%s) as acknowledged: %s', $id,
            $self->_is_redis_exception($err) ? $err->{redis}->{message} : $err);
    }

    return undef;
}

=head2 _publish_response

Publish response to channel that Producer subscribed

=over 4

=item * C<$channel> - The redis channel id which producer subscribed for

=item * C<$message> - The encoded message as JSON string

=back

Returns undef

=cut

sub _publish_response {
    my ($self, $channel, $message) = @_;

    try {
        $self->_exec_redis_command(PUBLISH => ($channel, $message))
    }
    catch {
        my $err = $@;

        $log->errorf('Failed while publishing a message to channel (%s): %s',
            $channel, $self->_is_redis_exception($err) ? $err->{redis}->{message} : $err);
    }

    return undef;
}

=head2 _exec_redis_command

Execute the Redis command with exception handling

Note: always call this subroutine within B<Try/Catch> block and check 
(B<$@> is a hash and key {redis} exists within) for any exception

=over 4

=item * C<commands> - An array of commands to be executed

=back

Returns scalar or arrayref

=cut

sub _exec_redis_command {
    my ($self, @commands) = @_;

    my $result = $self->redis->execute(@commands);

    die +{redis => $result} if (ref $result) =~ qr/RedisDB::Error/;

    return $result;
}

=head2 _current_virtual_mem_size

Returns the VSZ (virtual memory usage) for the current process, in bytes.

=cut

sub _current_virtual_mem_size {
    my $stat = path("/proc/self/stat")->slurp_utf8;
    # Process name is awkward and can contain (). We know that we're a running process.
    $stat =~ s/^.*\) R [0-9]+ //;

    return +(split " ", $stat)[18];
}

=head2 _is_redis_exception

Check exception is related to Redis communication or not

=over 4

=item * C<$err> - The original exception

=back

Returns scalar 0 or 1

=cut

sub _is_redis_exception {
    my ($self, $err) = @_;

    return (ref $err eq ref {}) && exists $err->{redis};
}

1;
