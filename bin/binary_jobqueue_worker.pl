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

use Getopt::Long;
use Log::Any qw($log);
use Log::Any::Adapter qw(Stderr), log_level => 'info';

GetOptions(
    'testing|T'    => \my $TESTING,
    'foreground|f' => \my $FOREGROUND,
    'workers|w=i'  => \(my $WORKERS = 4),
    'socket|S=s'   => \(my $SOCKETPATH),
    'redis|R=s'    => \(my $REDIS),
    'pid-file|P=s' => \(my $pid_file),
) or exit 1;

exit run_worker_process() if $FOREGROUND;

# TODO: This probably depends on a queue name which will come in as an a
#   commandline argument sometime
# TODO: Should it live in /var/run/bom-daemon? That exists but I don't know
#   what it is
$SOCKETPATH //= "/var/run/bom-rpc/binary_jobqueue_worker.sock";

my $loop = IO::Async::Loop->new;

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
print STDERR "Listening on control socket $SOCKETPATH\n";

exit run_coordinator();

my %workers;

sub takeover_coordinator {
    my ($sock) = @_;

    print STDERR "Taking over existing socket\n";

    $loop->add(
        my $conn = IO::Async::Stream->new(
            handle  => $sock,
            on_read => sub { },    # entirely by Futures
        ));

    # We'll start a "prisoner exchange"; starting one worker for every one of
    # the previous process we shut down
    while (1) {
        add_worker_process() if %workers < $WORKERS;

        $conn->write("DEC-WORKERS\n");
        my $result = $conn->read_until("\n")->get;
        last if $result eq "WORKERS 0\n";
    }

    $conn->write("EXIT\n");
    $conn->close_when_empty;

    print STDERR "Takeover successful\n";
}

sub run_coordinator {
    add_worker_process() while keys %workers < $WORKERS;

    $SIG{TERM} = $SIG{INT} = sub {
        $WORKERS = 0;

        Future->needs_all(map { $_->shutdown('TERM', timeout => 15) } values %workers)->get;

        unlink $SOCKETPATH;
        unlink $pid_file if $pid_file;
        exit 0;
    };

    if ($pid_file) {
        $pid_file = Path::Tiny->new($pid_file);
        $pid_file->spew($$);
    }

    $loop->run;
}

sub handle_ctrl_command {
    my ($cmd, $conn) = @_;
    print STDERR "Control command> $cmd\n";

    $cmd =~ s/-/_/g;
    if (my $code = __PACKAGE__->can("handle_ctrl_command_$cmd")) {
        $code->($conn);
    } else {
        print STDERR "Ignoring unrecognised control command\n";
    }
}

sub handle_ctrl_command_DEC_WORKERS {
    my ($conn) = @_;

    $WORKERS--;
    while (keys %workers > $WORKERS) {
        # Arbitrarily pick a victim
        my $worker_to_die = delete $workers{(keys %workers)[0]};
        $worker_to_die->shutdown('TERM', timeout => 15)->on_done(sub { $conn->write("WORKERS " . scalar(keys %workers) . "\n") })->retain;
    }
}

sub handle_ctrl_command_EXIT {
# Immediate exit; don't use the SIGINT shutdown part
    exit 0;
}

sub add_worker_process {
    my $worker = IO::Async::Process::GracefulShutdown->new(
        code => sub {
            undef $loop;
            undef $IO::Async::Loop::ONE_TRUE_LOOP;

            print STDERR "[$$] worker process waiting\n";
            $log->{context}{pid} = $$;
            return run_worker_process();
        },
        on_finish => sub {
            my ($worker, $exitcode) = @_;
            my $pid = $worker->pid;

            print STDERR "Worker $pid exited code $exitcode\n";

            delete $workers{$worker->pid};

            return if keys %workers >= $WORKERS;

            print STDERR "Restarting\n";

            $loop->delay_future(after => 1)->on_done(sub { add_worker_process() })->retain;
        },
    );

    $loop->add($worker);
    $workers{$worker->pid} = $worker;
}

sub run_worker_process {
    my $loop = IO::Async::Loop->new;

    require BOM::RPC::Registry;
    require BOM::RPC;    # This will load all the RPC methods into registry as a side-effect

    if ($TESTING) {
        # Running for a unit test; so start it up in test mode
        print STDERR "! Running in unit-test mode !\n";
        require BOM::Test;
        BOM::Test->import;

        require BOM::MT5::User::Async;
        no warnings 'once';
        @BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');
    }

    $loop->add(
        my $worker = Job::Async::Worker::Redis->new(
            uri => $REDIS // 'redis://127.0.0.1',
            max_concurrent_jobs => 1,
            use_multi           => 1,
            timeout             => 5
        ));

    my $stopping;
    $loop->attach_signal(
        TERM => sub {
            return if $stopping++;
            $worker->stop->on_done(sub { exit 0; })->retain;
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
            my $job    = $_;
            my $name   = $job->data('name');
            my $params = decode_json_utf8($job->data('params'));

            my $queue_time = $job->data('rpc_queue_client_tv');
            my ($queue)    = $worker->pending_queues;
            my $tags       = {tags => ["method:$name", 'queue:' . $queue]};    #TODO: replace with a more reliable value
            stats_gauge('rpc_queue.worker.length', scalar(keys($worker->{pending_jobs}->%*)), $tags);
            stats_inc("rpc_queue.worker.calls", $tags);
            stats_gauge("rpc_queue.client.latency", 1000 * Time::HiRes::tv_interval($queue_time), $tags) if $queue_time;

            # Handle a 'ping' request immediately here
            if ($name eq "ping") {
                $_->done(
                    encode_json_utf8({
                            success => 1,
                            result  => 'pong'
                        }));
                return;
            }

            print STDERR "Running RPC <$name> for:\n" . pp($params) . "\n";

            if (my $code = $services{$name}) {
                my $result = $code->($params);
                print STDERR "Result:\n" . join("\n", map { " | $_" } split m/\n/, pp($result)) . "\n";

                $_->done(
                    encode_json_utf8({
                            success => 1,
                            result  => $result
                        }));
            } else {
                print STDERR "  UNKNOWN\n";
                # Transport mechanism itself succeeded, so ->done is fine here
                $_->done(
                    encode_json_utf8({
                            success => 0,
                            error   => "Unknown RPC name '$name'"
                        }));
            }
        });

    $worker->trigger;
    $loop->run;

    return 0;    # exit code
}
