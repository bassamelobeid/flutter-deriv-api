package BOM::Event::Listener;

use strict;
use warnings;

use Log::Any qw($log);
use Syntax::Keyword::Try;

use BOM::Platform::Event::Emitter;
use BOM::Event::Process;
use BOM::Event::QueueHandler;

use IO::Async::Loop;

use constant SHUTDOWN_TIMEOUT => 60;

=head1 NAME

BOM::Event::Listener - Listen to events

=head1 SYNOPSIS

    BOM::Event::Listener->new(queue => '...')->run

=head1 DESCRIPTION

Watches queues in Redis for events and processes them accordingly.

=cut

sub new {
    my ($class, %args) = @_;
    return bless \%args, $class;
}

sub queue { return shift->{queue} }

sub run {    ## no critic (RequireFinalReturn)
    my $self = shift;
    $log->debugf('Starting listener for queue %s', $self->queue);
    my $loop = IO::Async::Loop->new;
    my $handler = BOM::Event::QueueHandler->new(queue => $self->queue);
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
        $handler->should_shutdown->done unless $handler->should_shutdown->is_ready;
    };
    $loop->add($handler);
    # Wait for the processing loop to end naturally (either due to errors, or
    # from the shutdown signal)
    try {
        $handler->process_loop->get;
    }
    catch {
        $log->errorf('Event listener bailing out early for %s - %s', $self->queue, $@) unless $@ =~ /normal_shutdown/;
    }
    finally {
        alarm(0);
    }
}

1;
