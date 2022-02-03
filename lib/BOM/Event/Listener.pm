package BOM::Event::Listener;

use strict;
use warnings;

use Log::Any qw($log);
use Syntax::Keyword::Try;

use BOM::Event::QueueHandler;

use IO::Async::Loop;
use Future::AsyncAwait;
use BOM::Event::Utility qw(exception_logged);

use constant SHUTDOWN_TIMEOUT => 60;

=head1 NAME

BOM::Event::Listener - Listen to events

=head1 SYNOPSIS

    BOM::Event::Listener->new(queue  => '...')->run
    BOM::Event::Listener->new(stream => '...')->run

=head1 DESCRIPTION

Watches queues in Redis for events and processes them accordingly.

=cut

sub new {
    my ($class, %args) = @_;

    return bless \%args, $class;
}

# The following 5 attributes are mainly just passed through
# to QueueHandler.
sub queue { return shift->{queue} }

# Use redis streams
sub streams { return shift->{streams} }

# Optional field for type of jobs to process
sub category { return shift->{category} }

sub maximum_job_time { return shift->{maximum_job_time} }

sub maximum_processing_time { return shift->{maximum_processing_time} }

sub shutdown_time_out { return shift->{shutdown_time_out} // SHUTDOWN_TIMEOUT }

# Set this if it is being run in parallel forks so that the
# fork termination process is  handled by the calling script.
sub running_parallel { return shift->{running_parallel} // 0 }

sub handler { return shift->{handler} }

sub worker_index { return shift->{worker_index} }

sub run {    ## no critic (RequireFinalReturn)
    my $self = shift;

    my $loop = IO::Async::Loop->new;

    my $handler = BOM::Event::QueueHandler->new(
        queue                   => $self->queue,
        streams                 => $self->streams,
        category                => $self->category,
        maximum_job_time        => $self->maximum_job_time,
        maximum_processing_time => $self->maximum_processing_time,
        worker_index            => $self->worker_index,
    );

    $loop->add($handler);
    $self->{handler} = $handler;
    local $SIG{TERM} = local $SIG{INT} = sub {
        $log->debug('got shutdown signal');
        # If things go badly wrong, we might never exit the loop. This attempts to
        # force the issue 60 seconds after the shutdown flag is set.
        # Note that it's not 100% guaranteed, might want to replace this with a hard
        # exit().
        local $SIG{ALRM} = sub {
            $log->errorf('Took too long to shut down, stopping loop manually');
            $loop->stop;
        };
        alarm($self->shutdown_time_out);
        # Could end up with multiple signals, so it's expected that subsequent
        # calls to this sub will not be able to mark as done
        $handler->should_shutdown->done unless $handler->should_shutdown->is_ready;
    };
    # Wait for the processing loop to end naturally (either due to errors, or
    # from the shutdown signal)
    try {
        $self->streams ? $handler->stream_process_loop->get : $handler->queue_process_loop->get;
    } catch ($e) {
        $log->errorf("Event listener bailing out early - %s ", $e) unless $e =~ /normal_shutdown/;
        exception_logged()                                         unless $e =~ /normal_shutdown/;
    } finally {
        alarm(0);
    }
}

1;
