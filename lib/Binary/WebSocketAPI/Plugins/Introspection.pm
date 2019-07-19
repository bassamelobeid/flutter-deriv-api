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
use Try::Tiny;
use POSIX qw(strftime);

use JSON::MaybeXS;
use Scalar::Util qw(blessed);
use Variable::Disposition qw(retain_future);
use Socket qw(:crlf);
use Proc::ProcessTable;
use feature 'state';
use Binary::WebSocketAPI::v3::Instance::Redis qw(ws_redis_master);

# How many seconds to allow per command - anything that takes more than a few milliseconds
# is probably a bad idea, please do not rely on this for any meaningful protection
use constant MAX_REQUEST_SECONDS => 5;

use constant INTROSPECTION_CHANNEL => 'introspection';

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
                                    warn "Publish response - $err" if $err;
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
                                    warn "Publish failure response - $err" if $err;
                                });
                        }));
            }));
    $INTROSPECTION_REDIS->subscribe(
        [INTROSPECTION_CHANNEL],
        sub {
            my ($redis, $err) = @_;
            return unless $err;
            warn "Failed to subscribe to introspection endpoint: " . $err;
        });
    $app->log->info("Introspection listening on: " . INTROSPECTION_CHANNEL);
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
        warn "Invalid command: $command @args\n";
        return Future->fail(
            sprintf("Invalid command [%s]", $command),
            invalid_command => $command,
            @args
        );
    }

    my $rslt = try {
        $self->$command($app, @args);
    }
    catch {
        Future->fail(
            $_,
            introspection => $command,
            @args
        );
    };
    # Allow deferred results
    $rslt = Future->done($rslt) unless blessed($rslt) && $rslt->isa('Future');
    return Future->wait_any($rslt, Future::Mojo->new_timer(MAX_REQUEST_SECONDS)->then(sub { Future->fail('Timeout') }),)->on_done(
        sub {
            my ($resp) = @_;
            warn "$command (@args) - " . $json->encode($resp) . "\n" if $write_to_log;
        }
        )->else(
        sub {
            my ($exception, $category, @details) = @_;
            my $rslt = {
                error    => $exception,
                category => $category,
                details  => \@details
            };
            warn "$command (@args) failed - $exception\n";
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
                }
                catch {
                    return unless $code;
                    return $code->() if $retries--;
                    warn "Unable to start introspection server after 100 retries - $@";
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
        die "Already registered $name" if exists $COMMANDS{$name};
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
        grep {
        defined
        }
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
        push @redises, $app->shared_redis    if $app->shared_redis;
        push @redises, $app->redis_pricer    if $app->redis_pricer;
        push @redises, $app->ws_redis_master if $app->ws_redis_master;
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
    warn "Writing memory dump to [$filename] for $$\n";
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
                warn "Error reading diverted app IDs from Redis: $err\n";
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
                        warn "Redis error when recording diverted app_id - $err";
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
                warn "Error reading blocked app IDs from Redis: $err\n";
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
                    $Binary::WebSocketAPI::BLOCK_APP_IDS{$app_id} = 1;
                } else {
                    delete $Binary::WebSocketAPI::BLOCK_APP_IDS{$app_id};
                }
                $redis->set(
                    'app_id::blocked' => Encode::encode_utf8($json->encode(\%Binary::WebSocketAPI::BLOCK_APP_IDS)),
                    sub {
                        my ($redis, $err) = @_;
                        unless ($err) {
                            $f->done($rslt);
                            return;
                        }
                        warn "Redis error when recording blocked app_id - $err";
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
                warn "Error reading blocked app orgins from Redis: $err\n";
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
                        warn "Redis error when recording blocked origin - $err";
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

=item * C<type> - Either of these: C<all>, C<method>, C<app_id> or C<loginid>

=item * C<value> - Value to check against the type (omitted if type is C<all>).

=item * C<action> - on/off

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
                warn "Error reading RPC logging config from Redis: $err\n";
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
                        warn "Redis error when setting RPC logging config - $err";
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

=head2 help

Returns a list of available commands.

=cut

command help => sub {
    Future->done({
        commands => [sort keys %COMMANDS],
    });
};

1;
