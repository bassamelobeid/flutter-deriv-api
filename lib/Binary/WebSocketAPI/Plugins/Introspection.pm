package Binary::WebSocketAPI::Plugins::Introspection;

use strict;
use warnings;

use parent qw(Mojolicious::Plugin);

no indirect;

use Mojo::IOLoop;
use Future;
use Future::Mojo;
use Try::Tiny;
use POSIX qw(strftime);

use JSON::XS;
use Scalar::Util qw(blessed);
use Variable::Disposition qw(retain_future);
use Socket qw(:crlf);
use Proc::ProcessTable;
use feature 'state';
use Binary::WebSocketAPI::v3::Instance::Redis;

# How many seconds to allow per command - anything that takes more than a few milliseconds
# is probably a bad idea, please do not rely on this for any meaningful protection
use constant MAX_REQUEST_SECONDS => 5;

=head2 start_server

Tries to start the introspection endpoint. May fail on hot restart, since the port will be
taken by something else and we have no SO_REUSEPORT on our current kernel.

=cut

sub start_server {
    my ($self, $app, $conf) = @_;
    my $id = Mojo::IOLoop->server({
            port => $conf->{port},
        } => sub {
            my (undef, $stream) = @_;

            # Client has connected, wait for commands and send responses back
            my $buffer = '';
            $stream->on(
                read => sub {
                    my ($stream, $bytes) = @_;

                    $buffer .= $bytes;
                    # One command per line
                    while ($buffer =~ s/^([^\x0D\x0A]+)\x0D?\x0A//) {
                        my ($command, @args) = split /[ =]/, $1;
                        my $write_to_log = 0;
                        if ($command eq 'log') {
                            $write_to_log = 1;
                            $command      = shift @args;
                        }
                        if (is_valid_command($command)) {
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
                            retain_future(
                                Future->wait_any($rslt, Future::Mojo->new_timer(MAX_REQUEST_SECONDS)->then(sub { Future->fail('Timeout') }),)->then(
                                    sub {
                                        my ($resp) = @_;
                                        my $output = encode_json($resp);
                                        warn "$command (@args) - $output\n" if $write_to_log;
                                        $stream->write("OK - $output$CRLF");
                                        Future->done;
                                    },
                                    sub {
                                        my ($exception, $category, @details) = @_;
                                        my $output = encode_json({
                                            error    => $exception,
                                            category => $category,
                                            details  => \@details
                                        });
                                        warn "$command (@args) failed - $output\n";
                                        $stream->write("ERR - $output$CRLF");
                                        Future->done;
                                    }));
                        } else {
                            warn "Invalid command: $command @args\n";
                            $stream->write(sprintf "Invalid command [%s]", $command);
                        }
                    }
                });
        });
    $app->log->info("Introspection listening on :" . Mojo::IOLoop->acceptor($id)->port);
    return;
}

=head2 register

Registers the plugin by creating an introspection TCP server endpoint.

This will keep on trying every 2 seconds for 100 retries: this is because
we don't have a reliable way to reuse the port, and listening on a random
port would not be as convenient.

=cut

sub register {
    my ($self, $app, $conf) = @_;

    my $retries = 100;
    my $code;
    $code = sub {
        Mojo::IOLoop->timer(
            2 => sub {
                try {
                    $self->start_server($app, $conf);
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
        for my $k (keys %{$_->pricing_subscriptions}) {
            ++$pc if defined $_->pricing_subscriptions->{$k};
        }
        for my $k (keys %{$_->stash->{pricing_channel} || {}}) {
            next if $k eq 'uuid';
            next if $k eq 'price_daemon_cmd';
            $ch += scalar keys %{$_->stash->{pricing_channel}{$k}};
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

=head2 help

Returns a list of available commands.

=cut

command help => sub {
    Future->done({
        commands => [sort keys %COMMANDS],
    });
};

1;
