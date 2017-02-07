package Binary::WebSocketAPI::Plugins::Introspection;

use strict;
use warnings;

use parent qw(Mojolicious::Plugin);

no indirect;

use Mojo::IOLoop;
use Future;
use Future::Mojo;
use Try::Tiny;

use JSON::XS;
use Scalar::Util qw(blessed);
use Variable::Disposition qw(retain_future);

use Socket qw(:crlf);

# FIXME This needs to come from config, requires chef changes
use constant INTROSPECTION_PORT => 8801;
# How many seconds to allow per command - anything that takes more than a few milliseconds
# is probably a bad idea, please do not rely on this for any meaningful protection
use constant MAX_REQUEST_SECONDS => 5;

=head2 register

Registers the plugin by creating an introspection TCP server endpoint.

=cut

sub register {
    my ($self, $app, $conf) = @_;

    Mojo::IOLoop->server({
        port => INTROSPECTION_PORT
    } => sub {
        my ($loop, $stream) = @_;

        # Client has connected, wait for commands and send responses back
        my $buffer = ''
        $stream->on(read => sub {
            my ($stream, $bytes) = @_;

            my $buffer .= $bytes;
            # One command per line
            while($buffer =~ s/^(.*)$CRLF//) {
                my ($command, @args) = split /[ =]/, $1;
                my $write_to_log = 0;
                if($command eq 'log') {
                    $write_to_log = 1;
                    $command = shift @args;
                }
                if(is_valid_command($command)) {
                    warn "Executing command: $command @args\n";
                    my $rslt = try {
                        $self->$command($app, @args);
                    } catch {
                        Future->fail($_, introspection => $command, @args)
                    };
                    # Allow deferred results
                    $rslt = Future->done($rslt) unless blessed($rslt) && $rslt->isa('Future');
                    retain_future(
                        Future->needs_any(
                            $rslt,
                            Future::Mojo->new_timer(MAX_REQUEST_SECONDS),
                        )->then(sub {
                            my ($resp) = @_;
                            my $output = encode_json($resp);
                            warn "$command (@args) - $output\n" if $write_to_log;
                            $stream->write("OK - $output$CRLF");
                            Future->done
                        }, sub {
                            my ($resp) = @_;
                            my $output = encode_json($resp);
                            warn "$command (@args) failed - $output\n";
                            $stream->write("ERR - $output$CRLF");
                            Future->done
                        })
                    )
                } else {
                    warn "Invalid command: $command @args\n";
                    $stream->write(sprintf "Invalid command [%s]", $command);
                }
            }
        });
    });
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
        no strict 'refs';
        die "Already registered $name" if exists $COMMANDS{$name};
        die "Not registered but already ->can($name)" if __PACKAGE__->can($name);
        $COMMANDS{$name} = 1;
        *$name = sub {
            my $self = shift;
            $self->$code(%args, @_);
        }
    }
}


=head2 is_valid_command

Returns true if we have registered this command. Used as an extra protection
against commands like 'DESTROY' or 'BEGIN'.

=cut

sub is_valid_command { exists $COMMANDS{shift()} }

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
    my ($app) = @_;
    Future->done(
        map +{
            app_id          => $_->stash->{source},
            lang            => $_->l,
            landing_company => $_->landing_company_name,
            ip              => $_->stash->{client_ip},
            country         => $_->country_code,
            client          => $_->stash->{loginid},
        } sort values %{$app->active_connections}
    )
};

=head2 subscriptions

Returns a list of all subscribed Redis channels. Placeholder, not yet implemented.

=cut

command subscriptions => sub {
    Future->fail('unimplemented')
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
    Future->fail('unimplemented')
};

=head2 dumpmem

Writes a dumpfile using L<Devel::MAT::Dumper>. This can be
viewed with the C<pmat-*> tools, or using the GUI tool from
L<App::Devel::MAT::Explorer::GTK>.

=cut

command dumpmem => sub {
    require Devel::MAT::Dumper;
    my $filename = '/var/lib/binary/websockets/' . strftime('%Y-%m-%d-%H%M%S', gmtime) . '-dump-$$.pmat';
    warn "Writing memory dump to [$filename] for $$\n";
    my $start = Time::HiRes::time;
    Devel::MAT::Dumper::dump($filename);
    my $elapsed = 1000.0 * (Time::HiRes::time - $start);
    Future->done({
        file => $filename,
        elapsed => $elapsed,
        size => -s $filename,
    })
};

1;
