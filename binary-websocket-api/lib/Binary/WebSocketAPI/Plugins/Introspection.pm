package Binary::WebSocketAPI::Plugins::Introspection;

use strict;
use warnings;

use parent qw(Mojolicious::Plugin);

no indirect;

use curry::weak;
use Encode;
use Mojo::IOLoop;
use Future;
use Future::Mojo;
use Syntax::Keyword::Try;
use POSIX qw(strftime);

use JSON::MaybeXS;
use JSON::MaybeUTF8       qw(encode_json_utf8);
use Scalar::Util          qw(blessed looks_like_number);
use Variable::Disposition qw(retain_future);
use Socket                qw(:crlf);
use Proc::ProcessTable;
use feature 'state';
use Log::Any qw($log);
use DataDog::DogStatsd::Helper;

use Binary::WebSocketAPI::v3::Instance::Redis qw(ws_redis_master);

# How many seconds to allow per command - anything that takes more than a few milliseconds
# is probably a bad idea, please do not rely on this for any meaningful protection
use constant MAX_REQUEST_SECONDS => 5;

use constant INTROSPECTION_CHANNEL => 'introspection';

use constant EXPIRY_HELP_STRING => <<'END_HELP';
The 'timeout_extension' data should be a JSON string with the following format:
[
  {
    "category": "string",           // A string pattern, regex to match for category, ("" == .*)
    "rpc": "string",                // A string pattern, regex to match for rpc name, ("" == .*)
    "offset": <number>,             // A number between 0 and 60, inclusive, indicating the offset.
    "percentage": <integer>         // An integer between 0 and 100, inclusive, indicating the percentage.
  },
    // More entries can follow with the same structure.
]
Note: Ensure that all integer values are actual numbers (not strings), and strings should be enclosed in quotes.
END_HELP

my $json = JSON::MaybeXS->new;

our $INTROSPECTION_REDIS;

=head2 start_server

Tries to start the introspection endpoint. May fail on hot restart, since the port will be
taken by something else and we have no SO_REUSEPORT on our current kernel.

=cut

sub start_server {
    my ($self, $app) = @_;
    $INTROSPECTION_REDIS = Binary::WebSocketAPI::v3::Instance::Redis::create('ws_redis_master');
    $INTROSPECTION_REDIS->on(
        message => $app->$curry::weak(
            sub {
                my ($app, $redis, $msg, $channel) = @_;
                return unless $channel eq INTROSPECTION_CHANNEL;
                my $request        = $json->decode(Encode::decode_utf8($msg));
                my $command        = $request->{command};
                my $return_channel = $request->{channel};
                my $id             = $request->{id};
                my @args           = @{$request->{args} || []};
                retain_future(
                    $self->handle_command($app, $command => @args)->transform(
                        done => sub {
                            my ($resp) = @_;
                            $resp->{id} = $id;
                            $redis->publish(
                                $return_channel => Encode::encode_utf8($json->encode($resp)),
                                # We'd like this to be nonblocking
                                sub {
                                    my ($redis, $err) = @_;
                                    $log->errorf('Publish failure response - %s', $err) if $err;
                                });
                        },
                        fail => sub {
                            my ($resp) = @_;
                            $resp->{id} = $id;
                            $redis->publish(
                                $return_channel => Encode::encode_utf8($json->encode($resp)),
                                # We'd like this to be nonblocking
                                sub {
                                    my ($redis, $err) = @_;
                                    $log->errorf('Publish failure response - %s', $err) if $err;
                                });
                        }));
            }));
    $INTROSPECTION_REDIS->subscribe(
        [INTROSPECTION_CHANNEL],
        sub {
            my ($redis, $err) = @_;
            return unless $err;
            $log->errorf('Failed to subscribe to introspection endpoint: %s', $err);
        });
    $log->debug('Introspection listening on: ' . INTROSPECTION_CHANNEL);
    return;
}

