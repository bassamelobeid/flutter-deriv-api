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
use Data::Dump 'pp';
use Syntax::Keyword::Try;
use Time::Moment;
use Text::Trim;

use Getopt::Long;
use Log::Any qw($log);

use BOM::Config::RedisReplicated;

my $redis_config = BOM::Config::RedisReplicated::redis_config('queue', 'write');

GetOptions(
    'testing|T'        => \my $TESTING,
    'foreground|f'     => \my $FOREGROUND,
    'workers|w=i'      => \(my $WORKERS = 4),
    'socket|S=s'       => \(my $SOCKETPATH = "/var/run/bom-rpc/binary_jobqueue_worker.sock"),
    'redis|R=s'        => \(my $REDIS = $redis_config->{uri}),
    'log|l=s'          => \(my $log_level = "info"),
    'queue-prefix|q=s' => \(my $queue_prefix = ''),
    'pid-file=s'       => \(my $PID_FILE),                                                      #for BOM::Test::Script compatilibity
) or exit 1;

require Log::Any::Adapter;
Log::Any::Adapter->import(qw(Stderr), log_level => $log_level);

exit run_worker_process($REDIS) if $FOREGROUND;

# TODO: This probably depends on a queue name which will come in as an a
#   commandline argument sometime
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
        my $result = $conn->read_until("\n")->get;
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
        Future->needs_all(map { $_->shutdown('TERM', timeout => 15) } values %workers)->get;

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
        $worker_to_die->shutdown('TERM', timeout => 15)->on_done(sub { $conn->write("WORKERS " . scalar(keys %workers) . "\n") })->get;
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

            $loop->delay_future(after => 1)->on_done(sub { add_worker_process($redis) })->retain;
        },
    );

    $loop->add($worker);
    $workers{$worker->pid} = $worker;
    $log->debugf("New worker started on redis: $redis");

    return $worker;
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

        if ($PID_FILE) {
            my $pid_file = Path::Tiny->new($PID_FILE);
            $pid_file->spew("$$");
        }
    }

    $loop->add(
        my $worker = Job::Async::Worker::Redis->new(
            uri                 => $redis,
            max_concurrent_jobs => 1,
            use_multi           => 1,
            timeout             => 5,
            prefix              => $queue_prefix,
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
        $method => BOM::RPC::wrap_rpc_sub($_)
    } BOM::RPC::Registry::get_service_defs();

    # Format:
    #   name=name of RPC
    #   id=string
    #   params=JSON-encoded arguments
    # Result: JSON-encoded result
    $worker->jobs->each(
        sub {
            my $job          = $_;
            my $current_time = Time::Moment->now;
            my $name         = $job->data('name');
            my $params       = decode_json_utf8($job->data('params'));

            my ($queue) = $worker->pending_queues;
            my $tags = {tags => ["rpc:$name", 'queue:' . $queue]};
            stats_inc("rpc_queue.worker.jobs", $tags);

            # Handle a 'ping' request immediately here
            if ($name eq "ping") {
                $_->done(
                    encode_json_utf8({
                            success => 1,
                            result  => 'pong'
                        }));
                return;
            }

            $log->tracef("Running RPC <%s> for: %s", $name, pp($params));

            if (my $code = $services{$name}) {
                my $result = $code->($params);
                $log->tracef("Results:\n%s", join("\n", map { " | $_" } split m/\n/, pp($result)));

                $_->done(
                    encode_json_utf8({
                            success => 1,
                            result  => $result
                        }));
            } else {
                $log->trace("  UNKNOWN");
                # Transport mechanism itself succeeded, so ->done is fine here
                $_->done(
                    encode_json_utf8({
                            success => 0,
                            error   => "Unknown RPC name '$name'"
                        }));
                stats_inc("rpc_queue.worker.jobs.failed", $tags);
            }

            stats_gauge("rpc_queue.worker.jobs.latency", $current_time->delta_milliseconds(Time::Moment->now), $tags);
        });

    $worker->trigger->retain;
    $loop->run;
    return 0;    # exit code
}
