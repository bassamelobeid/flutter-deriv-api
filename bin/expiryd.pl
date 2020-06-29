#!/etc/rmg/bin/perl
use strict;
use warnings;

use Cache::RedisDB;
use ExpiryQueue qw( dequeue_expired_contract get_queue_id);
use Getopt::Long qw(GetOptions :config no_auto_abbrev no_ignore_case);

use List::Util qw(max);
use Time::HiRes;

use BOM::User::Client;
use BOM::Transaction;

STDOUT->autoflush(1);

GetOptions(
    't|threads_number=i' => \my $threads_number,
    'h|help'             => \my $help,
);

my $show_help = $help;
die <<"EOF" if ($show_help);
This daemon sells off expired contracts in soft real-time.
usage: $0 OPTIONS

These options are available:
  -t, --threads_number      Number of processes to spawn. Default value is 5
  -h, --help                Show this message.
EOF

$threads_number ||= 5;
die 'invalid number of processes' unless $threads_number > 0;

my @pids;

$SIG{INT} = $SIG{TERM} = sub {
    print("Terminating $$\n");
    kill TERM => @pids if (@pids);
    exit(0);
};

sub _daemon_run {
    print("Starting as PID $$\n");
    my $redis = Cache::RedisDB->redis;
    while (1) {
        my $now       = time;
        my $next_time = $now + 1;                     # we want this to execute every second
        my $iterator  = dequeue_expired_contract();
        # Outer `while` to live through possible redis disconnects/restarts
        while (my $info = $iterator->()) {            # Blocking for next available.
           eval {
                my @processing_start = Time::HiRes::time;
                my $contract_id      = $info->{contract_id};
                my $client           = BOM::User::Client->new({
                    loginid      => $info->{held_by},
                    db_operation => 'replica'
                });
                if ($info->{in_currency} ne $client->currency) {
                    warn(     'Skip on currency mismatch for contract '
                            . $contract_id
                            . '. Expected: '
                            . $info->{in_currency}
                            . ' Client uses: '
                            . $client->currency);
                    next;
                }
                # This returns a result which might be useful for reporting
                # but for now we will ignore it.
                my $is_sold = BOM::Transaction::sell_expired_contracts({
                        client        => $client,
                        source        => 2,               # app id for `Binary.com expiryd.pl` in auth db => oauth.apps table
                        contract_ids  => [$contract_id],
                        collect_stats => 1});
                
                my @processing_done = Time::HiRes::time;

                if (not $is_sold or $is_sold->{number_of_sold_bets} == 0) {
                    $info->{sell_failure}++;
                    my $cid = get_queue_id($info);
                    if ($info->{sell_failure} <= 5) {
                        my $future_epoch = $now + 2;
                        $redis->rpush('EXPIRYQUEUE::SELL_FAILURE_' . $future_epoch, $cid);
                    }
                }
            };    # No catch, let MtM pick up the pieces.
        }
        Time::HiRes::sleep(max(0, $next_time - Time::HiRes::time));
    }
}

print "parent $$ launching child processes\n";

for (my $i = 1; $i < $threads_number; $i++) {
    if(my $pid = fork // die 'unable to fork - ' . $!) {
        push @pids, $pid;
    } else {
        @pids = ();
        _daemon_run();
    }
}

print "parent $$ starts processing by himself";
_daemon_run();