sub handle_command {
    my ($self, $app, $command, @args) = @_;
    my $write_to_log = 0;
    if ($command eq 'log') {
        $write_to_log = 1;
        $command      = shift @args;
    }

    unless (is_valid_command($command)) {
        $log->errorf('Invalid command: %s %s', $command, \@args);
        return Future->fail(
            sprintf("Invalid command [%s]", $command),
            invalid_command => $command,
            @args
        );
    }

    my $rslt = undef;
    try {
        $rslt = $self->$command($app, @args);
    } catch ($e) {
        $rslt = Future->fail(
            $e,
            introspection => $command,
            @args
        );
    }
    # Allow deferred results
    $rslt = Future->done($rslt) unless blessed($rslt) && $rslt->isa('Future');
    return Future->wait_any($rslt, Future::Mojo->new_timer(MAX_REQUEST_SECONDS)->then(sub { Future->fail('Timeout') }),)->on_done(
        sub {
            my ($resp) = @_;
            $log->debugf('%s (%s) - %s', $command, \@args, $resp) if $write_to_log;
        }
    )->else(
        sub {
            my ($exception, $category, @details) = @_;
            my $rslt = {
                error    => $exception,
                category => $category,
                details  => \@details
            };
            $log->errorf('%s (%s) failed - %s', $command, \@args, $exception);
            return Future->fail($rslt, $category, @details);
        });
}

=head2 register

Registers the plugin by creating an introspection TCP server endpoint.

This will keep on trying every 2 seconds for 100 retries: this is because
we don't have a reliable way to reuse the port, and listening on a random
port would not be as convenient.

=cut

sub register {
    my ($self, $app) = @_;

    my $retries = 100;
    my $code;
    $code = sub {
        Mojo::IOLoop->timer(
            2 => sub {
                try {
                    $self->start_server($app);
                    undef $code;
                } catch ($e) {
                    return unless $code;
                    return $code->() if $retries--;
                    $log->errorf('Unable to start introspection server after 100 retries - ', $e);
                    undef $code;
                }
            });
    };
    $code->();
    return;
}

# All registered commands - each hash slot should contain a true value, the
# command itself is a method on this class.
our %COMMANDS;

=head2 command

Registers the given command. Expects a command name, coderef, and any specific
parameters to pass to the coderef.

=cut

sub command {
    my ($name, $code, %args) = @_;
    {
        die "Already registered $name"                if exists $COMMANDS{$name};
        die "Not registered but already ->can($name)" if __PACKAGE__->can($name);
        $COMMANDS{$name} = 1;
        my $code = sub {
            my $self = shift;
            return $self->$code(%args, @_);
        };
        {
            no strict 'refs';
            *$name = $code;
        }
    }
    return;
}

=head2 is_valid_command

Returns true if we have registered this command. Used as an extra protection
against commands like 'DESTROY' or 'BEGIN'.

=cut

sub is_valid_command { return exists $COMMANDS{shift()} }

=head1 COMMANDS

=cut

=head2 connections

Returns a list of active connections.

For each connection, we have the following information:

=over 4

=item * IP

=item * Country

=item * Language

=item * App ID

=item * Landing company

=item * Client ID

=back

We also want to add this information, but it's not yet available:

=over 4

=item * Last request

=item * Last message sent

=item * Requests received

=item * Messages sent

=item * Idle time

=item * Session time

=item * Active subscriptions

=back

=cut

command connections => sub {
    my ($self, $app) = @_;

    my @active_connections = values %{$app->active_connections};
    my @connections        = map {
        my $pc = 0;
        my $ch = 0;

        my $stats = Binary::WebSocketAPI::v3::Subscription->introspect($_);
        for my $class (keys %$stats) {
            $pc += $stats->{$class}{subscription_count};
            $ch += $stats->{$class}{channel_count};
        }

        my $connection_info = {
            app_id                         => $_->stash->{source},
            landing_company                => $_->landing_company_name,
            ip                             => $_->stash->{client_ip},
            country                        => $_->country_code,
            client                         => $_->stash->{loginid},
            pricing_channel_count          => $ch,
            last_call_received_from_client => $_->stash->{introspection}{last_call_received},
            last_message_sent_to_client    => $_->stash->{introspection}{last_message_sent},
            received_bytes_from_client     => $_->stash->{introspection}{received_bytes},
            sent_bytes_to_client           => $_->stash->{introspection}{sent_bytes},
            messages_received_from_client  => $_->stash->{introspection}{msg_type}{received},
            messages_sent_to_client        => $_->stash->{introspection}{msg_type}{sent},
            last_rpc_error                 => $_->stash->{introspection}{last_rpc_error},
            pricer_subscription_count      => $pc,
        };
        $connection_info;
        }
        grep { defined }
        sort @active_connections;

    my $result = {
        connections => \@connections,
        # Report any invalid (disconnected but not cleaned up) entries
        invalid => 0 + (grep { !defined } @active_connections),
    };
    return Future->done($result);
};

