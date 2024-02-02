use Object::Pad;

class BOM::Transport::RedisAPI;

use RedisDB;
use Data::UUID;
use BOM::Config;
use Syntax::Keyword::Try;
use JSON::MaybeUTF8 qw(encode_json_utf8 decode_json_utf8);
use Time::HiRes     qw(usleep);
use Log::Any        qw($log);
use Scalar::Util    qw(blessed);

use constant DEFAULT_TIMEOUT              => 10;                        #seconds
use constant WAIT_PERIOD                  => 1 * 1000;                  #useconds (1ms)
use constant DEFAULT_CATEGORY_NAME        => 'general';
use constant REQUIRED_RESPONSE_PARAMETERS => qw(message_id response);
use constant ERROR_CODES => {
    REDISDB      => 'REDISDB',
    TIMEOUT      => 'TIMEOUT',
    UNKNOWN      => 'UNKNOWN',
    MISSING_ARGS => 'MISSING_ARGS',
};

field $req_category;
field $redis;
field $req_counter;
field $wait_period;

=head2 new

Creates a new instance of the RedisAPI.
Example usage:
my $redis_api = BOM::Transport::RedisAPI->new(
    redis_config => {
        host => $config->{host},
        port => $config->{port},
        password => $config->{password}
    },
    req_category => 'general',
);
my $request = $redis_api->build_rpc_request('authorize', {'authorize' => '<token>'}, undef, 60);
my $response = $redis_api->call_rpc($request);
The constructor allow more options:

=over 4

=item * C<redis_config> - RedisDB connection info, if provided, the module will create a new RedisDB instance.

=item * C<req_category> - The category to use to send the request. default is 'general'.

=item * C<wait_period> - The amount of time to wait between each check for the response. default is 1ms.

=back

=cut 

BUILD {
    my %args = @_;
    if ($args{redis_config}) {
        try {
            $redis = RedisDB->new($args{redis_config}->%*);
        } catch ($e) {
            die {
                code    => ERROR_CODES->{REDISDB},
                type    => ref $e,
                message => "$e"
            };
        }
    } else {
        die {
            code    => ERROR_CODES->{MISSING_ARGS},
            message => "No redis connection info provided. please provide a 'redis_config' parameter"
        };
    }
    $req_category = $args{req_category} // DEFAULT_CATEGORY_NAME;
    $wait_period  = $args{wait_period} || WAIT_PERIOD;
    $req_counter  = 0;
}

=head2 call_rpc

Sends the request to the server and wait for the response. this method will subscribe to who channel from request_data and wait for the response.
It'll also unsubscribe (reset the connection) from the channel after the response is received. or in case of failure. to allow the connection to be reused.

The request and the subscription commands will be sent in one transaction using MULTI/EXEC redis commands.
The module will send additional subscribe command to let RedisDb enter the subscription mode.

=over 4

=item $request_data - The request data, this should be a hashref. use the build_rpc_request method to create the request data.

=back 

=cut

method call_rpc ($request_data) {
    try {
        $self->send_request($request_data);
        $self->subscribe($request_data->{who});
        return $self->wait_for_reply($request_data);
    } catch ($e) {
        $self->throw_exception($e, $request_data);
    } finally {
        # We are done with the connection all the way.
        # RedisDB unsubscribe will reset the connection anyway. but it'll keep the replies causing inconsistency in the connection.
        # Instead of unsubscribe we call reset connection right away.
        $self->reset_connection;
    }
}

=head2 subscribe

Subscribes to the channel from request data.

=over 4

=item $channel - The request data.

=back

=cut

method subscribe ($channel) {
    $redis->subscribe($channel);
}

=head2 reset_connection

Resets the redisdb connection.

=cut

method reset_connection () {
    $redis->reset_connection;
}

=head2 next_req_id

Returns the next request id.

=cut

method next_req_id () {
    $req_counter++;
    return $req_counter;
}

=head2 build_rpc_request

Creates the request data.

=over 4

=item $method - The rpc method name.

=item $params - The rpc method params.

=item $stash_params - The rpc method stash params.

=item $req_timeout - The request timeout in seconds.

=back

=cut

method build_rpc_request ($method, $params, $stash_params = undef, $req_timeout = undef) {
    my $request_data = {
        rpc        => $method,
        who        => Data::UUID->new->create_str,
        deadline   => $req_timeout ? time + $req_timeout : $self->default_end_time,
        message_id => $self->next_req_id,
        $params       ? (args  => encode_json_utf8({args => $params})) : (),
        $stash_params ? (stash => encode_json_utf8($stash_params))     : (),
    };
    return $request_data;
}

