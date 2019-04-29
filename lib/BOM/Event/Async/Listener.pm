package BOM::Event::Async::Listener;

use strict;
use warnings;

use Log::Any qw($log);

use Date::Utility;
use BOM::Platform::Event::Emitter;
use BOM::Event::Process;
use BOM::Event::Async::QueueHandler;

use IO::Async::Loop;

use constant SHUTDOWN_TIMEOUT => 60;

=head1 NAME

BOM::Event::Async::Listener - Listen to events

=head1 SYNOPSIS

    BOM::Event::Async::Listener->new(queue => '...')->run

=head1 DESCRIPTION

Watches queues in Redis for events and processes them accordingly.

=cut

sub new {
    my ($class, %args) = @_;
    return bless \%args, $class;
}

sub queue { return shift->{queue} }

sub run {
    my ($self, $queue_name) = @_;
    my $loop = IO::Async::Loop->new;
    my $handler = BOM::Event::Async::QueueHandler->new(queue => $self->queue);
    local $SIG{TERM} = local $SIG{INT} = sub {
        # If things go badly wrong, we might never exit the loop. This attempts to
        # force the issue 60 seconds after the shutdown flag is set.
        # Note that it's not 100% guaranteed, might want to replace this with a hard
        # exit().
        local $SIG{ALRM} = sub {
            $log->errorf('Took too long to shut down, stopping loop manually');
            $loop->stop;
        };
        alarm(SHUTDOWN_TIMEOUT);
        # Could end up with multiple signals, so it's expected that subsequent
        # calls to this sub will not be able to mark as done
        $handler->shutdown->done unless $handler->shutdown->is_ready;
    };
    $loop->add($handler);
    # Wait for the processing loop to end naturally (either due to errors, or
    # from the shutdown signal)
    return try {
        $handler->process_loop->get;
    }
    catch {
        $log->errorf('Event listener bailing out early for %s - %s', $self->queue, $@);
    }
    finally {
        alarm(0);
    }
}

1;