=head2 subscriptions

Returns a list of all subscribed Redis channels. Placeholder, not yet implemented.

=cut

command subscriptions => sub {
    Future->fail('unimplemented');
};

=head2 stats

Returns a summary of current stats. Placeholder, not yet implemented.

=over 4

=item * Client count

=item * Subscription count

=item * Uptime

=item * Memory usage

=back

=cut

command stats => sub {
    my ($self, $app) = @_;
    state $pt = Proc::ProcessTable->new;
    my $me = (grep { $_->pid == $$ } @{$pt->table})[0];
    Future->done({
            cumulative_client_connections => $app->stat->{cumulative_client_connections},
            current_redis_connections     => _get_redis_connections($app),
            uptime                        => time - $^T,
            rss                           => $me->rss,
            cumulative_redis_errors       => $app->stat->{redis_errors}});
};

command backend => sub {
    my ($self, $app, $method, $backend) = @_;
    my $ws_actions  = $Binary::WebSocketAPI::WS_ACTIONS;
    my $ws_backends = $Binary::WebSocketAPI::WS_BACKENDS;

    my $backend_list = join(', ', keys %$ws_backends);

    return Future->fail('Websocket actions are not initialized yet. Please try later') unless $ws_actions;

    return Future->fail('No method name is specified (usage: backend <method> <backend>)') unless $method;

    return Future->done({backend_list => $backend_list}) if ($method eq '--list');
    return Future->fail("Method '$method' was not found") unless exists $ws_actions->{$method};

    return Future->fail('No backend name is specified (usage: backend <method> <backend>)') unless $backend;

    $backend = 'default' if $backend eq 'rpc_redis';
    if ($backend eq ($ws_actions->{$method}->{backend} // 'default')) {
        return Future->fail("Backend is already set to '$backend' for method '$method'. Nothing is changed.");
    }

    unless ($backend eq 'default' or exists $ws_backends->{$backend}) {
        my $msg = "Backend '$backend' was not found. Available backends: $backend_list";
        return Future->fail($msg);
    }

    $ws_actions->{$method}->{backend} = $backend;

    my $redis = ws_redis_master();

    my %method_backends = map { $ws_actions->{$_}->{backend} ? ($_ => $ws_actions->{$_}->{backend}) : () } keys $ws_actions->%*;
    my $f               = Future::Mojo->new;
    $redis->set(
        'web_socket_proxy::backends' => encode_json_utf8(\%method_backends),
        sub {
            my ($redis, $err) = @_;
            unless ($err) {
                $f->done({$method => $backend});
                return;
            }
            $log->errorf('Error when saving backends to redis - %s', $err);
            DataDog::DogStatsd::Helper::stats_inc(
                'bom_websocket_api.v_3.redis_instances.ws_redis_master.fail',
                {tags => ['introspection', 'command:backend', "args:$method $backend"]});
            $f->fail(
                $err,
                backend => $backend,
                method  => $method
            );
        });
    return $f;
};

sub _get_redis_connections {
    my $app         = shift;
    my $connections = 0;
    my %uniq;

    my @redises = values %Binary::WebSocketAPI::v3::Instance::Redis::INSTANCES;
    unless (@redises) {
        # redises are not moved to Instance::Redis yet...
        for my $c (values %{$app->active_connections // {}}) {
            push @redises, $c->redis if $c->stash->{redis};
        }
        push @redises, $app->redis_feed                if $app->redis_feed;
        push @redises, $app->redis_transaction         if $app->redis_transaction;
        push @redises, $app->redis_pricer              if $app->redis_pricer;
        push @redises, $app->redis_pricer_subscription if $app->redis_pricer_subscription;
        push @redises, $app->ws_redis_master           if $app->ws_redis_master;
    }
    for my $r (@redises) {
        my $con = $r->{connections} // {};
        for my $c (values %$con) {
            $connections++ if $c->{id} && !$uniq{$c->{id}}++;
        }
    }
    return $connections;
}

=head2 dumpmem

Writes a dumpfile using L<Devel::MAT::Dumper>. This can be
viewed with the C<pmat-*> tools, or using the GUI tool from
L<App::Devel::MAT::Explorer::GTK>.

=cut

command dumpmem => sub {
    require Devel::MAT::Dumper;
    my $filename = '/var/lib/binary/websockets/' . strftime('%Y-%m-%d-%H%M%S', gmtime) . '-dump-' . $$ . '.pmat';
    $log->debugf("Writing memory dump to [%s] for %s", $filename, $$);
    my $start = Time::HiRes::time;
    Devel::MAT::Dumper::dump($filename);
    my $elapsed = 1000.0 * (Time::HiRes::time - $start);
    Future->done({
        file    => $filename,
        elapsed => $elapsed,
        size    => -s $filename,
    });
};

=head2 divert

Mark an app_id for diversion to a different server.

=cut

command divert => sub {
    my ($self, $app, $app_id, $service) = @_;
    my $redis = ws_redis_master();
    my $f     = Future::Mojo->new;
    $redis->get(
        'app_id::diverted',
        sub {
            my ($redis, $err, $ids) = @_;
            if ($err) {
                $log->errorf('Error reading diverted app IDs from Redis: %s', $err);
                return $f->fail(
                    $err,
                    redis => $app_id,
                    $service
                );
            }
            # We'd expect this to be an empty hashref - i.e. true - if there's a value back from Redis.
            # No value => no update.
            %Binary::WebSocketAPI::DIVERT_APP_IDS = %{$json->decode(Encode::decode_utf8($ids))} if $ids;
            my $rslt = {diversions => \%Binary::WebSocketAPI::DIVERT_APP_IDS};
            if ($app_id) {
                if ($service) {
                    $Binary::WebSocketAPI::DIVERT_APP_IDS{$app_id} = $service;
                } else {
                    delete $Binary::WebSocketAPI::DIVERT_APP_IDS{$app_id};
                }
                $redis->set(
                    'app_id::diverted' => Encode::encode_utf8($json->encode(\%Binary::WebSocketAPI::DIVERT_APP_IDS)),
                    sub {
                        my ($redis, $err) = @_;
                        unless ($err) {
                            # Since this contains a reference rather than a copy of the diversion hash,
                            # it'll pick up the change we just made
                            $f->done($rslt);
                            return;
                        }
                        $log->errorf('Redis error when recording diverted app_id - %s', $err);
                        $f->fail(
                            $err,
                            redis => $app_id,
                            $service
                        );
                    });
            } else {
                $f->done($rslt);
            }
        });
    return $f;
};

=head2 block

Block an app_id from connecting.

=cut

command block => sub {
    my ($self, $app, $app_id, $service) = @_;
    my $redis = ws_redis_master();
    my $f     = Future::Mojo->new;
    $redis->get(
        'app_id::blocked',
        sub {
            my ($redis, $err, $ids) = @_;
            if ($err) {
                $log->errorf('Error reading blocked app IDs from Redis: %s', $err);
                return $f->fail(
                    $err,
                    redis => $app_id,
                    $service
                );
            }
            %Binary::WebSocketAPI::BLOCK_APP_IDS = %{$json->decode(Encode::decode_utf8($ids))} if $ids;
            my $rslt = {blocked => \%Binary::WebSocketAPI::BLOCK_APP_IDS};
            if ($app_id) {
                if ($service) {
                    $Binary::WebSocketAPI::BLOCK_APP_IDS{$app_id} = $service;
                } else {
                    delete $Binary::WebSocketAPI::BLOCK_APP_IDS{$app_id};
                }
                # don't write the app_ids that marked as 'inactive' into redis
                # this variable will be fetched when ws connection built. At that time ws knows the app id that marked as inactive is invalid
                # So those app ids needn't to be stored in redis
                my %blocked_app_ids = %Binary::WebSocketAPI::BLOCK_APP_IDS;
                delete $blocked_app_ids{$app_id} if $service && $service eq 'inactive';
                $redis->set(
                    'app_id::blocked' => Encode::encode_utf8($json->encode(\%blocked_app_ids)),
                    sub {
                        my ($redis, $err) = @_;
                        unless ($err) {
                            $f->done($rslt);
                            return;
                        }
                        $log->errorf('Redis error when recording blocked app_id - %s', $err);
                        $f->fail(
                            $err,
                            redis => $app_id,
                            $service
                        );
                    });
            } else {
                $f->done($rslt);
            }
        });
    return $f;
};

=head2 block_origin

Block a domain from connecting.

=cut

command block_origin => sub {
    my ($self, $app, $origin, $service) = @_;
    my $redis = ws_redis_master();
    my $f     = Future::Mojo->new;
    $redis->get(
        'origins::blocked',
        sub {
            my ($redis, $err, $origins) = @_;
            if ($err) {
                $log->errorf('Error reading blocked app orgins from Redis: %s', $err);
                return $f->fail(
                    $err,
                    redis => $origins,
                    $service
                );
            }
            %Binary::WebSocketAPI::BLOCK_ORIGINS = %{$json->decode(Encode::decode_utf8($origins))} if $origins;
            my $rslt = {blocked => \%Binary::WebSocketAPI::BLOCK_ORIGINS};
            if ($origin) {
                if ($service) {
                    $Binary::WebSocketAPI::BLOCK_ORIGINS{$origin} = 1;
                } else {
                    delete $Binary::WebSocketAPI::BLOCK_ORIGINS{$origin};
                }
                $redis->set(
                    'origins::blocked' => Encode::encode_utf8($json->encode(\%Binary::WebSocketAPI::BLOCK_ORIGINS)),
                    sub {
                        my ($redis, $err) = @_;
                        unless ($err) {
                            $f->done($rslt);
                            return;
                        }
                        $log->errorf('Redis error when recording blocked origin - %s', $err);
                        $f->fail(
                            $err,
                            redis => $origin,
                            $service
                        );
                    });
            } else {
                $f->done($rslt);
            }
        });
    return $f;
};

=head2 logging

To start/stop logging of certain RPC calls.

=over 4

=item * C<type> - Either of these: C<all>, C<method>, C<app_id> or C<loginid>

=item * C<value> - Value to check against the type (omitted if type is C<all>).

=item * C<action> - on/off

=back

Returns the logging configuration.

=cut

command logging => sub {
    my ($self, $app, $type, $value, $action) = @_;
    my $redis = ws_redis_master();
    my $f     = Future::Mojo->new;
    # all takes no value, only on/off
    $action = $value if defined $type and $type eq 'all';
    $redis->get(
        'rpc::logging',
        sub {
            my ($redis, $err, $config) = @_;
            if ($err) {
                $log->errorf('Error reading RPC logging config from Redis: %s', $err);
                return $f->fail($err);
            }
            %Binary::WebSocketAPI::RPC_LOGGING = $json->decode(Encode::decode_utf8($config))->%* if $config;
            my $rslt = {logging => \%Binary::WebSocketAPI::RPC_LOGGING};
            if ($type) {
                if ($type =~ /^(loginid|method|app_id)$/ and defined $value and defined $action) {
                    if ($action eq 'on') {
                        $Binary::WebSocketAPI::RPC_LOGGING{$type}{$value} = 1;
                    } elsif ($action eq 'off') {
                        delete $Binary::WebSocketAPI::RPC_LOGGING{$type}{$value};
                        delete $Binary::WebSocketAPI::RPC_LOGGING{$type}
                            unless $Binary::WebSocketAPI::RPC_LOGGING{$type}->%*;
                    } else {
                        return $f->fail("Action can be either on or off, passed: $action");
                    }
                } elsif ($type eq 'all') {
                    if (defined $action and $action eq 'on') {
                        $Binary::WebSocketAPI::RPC_LOGGING{$type} = 1;
                    } else {
                        delete $Binary::WebSocketAPI::RPC_LOGGING{$type};
                    }
                } else {
                    return $f->fail("Usage: logging [type] [value] [action], passed: " . join(', ', $type, $value, $action));
                }
                $redis->set(
                    'rpc::logging' => Encode::encode_utf8($json->encode(\%Binary::WebSocketAPI::RPC_LOGGING)),
                    sub {
                        my ($redis, $err) = @_;
                        unless ($err) {
                            $f->done($rslt);
                            return;
                        }
                        $log->errorf('Redis error when setting RPC logging config - %s', $err);
                        $f->fail(
                            $err,
                            type   => $type,
                            value  => $value,
                            action => $action,
                        );
                    });
            } else {
                $f->done($rslt);
            }
        });
    return $f;
};

=head2 block_app_in_domain

To block or unblock app ids from certain environments like red, blue etc

=over 4

=item * C<app_id> App id to block or unblock

=item * C<env> Environment red/blue/green

=item * C<block_status> Block/unblock example Yes to block, leave empty to unblock

=back

Returns the apps blocked from operation domain

=cut

command block_app_in_domain => sub {
    my ($self, $app, $app_id, $env, $block_status) = @_;
    my $redis = ws_redis_master();
    if ($app_id && $env) {
        my $operation;
        if ($block_status) {
            $operation = Binary::WebSocketAPI::add_remove_apps_blocked_from_opertion_domain('add', $app_id, $env);
        } else {
            $operation = Binary::WebSocketAPI::add_remove_apps_blocked_from_opertion_domain('del', $app_id, $env);
        }
        return $operation->then(
            sub {
                return _get_apps_blocked_from_operation_domain();
            });
    } else {
        return _get_apps_blocked_from_operation_domain();
    }
};

=head2 throttle

Will throttle the number of requests being passed through to the rpc workers by
a given integer percentage. e.g throttle 5 will mean that 5% of incoming requests
are just dropped, there will be no error response, we don't want the client to
retry as this is a temporary measure to reduce load.

=over 4

=item * C<value> - %age throttle value to use.

=back

Returns the logging configuration.

=cut

command throttle => sub {
    my ($self, $app, $throttle) = @_;
    my $redis = ws_redis_master();
    my $f     = Future::Mojo->new;

    $redis->get(
        'rpc::throttle',
        sub {
            my ($redis, $err, $current_throttle) = @_;
            if ($err) {
                $log->errorf('Error reading RPC throttle config from Redis: %s', $err);
                return $f->fail($err);
            }
            if (defined $throttle) {
                if ($throttle =~ /^\d+$/ && $throttle >= 0 && $throttle <= 100) {
                    $redis->set(
                        'rpc::throttle' => $throttle,
                        sub {
                            my ($redis, $err) = @_;
                            unless ($err) {
                                $Binary::WebSocketAPI::RPC_THROTTLE->{throttle}         = $throttle;
                                $Binary::WebSocketAPI::RPC_THROTTLE->{requests_dropped} = 0;
                                $Binary::WebSocketAPI::RPC_THROTTLE->{requests_passed}  = 0;
                                $f->done({
                                    %$Binary::WebSocketAPI::RPC_THROTTLE,
                                    message => "Passed/Dropped counts have been reset to 0 after setting throttle value"
                                });
                                return;
                            }
                            $log->errorf('Redis error when setting RPC throttle value - %s', $err);
                            $f->fail($err, throttle => $throttle);
                        });
                } else {
                    return $f->fail("Usage: throttle [value 0-100], was passed: " . $throttle);
                }
            } else {
                if (defined $current_throttle) {
                    $f->done({%$Binary::WebSocketAPI::RPC_THROTTLE, throttle => $current_throttle});
                } else {
                    $f->done({
                        %$Binary::WebSocketAPI::RPC_THROTTLE,
                        message => "No throttle value found in redis for rpc::throttle, instance value provided"
                    });
                }
            }
        });
    return $f;
};

=head2 timeout_extension

Will extend the internal expiry time of calls placed into the RPC queues for a given category/
rpc. There are two types of extension, absolute and percentage. However the external deadline
advertised in redis will be the same. The idea is that under heavy load an rpc worker can pickup
a job that has almost expired and additional time is given for it in bws to complete, whereas
without the extension it might have picked up a job that was impossible to complete in the
timeframe and work would have been lost as bws would have timed out and responded failure to the
client

=over 4

=item * C<value> - %age throttle value to use.

=back

Returns the logging configuration.

=cut

command timeout_extension => sub {
    my ($self, $app, $timeout_extension_json) = @_;
    my $redis = ws_redis_master();
    my $f     = Future::Mojo->new;

    $redis->get(
        'rpc::timeout_extension',
        sub {
            my ($redis, $err, $config) = @_;
            if ($err) {
                $log->errorf('Error reading RPC throttle config from Redis: %s', $err);
                return $f->fail($err);
            }

            if (defined $timeout_extension_json) {
                # Decode JSON string into a Perl hash
                my $data;
                try {
                    $data = decode_json($timeout_extension_json);
                } catch {
                    return $f->fail("Invalid structure: json parse failure.\n" . EXPIRY_HELP_STRING . "\n");
                };

                # Validate the top-level structure is a hash with 'timeout_extension' key
                unless (ref $data eq 'ARRAY') {
                    return $f->fail("Invalid structure: top level is not an array.\n" . EXPIRY_HELP_STRING . "\n");
                }

                # Iterate over each element in the 'timeout_extension' array
                foreach my $item (@{$data}) {
                    # Validate each item is a hash with specific keys
                    unless (ref $item eq 'HASH'
                        && exists $item->{category}
                        && exists $item->{rpc}
                        && exists $item->{offset}
                        && exists $item->{percentage})
                    {
                        return $f->fail(
                            "Invalid item structure in 'timeout_extension', array elements should be hash type.\n" . EXPIRY_HELP_STRING . "\n");
                    }

                    # Validate 'category' is a string and a regex
                    unless (is_string($item->{category})) {
                        return $f->fail("Invalid data: 'category' is not a string.\n" . EXPIRY_HELP_STRING . "\n");
                    }
                    unless (eval { qr/$item->{category}/; 1 } || 0) {
                        return $f->fail("Invalid data: 'category' is not a valid regex.\n" . EXPIRY_HELP_STRING . "\n");
                    }

                    # Validate 'rpc' is a string and a regex
                    unless (is_string($item->{rpc})) {
                        return $f->fail("Invalid data: 'rpc' is not a string.\n" . EXPIRY_HELP_STRING . "\n");
                    }
                    unless (eval { qr/$item->{rpc}/; 1 } || 0) {
                        return $f->fail("Invalid data: 'rpc' is not a valid regex.\n" . EXPIRY_HELP_STRING . "\n");
                    }

                    # Validate 'offset' is an integer between 0 and 60
                    unless ($item->{offset} =~ /^\d+$/ && $item->{offset} >= 0 && $item->{offset} <= 60) {
                        return $f->fail("Invalid data: 'offset' is not an integer between 0 and 60.\n" . EXPIRY_HELP_STRING . "\n");
                    }

                    # Validate 'percentage' is an integer between 0 and 100
                    unless ($item->{percentage} =~ /^\d+$/ && $item->{percentage} >= 0 && $item->{percentage} <= 100) {
                        return $f->fail("Invalid data: 'percentage' is not an integer between 0 and 100.\n" . EXPIRY_HELP_STRING . "\n");
                    }
                }
                # %Binary::WebSocketAPI::RPC_TIMEOUT_EXTENSION = $data->{timeout_extension}->@*;
                # $f->done({ timeout_extension => $data->{timeout_extension} });
                # return
                $redis->set(
                    'rpc::timeout_extension' => Encode::encode_utf8($json->encode($data)),
                    sub {
                        my ($redis, $err) = @_;
                        unless ($err) {
                            $Binary::WebSocketAPI::RPC_TIMEOUT_EXTENSION = $data;
                            $f->done({timeout_extension => $data});
                            return;
                        }
                        $log->errorf('Redis error when setting RPC timeout_extension values - %s', $err);
                        $f->fail($err, timeout_extension => $data);
                    });

            } else {
                if (defined $config) {
                    $f->done({timeout_extension => $json->decode(Encode::decode_utf8($config))});
                } else {
                    $f->done({
                        timeout_extension => $Binary::WebSocketAPI::RPC_TIMEOUT_EXTENSION,
                        message           => "No expiry extension value found in redis for rpc::timeout_extension, instance value provided"
                    });
                }
            }
        });
    return $f;
};

=head2 is_string

Returns 1 if the passed in var is a string, 0 otherwise.

=cut

sub is_string {
    my ($var) = @_;

    # Check if it's a reference or an object
    return 0 if ref($var) || blessed($var);

    # Check if it doesn't look like a number
    return !looks_like_number($var);
}

sub _get_apps_blocked_from_operation_domain {
    return Binary::WebSocketAPI::get_apps_blocked_from_operation_domain()->then(
        sub {
            my $result = shift;
            my $rslt   = {blocked => $result};
            return Future::Mojo->done($rslt);
        }
    )->catch(
        sub {
            my $err = shift;
            $log->errorf('Redis error when getting blocked apps - %s', $err);
            return Future::Mojo->fail($err);
        });
}

=head2 help

Returns a list of available commands.

=cut

command help => sub {
    Future->done({
        commands => [sort keys %COMMANDS],
    });
};

1;
