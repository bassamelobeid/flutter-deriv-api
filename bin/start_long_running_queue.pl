#!/usr/bin/env perl 

use strict;
use warnings;
use Getopt::Long;
use Pod::Usage;
use Sys::Info;
use List::Util qw(max);
use Parallel::ForkManager;
use BOM::Event::Listener;
use DataDog::DogStatsd::Helper;
use LWP::Simple; 
use Log::Any::Adapter qw(Stderr), log_level => $ENV{BOM_LOG_LEVEL} // 'info';

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
    
    start_long_running_job_queue.pl  --queue <queue_name> --maximum_process_time=<Process time out> --maximum_job_time=<Max job time> --number_of_workers=<number of processes to spawn> --shutdown_time_out=<Number of seconds allowed for graceful shutdown>


=over 4

=item * --queue  the name of the queue in Redis that this will be listening to. 

=item * --maximum_process_time : The maximum number of seconds a Synchronous job can run for. 

=item * --maximum_job_time : The maximum number of seconds an Ansychronous Job can run for. 

=item * --number_of_workers :  The Number of forks of this script to run in parallel.  Defaults to  the the number of cpu's available. 

=item * --shutdown_time_out :  The amount of time to allow for a graceful shutdown after the C<TERM> or C<INT> signal is received. Once reached the C<KILL> signal will be sent.

=back


=cut

my %options ;
# Defaults
$options{running_parallel} = 0;
$options{shutdown_time_out} = 60;  #this defaults to 60 seconds in BOM::Event::Listener so makes sense to default to the same here. 
$options{number_of_workers} = max(1, Sys::Info->new->device("CPU")->count);

GetOptions(
    \%options,
    "number_of_workers=i",
    "queue=s",
    "maximum_job_time=i",
    "maximum_process_time=i",
    "shutdown_time_out=i",
);

my @required_options = qw/queue maximum_job_time maximum_process_time/; 
  
for (@required_options) {if(!$options{$_}) { pod2usage(1); die " Missing Option $_ "; } } 


my @running_forks;
my @workers = (0) x $options{number_of_workers};

# Only works on AWS so default to local for all else. 
my $internal_ip = get("http://169.254.169.254/latest/meta-data/local-ipv4") || '127.0.0.1';

my $pm = Parallel::ForkManager->new($options{number_of_workers});

 local $SIG{INT} = local $SIG{TERM}  = sub {
     if (@running_forks) {
         my $start_time = time;
         # Give everything a chance to shut down gracefully before forcibly killing them.
         local $SIG{ALRM} = sub {
             print "Timeout reached forcibly killing child procs.\n";
             kill KILL => @running_forks;
             exit 1;
         };
         kill TERM => @running_forks;
         print " Shutting Down, allowing  children ".$options{shutdown_time_out}." seconds for graceful shutdown \n";
         alarm $options{shutdown_time_out}; 
         $pm->wait_all_children;
         exit 1; #if we get here all the children exited on their own. 
     }
 };


$pm->run_on_start(
    sub {
        my $pid = shift;
        my ($index) = grep { $workers[$_] == 0 } 0 .. $#workers;
        $workers[$index] = $pid;
        push @running_forks, $pid;
        DataDog::DogStatsd::Helper::stats_gauge('long_running_event_queue.'.$options{queue}.'.forks.count', (scalar @running_forks), {tags => ['tag:' . $internal_ip]});
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

        DataDog::DogStatsd::Helper::stats_gauge('long_running_event_queue.'.$options{queue}.'.forks.count', (scalar @running_forks), {tags => ['tag:' . $internal_ip]});
    });

while (1) {
  $pm->start and next;
  #We are running in child processes here. 
    my $daemon = BOM::Event::Listener->new(%options);

    # This runs the actual process (queue listening, running jobs etc ) that  we are interested in.
    # It is a blocking call, This while loop will only loop again if the child finishes or is killed. 
    # in which case it will cause the respawn of another child to replace the killed one.
    $daemon->run();

    $pm->finish;
}
