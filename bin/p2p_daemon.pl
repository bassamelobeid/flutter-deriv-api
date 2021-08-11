#!/usr/bin/env perl
use strict;
use warnings;
no indirect;

no indirect;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Net::Async::Redis;
use BOM::Platform::Event::Emitter;
use Time::HiRes;
use Getopt::Long;
use Log::Any qw($log);
use Syntax::Keyword::Try;
use Date::Utility;
use Path::Tiny qw(path);
use DataDog::DogStatsd::Helper qw(stats_inc);

use BOM::Config::Runtime;
use BOM::Config::Redis;

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

require Log::Any::Adapter;
GetOptions(
    'l|log=s'         => \my $log_level,
    'json_log_file=s' => \my $json_log_file,
) or die;

$log_level     ||= 'info';
$json_log_file ||= '/var/log/deriv/' . path($0)->basename . '.json.log';
Log::Any::Adapter->import(
    qw(DERIV),
    log_level     => $log_level,
    json_log_file => $json_log_file
);

=head1 Name

p2p_daemon - the daemon process operations which should happen at some particular.

=head1 Description

The Daemon checks database every established interval of time C<POLLING_INTERVAL> and
emits event for every order/advert, which state need to be updated.

=cut

use constant {
    # Seconds between each attempt at checking redis.
    POLLING_INTERVAL => 1,
    # Keys will be recreated with this number of seconds in future.
    # So if bom-events fails and does not delete them, the job will run again after this time.
    PROCESSING_RETRY => 30,
    # redis keys
    P2P_ORDER_DISPUTED_AT        => 'P2P::ORDER::DISPUTED_AT',
    P2P_ORDER_EXPIRES_AT         => 'P2P::ORDER::EXPIRES_AT',
    P2P_ORDER_TIMEDOUT_AT        => 'P2P::ORDER::TIMEDOUT_AT',
    P2P_ADVERTISER_BLOCK_ENDS_AT => 'P2P::ADVERTISER::BLOCK_ENDS_AT',
};

my $app_config = BOM::Config::Runtime->instance->app_config;
my $p2p_redis  = BOM::Config::Redis->redis_p2p_write();
my $loop       = IO::Async::Loop->new;
my $advert_subscriptions;
my $in_progress;    # Future to signal tick processing in progress

my $signal_handler = sub {
    $log->info('P2P daemon is shutting down');
    ($in_progress // Future->done)->on_done(sub { $loop->stop });
};
$loop->watch_signal(INT  => $signal_handler);
$loop->watch_signal(TERM => $signal_handler);

my $timer = IO::Async::Timer::Periodic->new(
    interval => POLLING_INTERVAL,
    on_tick  => \&on_tick,
);
$loop->add($timer);

my $tx_redis_config = BOM::Config::Redis::redis_config('transaction', 'read');

my $tx_redis = Net::Async::Redis->new(
    uri  => $tx_redis_config->{uri},
    auth => $tx_redis_config->{password},
);
$loop->add($tx_redis);

$log->info('P2P daemon is starting');

$tx_redis->connect->then(
    sub {
        $tx_redis->psubscribe('TXNUPDATE::transaction_*');
    }
)->then(
    sub {
        my ($sub) = @_;
        $sub->events->each(\&on_transaction);
    })->get;

$timer->start;
$loop->run;

=head2 on_tick

Fixed interval processing.

=cut

sub on_tick {
    $in_progress = $loop->new_future;
    $app_config->check_for_update;
    my $epoch_now = Date::Utility->new()->epoch;

    # We'll raise LC tickets when dispute reaches a given threshold in hours.
    my $dispute_threshold = Date::Utility->new->minus_time_interval(($app_config->payments->p2p->disputed_timeout // 24) . 'h')->epoch;

    $p2p_redis->multi;
    $p2p_redis->zrangebyscore(P2P_ORDER_DISPUTED_AT, '-Inf', $dispute_threshold, 'WITHSCORES');
    $p2p_redis->zremrangebyscore(P2P_ORDER_DISPUTED_AT, '-Inf', $dispute_threshold);
    my %dispute_timeouts = $p2p_redis->exec->[0]->@*;

    foreach my $payload (keys %dispute_timeouts) {
        # We store each member as P2P_ORDER_ID|BROKER_CODE
        my $timestamp = $dispute_timeouts{$payload};
        my ($order_id, $broker_code) = split(/\|/, $payload);

        BOM::Platform::Event::Emitter::emit(
            p2p_dispute_expired => {
                order_id    => $order_id,
                broker_code => $broker_code,
                timestamp   => $timestamp,
            });
        $log->debugf('Order %s dispute has timed out', $order_id);
    }
    undef %dispute_timeouts;

    # Advertiser blocks ended
    my $block_time = $epoch_now - 1;    # we wait for 1 second just in case db is not ready yet
    $p2p_redis->multi;
    $p2p_redis->zrangebyscore(P2P_ADVERTISER_BLOCK_ENDS_AT, '-Inf', $block_time);
    $p2p_redis->zremrangebyscore(P2P_ADVERTISER_BLOCK_ENDS_AT, '-Inf', $block_time);
    my @blocks_ending = $p2p_redis->exec->[0]->@*;

    for my $loginid (@blocks_ending) {
        BOM::Platform::Event::Emitter::emit(
            p2p_advertiser_updated => {
                client_loginid => $loginid,
            });
        $log->debugf('Block for %s has ended', $loginid);
    }

    # Expired orders
    my %expired         = $p2p_redis->zrangebyscore(P2P_ORDER_EXPIRES_AT, '-Inf', $epoch_now, 'WITHSCORES')->@*;
    my %expired_updates = map { ($epoch_now + PROCESSING_RETRY) => $_ } keys %expired;
    $p2p_redis->zadd(P2P_ORDER_EXPIRES_AT, %expired_updates) if %expired_updates;

    foreach my $payload (keys %expired) {
        # Payload is P2P_ORDER_ID|CLIENT_LOGINID
        my ($order_id, $client_loginid) = split(/\|/, $payload);

        BOM::Platform::Event::Emitter::emit(
            p2p_order_expired => {
                order_id       => $order_id,
                client_loginid => $client_loginid,
                expiry_started => [Time::HiRes::gettimeofday],
            });
        $log->debugf('Order %s for %s has expired', $order_id, $client_loginid);
    }

    $advert_subscriptions = {};
    my $channels = $p2p_redis->pubsub('channels', 'P2P::ADVERT::*');
    for my $channel (@$channels) {
        # channel format is advertiser_id::account_id::loginid::advert_id (we only need account_id)
        my ($advertiser_id, $account_id) = $channel =~ /P2P::ADVERT::(.+?)::(.+?)::.+?::.+?$/;
        push $advert_subscriptions->{$account_id}{channels}->@*, $channel;
        $advert_subscriptions->{$account_id}{advertiser_id} = $advertiser_id;
    }

    $in_progress->done;
}

=head2 on_transaction

Process transaction messages (account balance updates).

=cut

sub on_transaction {
    my $message      = shift;
    my ($account_id) = $message->channel =~ /TXNUPDATE::transaction_(.+)$/;
    my $subscription = $advert_subscriptions->{$account_id} or return;
    stats_inc('p2p.advertiser_adverts.transaction_update');
    $log->debugf('Transaction matches advertiser_adverts subscription on channel(s) %s', $subscription->{channels});
    BOM::Platform::Event::Emitter::emit(p2p_adverts_updated => $subscription);
}
