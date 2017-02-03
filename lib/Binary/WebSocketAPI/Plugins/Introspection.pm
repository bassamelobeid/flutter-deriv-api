package Binary::WebSocketAPI::Plugins::Introspection;

use strict;
use warnings;

use parent qw(Mojolicious::Plugin);

use Mojo::IOLoop;
use Future;
use Future::Mojo;

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
                if(is_valid_command($command)) {
                    warn "Executing command: $command @args\n";
                    my $rslt = $self->$command(@args);
                    # Allow deferred results
                    $rslt = Future->done($rslt) unless blessed($rslt) && $rslt->isa('Future');
                    retain_future(
                        Future->needs_any(
                            $rslt,
                            Future::Mojo->new_timer(MAX_REQUEST_SECONDS),
                        )->then(sub {
                            $stream->write('OK - ' . encode_json(shift) . $CRLF);
                        }, sub {
                            $stream->write('ERR - ' . encode_json(shift) . $CRLF);
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

1;
