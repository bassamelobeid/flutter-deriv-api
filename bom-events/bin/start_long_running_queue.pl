#!/usr/bin/env perl

use strict;
use warnings;
use Getopt::Long;
use Pod::Usage;
use Sys::Info;
use List::Util qw(max);
use Parallel::ForkManager;
use DataDog::DogStatsd::Helper;
use LWP::Simple;
use Path::Tiny;
use Log::Any::Adapter;

=head1 NAME

start_long_running_job_queue.pl - Long running job queue runner

=head1 DESCRIPTION

This is designed as a generic queue runner for various long running queues.
This can run multiple synchronous jobs that take minutes to hours to complete.
Rather than having multiple PL files for each queue this takes a Queue name parameter among others so
it can be reused.

Because the Event system will not rerun failed or incomplete jobs, Long running jobs need to make sure they are
capable of being rerun.

=head1 SYNOPSIS

    start_long_running_job_queue.pl  --streams <stream1,stream2> --queue <queue_name> --maximum_process_time=<Process time out> --maximum_job_time=<Max job time> --number_of_workers=<number of processes to spawn> --shutdown_time_out=<Number of seconds allowed for graceful shutdown>


=over 4

=item * --queue  the name of the queue in Redis that this will be listening to.

=item * --streams  comma separated list of Redis streams to listen to.

=item * --type  type of jobs to process

=item * --maximum_job_time : The maximum number of seconds an Job can run for.

=item * --number_of_workers :  The Number of forks of this script to run in parallel.  Defaults to  the the number of cpu's available.

=item * --shutdown_time_out :  The amount of time to allow for a graceful shutdown after the C<TERM> or C<INT> signal is received. Once reached the C<KILL> signal will be sent.

=item * --json_log_file : The json format log file
=back


=cut

my %options;
# Defaults
$options{running_parallel}  = 0;
$options{shutdown_time_out} = 60;    #this defaults to 60 seconds in BOM::Event::Listener so makes sense to default to the same here.
$options{number_of_workers} = max(1, Sys::Info->new->device("CPU")->count);
$options{json_log_file}     = '/var/log/deriv/' . path($0)->basename . '.json.log';
$options{log_level}         = 'info';

GetOptions(
    \%options,         "streams=s",  "number_of_workers=i", "queue=s", "maximum_job_time=i", "shutdown_time_out=i",
    "json_log_file=s", "category=s", "log_level=s",
);

Log::Any::Adapter->import(
    qw(DERIV),
    log_level     => $options{log_level} // $ENV{BOM_LOG_LEVEL},
    json_log_file => $options{json_log_file},
);

# Between queue and stream options one and only one of them should be used,
# maximum_job_time and maximum_process_time are required options.
if (   !(!$options{queue} != !$options{streams})
    || !$options{maximum_job_time}
    || !$options{category})
{
    pod2usage(1);
    die " Invalid Options Entered ";
}

$options{streams} = [split ',', $options{streams}];

my @running_forks;
my @workers = (0) x $options{number_of_workers};

# Only works on AWS so default to local for all else.
my $internal_ip = get("http://169.254.169.254/latest/meta-data/local-ipv4") || '127.0.0.1';

# Enable watchdog
$ENV{IO_ASYNC_WATCHDOG} = 1;
# Set watchdog interval
$ENV{IO_ASYNC_WATCHDOG_INTERVAL} = $options{maximum_job_time} // 30;
# Listner consumes the above env variables to set watchdog timeout
require BOM::Event::Listener;

my $pm = Parallel::ForkManager->new($options{number_of_workers});

local $SIG{INT} = local $SIG{TERM} = sub {
    if (@running_forks) {
        my $start_time = time;
        # Give everything a chance to shut down gracefully before forcibly killing them.
        local $SIG{ALRM} = sub {
            print "Timeout reached forcibly killing child procs.\n";
            kill KILL => @running_forks;
            exit 1;
        };
        kill TERM => @running_forks;
        print " Shutting Down, allowing  children " . $options{shutdown_time_out} . " seconds for graceful shutdown \n";
        alarm $options{shutdown_time_out};
        $pm->wait_all_children;
        exit 1;    #if we get here all the children exited on their own.
    }
};

$pm->run_on_start(
    sub {
        my $pid = shift;
        my ($index) = grep { $workers[$_] == 0 } 0 .. $#workers;
        $workers[$index] = $pid;
        push @running_forks, $pid;
    });
$pm->run_on_finish(
    sub {
        my ($pid, $exit_code) = @_;
        for (@workers) {
            if ($_ == $pid) {
                $_ = 0;
                last;
            }
        }
        @running_forks = grep { $_ != $pid } @running_forks;
    });

while (1) {
    my $pid = $pm->start and next;
    my ($index) = grep { $workers[$_] == $pid } 0 .. $#workers;

    #We are running in child processes here.
    my $daemon = BOM::Event::Listener->new(%options, worker_index => $index);

    # This runs the actual process (queue listening, running jobs etc ) that  we are interested in.
    # It is a blocking call, This while loop will only loop again if the child finishes or is killed.
    # in which case it will cause the respawn of another child to replace the killed one.
    $daemon->run();

    $pm->finish;
}
