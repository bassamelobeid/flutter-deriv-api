#!/etc/rmg/bin/perl

use strict;
use warnings;

use IO::Async::Listener;
use IO::Async::Loop;
use IO::Async::Process::GracefulShutdown;
use Job::Async::Worker::Redis;

use IO::Socket::UNIX;
use JSON::MaybeUTF8 qw(encode_json_utf8 decode_json_utf8);
use DataDog::DogStatsd::Helper qw(stats_gauge stats_inc);
use Path::Tiny qw(path);
use Syntax::Keyword::Try;
use Time::Moment;
use Text::Trim;
use Path::Tiny;
use Try::Tiny;
use Time::HiRes qw(alarm);

use Getopt::Long;
use Log::Any qw($log);

use BOM::Config::RedisReplicated;
use BOM::RPC::JobTimeout;

use constant QUEUE_WORKER_TIMEOUT => 300;


=head1 NAME binary_jobqueue_worker.pl

RPC queue worker script. It can load multiple number of workers with the requested settings and manages their lifetime.

=head1 SYNOPSIS

    perl binary_jobqueue_worker.pl [--queue-prefix QA12] [--workers n] [--log=warn] [--socket /path/to/socket/file] [--redis redis://...]  [--testing] [--pid-file=/path/to/pid/file] [--foreground] 
    
=head1 DESCRIPTION

This script loads a number of queue worker processes and make them ready to accept ne requests.

=head1 OPTIONS

=over 8

=item B<--queue-prefix> or B<--q>

Sets a prefix to the redis keys processed by the queue. The default value is the runtime envirnoment name (QAxx, production, qa, ...). 
This way, a single redis instance can be configured to exchange messages for multiple rpc queues (each with it's own prefixe).

=item B<--workers> or B<--w>

The number of queue workers to be created with this script (default = 4). Workers will normally run in parallel as background processes.

=item B<--log> or B<--l>

The log level of the RPC queue which accepts one of the following values: info (default), warn, error, trace.

=item B<--socket> or B<--s>

The socket file for interacting with RPC queue service at runtime. It supports the fillowing commands:

=over 8

=item I<DEC_WORKERS>

Kills one of the existing queue workers and returns the number of remaining workers.

=item I<ADD_WORKERS>

Adds a new queue worker and returns resulting number of workers.

=item I<PING>

A command for testing if serice is up and running. Return B<PING> in response.

=item I<EXIT>

Exits the queue worker process immediately, befure terminating the exsting workers.

=back

=item B<--redis> or B<--r>

The connection string of the redis server prepared for the queue.


=item  B<--testing> or B<--t>

A value-less arg for telling that the rpc workers are being loaded from L<BOM::Test>.

=item B<pid-file> or B<s>

Path to file that should contain RPC queue process id after it is started up. It makes RPC queue compatible with L<BOM::Test::Script>, thus easier test development.

=item  B<--foreground> or B<--f>

This value-less arg tells queue script to load a single worker in foreground, mostly used for testing and easier log monitoring.


=back

=cut

use constant RESTART_COOLDOWN => 1;

my $redis_config = BOM::Config::RedisReplicated::redis_config('queue', 'write');

GetOptions(
    'testing|T'        => \my $TESTING,
    'foreground|f'     => \my $FOREGROUND,
    'workers|w=i'      => \(my $WORKERS = 4),
    'socket|S=s'       => \(my $SOCKETPATH = "/var/run/bom-rpc/binary_jobqueue_worker.sock"),
    'redis|R=s'        => \(my $REDIS = $redis_config->{uri}),
    'log|l=s'          => \(my $log_level = "info"),
    'queue-prefix|q=s' => \(my $queue_prefix = $ENV{JOB_QUEUE_PREFIX} // path('/etc/rmg/environment')->slurp_utf8),
    'pid-file=s' => \(my $PID_FILE),    #for BOM::Test::Script compatilibity
) or exit 1;

require Log::Any::Adapter;
Log::Any::Adapter->import(qw(Stderr), log_level => $log_level);

exit run_worker_process($REDIS) if $FOREGROUND;

# TODO: Should it live in /var/run/bom-daemon? That exists but I don't know
#   what it is
my $loop = IO::Async::Loop->new();

if (-S $SOCKETPATH) {
    # Try to connect first
    my $sock = IO::Socket::UNIX->new(
        Type => SOCK_STREAM,
        Peer => $SOCKETPATH,
    );
    takeover_coordinator($sock) if $sock;

    # Socket is now unused. It's safe to unlink it before
    # we try to start a new one
    unlink $SOCKETPATH
        or die "Cannot unlink $SOCKETPATH - $!\n";
}

unless (-d path($SOCKETPATH)->parent) {
    # ->mkpath will autodie on failure
    path($SOCKETPATH)->parent->mkpath;
}

my $sock = IO::Socket::UNIX->new(
    Type   => SOCK_STREAM,
    Local  => $SOCKETPATH,
    Listen => 1,
);
die "Cannot socket () - $!" unless $sock;

$loop->add(
    IO::Async::Listener->new(
        handle       => $sock,
        handle_class => "IO::Async::Stream",
        on_accept    => sub {
            my ($self, $conn) = @_;
            $conn->configure(
                on_read => sub {
                    my ($self, $buffref) = @_;
                    handle_ctrl_command($1, $conn) while $$buffref =~ s/^(.*?)\n//;
                    return 0;
                },
            );
            $self->add_child($conn);
        },
    ));
$log->debugf("Listening on control socket %s", $SOCKETPATH);

exit run_coordinator();

my %workers;

sub takeover_coordinator {
    my ($sock) = @_;

    $log->debug("Taking over existing socket");

    $loop->add(
        my $conn = IO::Async::Stream->new(
            handle  => $sock,
            on_read => sub { },    # entirely by Futures
        ));

    # We'll start a "prisoner exchange"; starting one worker for every one of
    # the previous process we shut down
    while (1) {
        add_worker_process($REDIS) if %workers < $WORKERS;

        $conn->write("DEC-WORKERS\n");
        my $result = $conn->read_until("\n")->retain;
        last if $result eq "WORKERS 0\n";
    }

    $conn->write("EXIT\n");
    $conn->close_when_empty;

    $log->debug("Takeover successful");
}

sub run_coordinator {
    add_worker_process($REDIS) while keys %workers < $WORKERS;
    $log->infof("%d Workers are running, processing queue on: %s", $WORKERS, $REDIS);

    $SIG{TERM} = $SIG{INT} = sub {
        $WORKERS = 0;
        $log->info("Terminating workers...");
        Future->needs_all(map { $_->shutdown('TERM', timeout => 15) } values %workers)->retain;

        unlink $SOCKETPATH;
        exit 0;
    };

    $loop->run;
}

sub handle_ctrl_command {
    my ($cmd, $conn) = @_;
    $log->debug("Control command> $cmd");

    my ($name, @args) = split ' ', $cmd;
    $name =~ s/-/_/g;
    if (my $code = __PACKAGE__->can("handle_ctrl_command_$name")) {
        $code->($conn, @args);
    } else {
        $log->debug("Ignoring unrecognised control command $cmd");
    }
}

sub handle_ctrl_command_DEC_WORKERS {
    my ($conn) = @_;

    $WORKERS = $WORKERS - 1;
    if (scalar(keys %workers) == 0) {
        $WORKERS = 0;
        $conn->write("WORKERS " . scalar(keys %workers) . "\n");
        return;
    }
    while (keys %workers > $WORKERS) {
        # Arbitrarily pick a victim
        warn 'DELETING WORKERS';
        my $worker_to_die = delete $workers{(keys %workers)[0]};
        $worker_to_die->shutdown('TERM', timeout => 15)->on_done(sub { $conn->write("WORKERS " . scalar(keys %workers) . "\n") })->retain;
    }
}

sub handle_ctrl_command_ADD_WORKERS {
    my ($conn, $redis) = @_;
    $conn->write('Error: redis arg was empty') unless $redis;

    $WORKERS += 1;
    add_worker_process($redis);
    $conn->write("WORKERS " . scalar(keys %workers) . "\n");
}

sub handle_ctrl_command_PING {
    my ($conn) = @_;

    $conn->write("PONG\n");
}

sub handle_ctrl_command_EXIT {
# Immediate exit; don't use the SIGINT shutdown part
    unlink $SOCKETPATH;
    exit 0;
}

sub add_worker_process {
    my $redis  = shift;
    my $worker = IO::Async::Process::GracefulShutdown->new(
        code => sub {
            undef $loop;
            undef $IO::Async::Loop::ONE_TRUE_LOOP;

            $log->debugf("[%d] worker process waiting", $$);
            $log->{context}{pid} = $$;
            return run_worker_process($redis);
        },
        on_finish => sub {
            my ($worker, $exitcode) = @_;
            my $pid = $worker->pid;

            $log->debugf("Worker %d exited code %d", $pid, $exitcode);

            delete $workers{$worker->pid};

            return if keys %workers >= $WORKERS;

            $log->debug("Restarting");

            $loop->delay_future(after => RESTART_COOLDOWN)->on_done(sub { add_worker_process($redis) })->retain;
        },
    );

    $loop->add($worker);
    $workers{$worker->pid} = $worker;
    $log->debugf("New worker started on redis: $redis");

    return $worker;
}

sub process_job {
    my %args = @_;

    my $job      = $args{job};
    my $tags     = $args{tags};
    my $code_sub = $args{code_sub};

    my $name = $job->data('name');

    my $current_time = Time::Moment->now;
    my $params       = decode_json_utf8($job->data('params'));

    stats_inc("rpc_queue.worker.jobs", $tags);

    # Handle a 'ping' request immediately here
    if ($name eq "ping") {
        $job->done(
            encode_json_utf8({
                    success => 1,
                    result  => 'pong'
                }));
        return;
    }

    $log->tracef("Running RPC <%s> for: %s", $name, $params);

    if (my $method = $code_sub) {
        my $result = $method->($params);
        $log->tracef("Results:\n%s", $result);

        $job->done(
            encode_json_utf8({
                    success => 1,
                    result  => $result
                })) unless $job->is_ready;
    } else {
        $log->errorf("Unknown rpc method: %s", $name);
        stats_inc("rpc_queue.worker.jobs.failed", $tags);
        # Transport mechanism itself succeeded, so ->done is fine here
        $job->done(
            encode_json_utf8({
                    success => 0,
                    result  => {
                        error => {
                            code              => 'InternalServerError',
                            message_to_client => 'Sorry, an error occurred while processing your request.',
                        }}})) unless $job->is_ready;
    }

    stats_gauge("rpc_queue.worker.jobs.latency", $current_time->delta_milliseconds(Time::Moment->now), $tags);

    return;
}

sub run_worker_process {
    my $redis = shift;
    my $loop  = IO::Async::Loop->new;

    require BOM::RPC::Registry;
    require BOM::RPC;    # This will load all the RPC methods into registry as a side-effect

    if ($TESTING) {
        # Running for a unit test; so start it up in test mode
        $log->debug("! Running in unit-test mode !");
        require BOM::Test;
        BOM::Test->import;

        require BOM::MT5::User::Async;
        no warnings 'once';
        @BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');

        Path::Tiny->new($PID_FILE)->spew("$$") if $PID_FILE;
    }

    $loop->add(
        my $worker = Job::Async::Worker::Redis->new(
            uri                 => $redis,
            max_concurrent_jobs => 1,
            timeout             => QUEUE_WORKER_TIMEOUT,
            $queue_prefix ? (prefix => $queue_prefix) : (),
        ));

    my $stopping;
    $loop->attach_signal(
        TERM => sub {
            return if $stopping++;
            unlink $PID_FILE if ($PID_FILE);
            $worker->stop->on_done(sub { exit 0; });
        });
    $SIG{INT} = 'IGNORE';

    my %services = map {
        my $method = $_->name;
        $method => {
            code_sub => BOM::RPC::wrap_rpc_sub($_),
            category => $_->category,
            }
    } BOM::RPC::Registry::get_service_defs();

    # Format:
    #   name=name of RPC
    #   id=string
    #   params=JSON-encoded arguments
    # Result: JSON-encoded result
    $worker->jobs->each(
        sub {
            my $job = $_;
            my $name = $job->data('name');
            my ($queue) = $worker->pending_queues;

            my $job_timeout = BOM::RPC::JobTimeout::get_timeout(category => $services{$name}{category});
            $log->tracef('Timeout for %s is %d', $name, $job_timeout);

            my $tags = {tags => ["rpc:$name", 'queue:' . $queue]};

            my $job_timeout = BOM::RPC::JobTimeout::get_timeout(category => $services{$name}{category});
            if (my $expire = $job->data('_expires')){
                my $expire_timeout = $expire - Time::HiRes::time();
                if ($expire_timeout > 0 && $expire_timeout < $job_timeout){
                    $job_timeout = $expire_timeout;
                    $log->tracef('Switched timeout to the queue client expire time %d', $job_timeout);
                }
                else {
                    $log->errorf('Job is aleardy expired at %d',$expire);
                    stats_inc("rpc_queue.worker.jobs.expire", $tags);
                    $job->fail('Job is expired');
                    return;
                }
            }

            $log->tracef('Timeout for %s is %d', $name, $job_timeout);

            try {
                local $SIG{ALRM} = sub {
                    stats_inc("rpc_queue.worker.jobs.timeout", $tags);
                    $log->errorf('rpc_queue: Timeout error - Not able to get response for %s job, job timeout is configured at %s seconds',
                        $name, $job_timeout);
                    $job->done(
                        encode_json_utf8({
                                success => 0,
                                result  => {
                                    error => {
                                        code              => 'RequestTimeout',
                                        message_to_client => "Request timed out.",
                                    }}}));
                };
                alarm $job_timeout;
                process_job(
                    job      => $job,
                    code_sub => $services{$name}{code_sub},
                    tags     => $tags
                );
                alarm 0;
            }
            catch {
                $log->errorf('An error occurred while processing job for %s, ERROR: %s', $name, $@);
            }
            finally {
                alarm 0;
            }
        });

    $worker->trigger->retain;
    $loop->run;
    return 0;    # exit code
}