=head2 wait_for_reply

Waits for the response. Will periodically for reply of a the passed request data.
The request should be already sent. and the module should be in subscription mode (i.e subscribe called).
Will wait (sleep) for the response until the deadline is reached. or the default timeout is reached.
In case of timeout, the method will die with an error message.

=over 4

=item $request_data - The request data.

=back

=cut

method wait_for_reply ($request_data) {
    my $end_time = $request_data->{deadline} // $self->default_end_time;
    while (time < $end_time) {
        if ($redis->reply_ready) {
            my $reply = $redis->get_reply;
            if ($reply->[0] eq 'message') {
                my $response = $self->process_message($request_data, $reply->[2]);
                if ($response) {
                    return $response;
                }
            }
        }

        Time::HiRes::usleep($wait_period);
    }

    die {
        code    => ERROR_CODES->{TIMEOUT},
        message => sprintf("Timeout waiting the reply of the rpc: %s", $request_data->{rpc})};
}

=head2 default_end_time

Returns the default timeout/deadline of the request.

=cut

method default_end_time () {
    return time + DEFAULT_TIMEOUT;
}

=head2 send_request

Sends the request to the server and subscribe to response channel in a single transaction.

=over 4

=item $request_data - The request data.

=back

=cut

method send_request ($request_data) {
    $redis->send_command('MULTI', \&callback);
    $self->execute_request($request_data);
    $redis->send_command('subscribe', $request_data->{who}, \&callback);
    $redis->send_command('EXEC', \&callback);
}

=head2 execute_request

Puts the request on the redis stream(category). 

=over 4

=item $request_data - The request data.

=back

=cut

method execute_request ($request_data) {
    $redis->send_command('XADD' => ($req_category, qw(MAXLEN ~ 100000), '*', $request_data->%*, \&callback));
}

=head2 process_message

Handles the messages received from channel. returns undef if the message is not the response of the passed request.

=over 4

=item $request_data - The request data.

=item $raw_message - string - The response from channel.

=back

=cut

method process_message ($request_data, $raw_message) {
    my $message_data;
    try {
        $message_data = decode_json_utf8($raw_message);
    } catch ($e) {
        $log->errorf("Failed to decode message: %s while waiting for response of %s", $e, $request_data->{rpc});
        return undef;
    }

    my (@missing_params) = grep { !exists $message_data->{$_} } REQUIRED_RESPONSE_PARAMETERS;
    if (@missing_params) {
        $log->errorf(
            "Failed to process response: '%s' are missing while waiting for response of %s",
            join(",", @missing_params),
            $request_data->{rpc});
        return undef;
    }

    if ($message_data->{message_id} ne $request_data->{message_id}) {
        $log->infof(
            "Received response with message_id: %s, expected message_id: %s while waiting for response of rpc: %s ",
            $message_data->{message_id},
            $request_data->{message_id},
            $request_data->{rpc});
        return undef;
    }

    return $message_data;
}

=head2 throw_exception

Throws an exception (die) based on the error. The exception will contain an error code of ERROR_CODES and message.
Three types of exceptions RedisDB exceptions, expected exceptions(module exceptions) and unknown exceptions. 

=cut

method throw_exception ($e, $request_data) {

    if (ref $e eq 'HASH' && $e->{code}) {
        if (exists ERROR_CODES->{$e->{code}}) {
            die $e;
        }
    }

    if (blessed($e) && $e->isa('RedisDB::Error')) {
        die {
            code    => ERROR_CODES->{REDISDB},
            type    => ref $e,
            message => sprintf("$e while calling rpc: %s", $request_data->{rpc})};
    }

    die {
        code    => ERROR_CODES->{UNKNOWN},
        message => sprintf("Unknown error: %s while calling rpc: %s", $e, $request_data->{rpc})};
}

=head2 callback

The default handler for redis commands. to be used as callback for send_command method
Checks wether the reply is an error, and die if so.

=over 4

=item $redisdb - The redisdb instance.

=item $reply - The reply from redisdb.

=back

=cut 

sub callback {
    my ($redisdb, $reply) = @_;
    if (blessed $reply && $reply->isa('RedisDB::Error')) {
        die $reply;
    }
}

1;
