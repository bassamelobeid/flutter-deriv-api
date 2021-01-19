#!/usr/bin/env perl
use strict;
use warnings;
no indirect;

no indirect;
use IO::Async::Loop;
use Future::AsyncAwait;
use BOM::Platform::Event::Emitter;
use Time::HiRes;
use Getopt::Long;
use Log::Any qw($log);
use Syntax::Keyword::Try;

use BOM::Config::Runtime;
use BOM::Config::Redis;
use Date::Utility;

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

require Log::Any::Adapter;
GetOptions('l|log=s' => \my $log_level) or die;

$log_level ||= 'info';

Log::Any::Adapter->import(qw(Stderr), log_level => $log_level);

=head1 Name

p2p_daemon - the daemon process operations which should happen at some particular.

=head1 Description

The Daemon checks database every established interval of time C<POLLING_INTERVAL> and
emits event for every order/advert, which state need to be updated.

=cut

# Seconds between each attempt at checking redis.
use constant POLLING_INTERVAL => 1;
# Keys will be recreated with this number of seconds in future.
# So if bom-events fails and does not delete them, the job will run again after this time.
use constant PROCESSING_RETRY => 30;
# redis keys
use constant P2P_ORDER_DISPUTED_AT => 'P2P::ORDER::DISPUTED_AT';
use constant P2P_ORDER_EXPIRES_AT  => 'P2P::ORDER::EXPIRES_AT';
use constant P2P_ORDER_TIMEDOUT_AT => 'P2P::ORDER::TIMEDOUT_AT';

my $app_config = BOM::Config::Runtime->instance->app_config;
my $loop     = IO::Async::Loop->new;
my $shutdown = $loop->new_future;
$shutdown->on_ready(sub {
    $log->info('Shut down');
});

my $signal_handler = sub {$shutdown->done};
$loop->watch_signal(INT  => $signal_handler);
$loop->watch_signal(TERM => $signal_handler);

my $redis = BOM::Config::Redis->redis_p2p_write();
my %dbs;
(async sub {
    $log->info('Starting P2P polling');
    until ($shutdown->is_ready) {
        $app_config->check_for_update;

        # Redis Polling
        # We'll raise LC tickets when dispute reaches a given threshold in hours.
        my $dispute_threshold = Date::Utility->new->minus_time_interval(($app_config->payments->p2p->disputed_timeout // 24).'h')->epoch;
        my %dispute_timeouts = $redis->zrangebyscore(P2P_ORDER_DISPUTED_AT, '-Inf', $dispute_threshold, 'WITHSCORES')->@*;
        $redis->zremrangebyscore(P2P_ORDER_DISPUTED_AT, '-Inf', $dispute_threshold);

        foreach my $payload (keys %dispute_timeouts) {
            # We store each member as P2P_ORDER_ID|BROKER_CODE
            my $timestamp = $dispute_timeouts{$payload};
            my ($order_id, $broker_core) = split(/\|/, $payload);

            BOM::Platform::Event::Emitter::emit(
                p2p_dispute_expired => {
                    order_id => $order_id,
                    broker_code  => $broker_core,
                    timestamp => $timestamp,
                });
        }
        undef %dispute_timeouts;
        
        # Expired orders
        my $expiry_threshold = Date::Utility->new()->epoch;
        my %expired = $redis->zrangebyscore(P2P_ORDER_EXPIRES_AT, '-Inf', $expiry_threshold, 'WITHSCORES')->@*;
        my %expired_updates = map { ( $expiry_threshold + PROCESSING_RETRY ) => $_ } keys %expired;
        $redis->zadd(P2P_ORDER_EXPIRES_AT, %expired_updates) if %expired_updates;
        
        foreach my $payload (keys %expired) {
            # Payload is P2P_ORDER_ID|CLIENT_LOGINID
            my ($order_id, $client_loginid) = split(/\|/, $payload);

            BOM::Platform::Event::Emitter::emit(
                p2p_order_expired => {
                    order_id => $order_id,
                    client_loginid  => $client_loginid,
                    expiry_started => [Time::HiRes::gettimeofday],
                });
        }
        
        # Orders that reached configured days after timeout
        my $timeout_threshold = Date::Utility->new->minus_time_interval($app_config->payments->p2p->refund_timeout.'d')->epoch;
        my %timedout = $redis->zrangebyscore(P2P_ORDER_TIMEDOUT_AT, '-Inf', $timeout_threshold, 'WITHSCORES')->@*;
        my %timedout_updates = map { ( $timeout_threshold + PROCESSING_RETRY ) => $_ } keys %timedout;
        $redis->zadd(P2P_ORDER_TIMEDOUT_AT, %timedout_updates) if %timedout_updates;
        
        foreach my $payload (keys %timedout) {
            # Payload is P2P_ORDER_ID|CLIENT_LOGINID
            my ($order_id, $client_loginid) = split(/\|/, $payload);

            BOM::Platform::Event::Emitter::emit(
                p2p_timeout_refund => {
                    order_id => $order_id,
                    client_loginid  => $client_loginid,
            });
        }

        await Future->wait_any(
            $loop->delay_future(after => POLLING_INTERVAL),
            $shutdown->without_cancel);
    }
})->()->get;
