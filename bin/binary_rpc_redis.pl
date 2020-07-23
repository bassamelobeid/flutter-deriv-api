#!/etc/rmg/bin/perl

use strict;
use warnings;

use Getopt::Long;
use Net::Domain qw( hostname );
use Parallel::ForkManager;
use Pod::Usage;
use Log::Any::Adapter qw( Stderr ), log_level => $ENV{BOM_LOG_LEVEL} // 'info';
use Log::Any qw( $log );

use BOM::RPC::Transport::Redis;
use BOM::Config::Redis;

=head1 NAME binary_rpc_redis.pl

The RPC synchronized queue worker script.

=head1 SYNOPSIS

    perl binary_rpc_redis.pl [--redis redis://...]  [--category platform-details] [--host rpc01]
    
=head1 DESCRIPTION

This script will consumes requests which are provided
as messages over Redis stream, trying to dispatch 
the requests and respond to them synchronously.

=head1 OPTIONS

=over 4

=item C<--redis> or C<-r>

The connection string of the related Redis server.

=item C<--category> or C<-c>

The category of actions which this worker bounds to handle.

=item C<--host> or C<-m>

Optional. The host/machine name; default is machine's name

=item C<--workers> or C<-w>

Optional. The number of workers; default is 1

=item C<--help> or C<-h>

More information

=back

=cut

my $redis_config = BOM::Config::Redis::redis_config('rpc', 'write');

GetOptions(
    'category|c=s' => \(my $category   = 'general'),
    'host|m=s'     => \(my $host       = hostname),
    'redis|r=s'    => \(my $redis_uri  = $redis_config->{uri}),
    'workers|w=i'  => \(my $workers_no = 1),
    'help|h'       => \my $more_info,
) or pod2usage({-verbose => 1});

pod2usage({
        -verbose  => 99,
        -sections => "NAME|SYNOPSIS|DESCRIPTION|OPTIONS"
    }) if $more_info;

$log->infof('Start consuming from `%s` stream using `%d` workers.', $category, $workers_no);

my @workers = (0) x $workers_no;

my $fm = Parallel::ForkManager->new($workers_no);

local $SIG{TERM} = local $SIG{INT} = sub {
    my @forks = grep { $_ != 0 } @workers;
    local $SIG{ALRM} = sub {
        print "Graceful shutting down timeout has been reached. All child processes are forcefully killed.\n";
        kill KILL => @forks;
        exit 1;
    };

    kill TERM => @forks;
    print "Shutting Down...\n";
    alarm 5;
    $fm->wait_all_children;
    exit 1;
};

$fm->run_on_start(
    sub {
        srand;    #seed random generator
        my $pid = shift;
        my ($index) = grep { $workers[$_] == 0 } 0 .. $#workers;
        $workers[$index] = $pid;
    });
$fm->run_on_finish(
    sub {
        my ($pid, $exit_code) = @_;
        for my $index (0 .. $#workers) {
            if ($workers[$index] == $pid) {
                $workers[$index] = 0;
                last;
            }
        }
    });

while (1) {
    my $pid = $fm->start and next;
    my ($index) = grep { $workers[$_] == $pid } 0 .. $#workers;

    my $consumer = BOM::RPC::Transport::Redis->new(
        pid          => $pid,
        worker_index => $index,
        category     => $category,
        host         => $host,
        redis_uri    => $redis_uri,
    );

    $consumer->run();

    $fm->finish;
}
