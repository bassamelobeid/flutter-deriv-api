package BOM::User::Script::P2PDaemon;

use strict;
use warnings;
no indirect;

use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Net::Async::Redis;
use Time::HiRes qw(gettimeofday tv_interval);
use Log::Any    qw($log);
use Date::Utility;
use DataDog::DogStatsd::Helper qw(stats_inc stats_timing stats_gauge);
use List::Util                 qw(uniq);
use curry::weak;

use BOM::Config::Runtime;
use BOM::Config::Redis;
use BOM::Platform::Event::Emitter;

use constant {
    # Seconds between each attempt at checking redis.
    POLLING_INTERVAL => 1,
    # Keys will be recreated with this number of seconds in future.
    # So if bom-events fails and does not delete them, the job will run again after this time.
    PROCESSING_RETRY => 30,
    # redis keys
    P2P_ORDER_EXPIRES_AT          => 'P2P::ORDER::EXPIRES_AT',
    P2P_ORDER_TIMEDOUT_AT         => 'P2P::ORDER::TIMEDOUT_AT',
    P2P_ORDER_DISPUTED_AT         => 'P2P::ORDER::DISPUTED_AT',
    P2P_ADVERTISER_BLOCK_ENDS_AT  => 'P2P::ADVERTISER::BLOCK_ENDS_AT',
    P2P_USERS_ONLINE              => 'P2P::USERS_ONLINE',
    P2P_USERS_ONLINE_LATEST       => 'P2P::USERS_ONLINE_LATEST',
    P2P_ONLINE_PERIOD             => 90,
    P2P_ORDER_REVIEWABLE_START_AT => 'P2P::ORDER::REVIEWABLE_START_AT',
    P2P_VERIFICATION_EVENT_KEY    => 'P2P::ORDER::VERIFICATION_EVENT',
};

=head1 Name

P2PDailyDaemon - realtime processing of various P2P tasks.

=head2 new

Constructor

=cut

sub new {
    my $class = shift;

    return bless {
        app_config => BOM::Config::Runtime->instance->app_config,
        p2p_redis  => BOM::Config::Redis->redis_p2p_write(),
        loop       => IO::Async::Loop->new,
    }, $class;
}

=head2 run

Runs loop

=cut

sub run {
    my ($self) = @_;

    $log->info('P2P daemon is starting');

    my $loop = $self->{loop};

    my $signal_handler = sub {
        $log->info('P2P daemon is shutting down');
        ($self->{in_progress} // Future->done)->on_done(sub { $loop->stop });
    };
    $loop->watch_signal(INT  => $signal_handler);
    $loop->watch_signal(TERM => $signal_handler);

    my $timer_sec = IO::Async::Timer::Periodic->new(
        on_tick        => $self->curry::weak::on_sec,
        interval       => 1,
        first_interval => tv_interval([gettimeofday], [time + 1]),
        reschedule     => 'hard',
    );

    $loop->add($timer_sec);

    my $timer_min = IO::Async::Timer::Periodic->new(
        on_tick        => $self->curry::weak::on_min,
        interval       => 60,
        first_interval => tv_interval([gettimeofday], [(int(time / 60) + 1) * 60]),
        reschedule     => 'hard',
    );

    $loop->add($timer_min);

    my $tx_redis_config = BOM::Config::Redis::redis_config('transaction', 'read');

    my $tx_redis = Net::Async::Redis->new(
        uri  => $tx_redis_config->{uri},
        auth => $tx_redis_config->{password},
    );
    $loop->add($tx_redis);

    $tx_redis->connect->then(
        sub {
            $tx_redis->psubscribe('TXNUPDATE::transaction_*');
        }
    )->then(
        sub {
            my ($sub) = @_;
            $sub->events->each($self->curry::weak::on_transaction);
        })->get;

    $timer_sec->start;
    $timer_min->start;
    $loop->run;
    return 0;
}

=head2 on_sec

Per second processing.

=cut

sub on_sec {
    my ($self) = @_;

    if ($self->{in_progress} and not $self->{in_progress}->is_done) {
        $log->warn('Skpping interval because processing took too long');
        return;
    }

    my $start_tv = [gettimeofday];
    $self->{in_progress} = $self->{loop}->new_future;
    $self->{app_config}->check_for_update;
    $self->process_expired_orders;
    $self->refund_timedout_orders;
    $self->process_disputes;
    $self->process_advertiser_blocks_ending;
    $self->find_active_ad_subscriptions;
    $self->process_advertisers_online;
    $self->notify_unreviewable_orders;
    $self->process_verification_events;

    $self->{in_progress}->done;
    stats_timing('p2p.daemon.processing_time_sec', 1000 * tv_interval($start_tv));
}

=head2 on_min

Per minute processing.

=cut

sub on_min {
    my ($self) = @_;

    my $start_tv = [gettimeofday];

    $self->update_local_currencies;

    stats_timing('p2p.daemon.processing_time_min', 1000 * tv_interval($start_tv));
}

=head2 process_expired_orders

Fires a p2p_order_expired event when an order expiry time is reached.

=cut

sub process_expired_orders {
    my ($self) = @_;

    my $redis = $self->{p2p_redis};

    my %expired         = $redis->zrangebyscore(P2P_ORDER_EXPIRES_AT, '-Inf', time, 'WITHSCORES')->@*;
    my @expired_updates = map { (time + PROCESSING_RETRY, $_) } keys %expired;
    $redis->zadd(P2P_ORDER_EXPIRES_AT, @expired_updates) if @expired_updates;

    foreach my $payload (keys %expired) {
        # Payload is P2P_ORDER_ID|CLIENT_LOGINID
        my ($order_id, $client_loginid) = split(/\|/, $payload);

        BOM::Platform::Event::Emitter::emit(
            p2p_order_expired => {
                order_id       => $order_id,
                client_loginid => $client_loginid,
            });
        $log->debugf('Order %s for %s has expired', $order_id, $client_loginid);
    }
}

=head2 refund_timedout_orders

Fires a p2p_timeout_refund event when configured days pass after an order became timed_out.

=cut

sub refund_timedout_orders {
    my ($self) = @_;

    my $timeout_threshold = Date::Utility->new->minus_time_interval($self->{app_config}->payments->p2p->refund_timeout . 'd')->epoch;
    my $redis             = $self->{p2p_redis};

    my %timedout         = $redis->zrangebyscore(P2P_ORDER_TIMEDOUT_AT, '-Inf', $timeout_threshold, 'WITHSCORES')->@*;
    my @timedout_updates = map { ($timeout_threshold + PROCESSING_RETRY, $_) } keys %timedout;
    $redis->zadd(P2P_ORDER_TIMEDOUT_AT, @timedout_updates) if @timedout_updates;

    foreach my $payload (keys %timedout) {
        # Payload is P2P_ORDER_ID|CLIENT_LOGINID
        my ($order_id, $client_loginid) = split(/\|/, $payload);

        BOM::Platform::Event::Emitter::emit(
            p2p_timeout_refund => {
                order_id       => $order_id,
                client_loginid => $client_loginid,
            });
        $log->debugf('Order %s for %s has reached timeout refund', $order_id, $client_loginid);
    }
}

=head2 process_disputes

Fires p2p_dispute_expired event when configured time passes after a order dispute was created.

=cut

sub process_disputes {
    my ($self) = @_;

    my $dispute_threshold = Date::Utility->new->minus_time_interval(($self->{app_config}->payments->p2p->disputed_timeout // 24) . 'h')->epoch;
    my $redis             = $self->{p2p_redis};

    $redis->multi;
    $redis->zrangebyscore(P2P_ORDER_DISPUTED_AT, '-Inf', $dispute_threshold, 'WITHSCORES');
    $redis->zremrangebyscore(P2P_ORDER_DISPUTED_AT, '-Inf', $dispute_threshold);
    my %dispute_timeouts = $redis->exec->[0]->@*;

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
}

=head2 process_advertiser_blocks_ending

Fires a p2p_advertiser_updated event when an advertiser temp ban ends.

=cut

sub process_advertiser_blocks_ending {
    my ($self) = @_;

    my $block_time = time - 1;             # we wait for 1 second just in case db is not ready yet
    my $redis      = $self->{p2p_redis};

    $redis->multi;
    $redis->zrangebyscore(P2P_ADVERTISER_BLOCK_ENDS_AT, '-Inf', $block_time);
    $redis->zremrangebyscore(P2P_ADVERTISER_BLOCK_ENDS_AT, '-Inf', $block_time);
    my @blocks_ending = $redis->exec->[0]->@*;

    for my $loginid (@blocks_ending) {
        BOM::Platform::Event::Emitter::emit(
            p2p_advertiser_updated => {
                client_loginid => $loginid,
            });
        $log->debugf('Block for %s has ended', $loginid);
    }
}

=head2 find_active_ad_subscriptions

Checks for active p2p_advert_info subscriptions.

=cut

sub find_active_ad_subscriptions {
    my ($self) = @_;

    $self->{advert_subscriptions} = {};

    my $channels = $self->{p2p_redis}->pubsub('channels', 'P2P::ADVERT::*');
    for my $channel (@$channels) {
        # channel format is advertiser_id::account_id::loginid::advert_id (we only need account_id)
        my ($advertiser_id, $account_id) = $channel =~ /P2P::ADVERT::(.+?)::(.+?)::.+?::.+?$/;
        push $self->{advert_subscriptions}{$account_id}{channels}->@*, $channel;
        $self->{advert_subscriptions}{$account_id}{advertiser_id} = $advertiser_id;
    }
}

=head2 process_advertisers_online

Uses redis pubsub to find all active advert subscriptions.

=cut

sub process_advertisers_online {
    my ($self) = @_;

    my $redis = $self->{p2p_redis};

    my @current  = $redis->zrangebyscore(P2P_USERS_ONLINE, time - P2P_ONLINE_PERIOD, '+Inf')->@*;
    my @previous = split /\|/, $redis->get(P2P_USERS_ONLINE_LATEST) // '';
    $redis->set(P2P_USERS_ONLINE_LATEST, join '|', @current);
    if (@current) {
        my %counter;
        my @countries_list = map { $_ =~ /::(\w+?)$/ } @current;
        $counter{$_}++ for @countries_list;
        stats_gauge('p2p.user_online.country.count', $counter{$_}, {tags => ['country:' . $_]}) foreach keys %counter;
    }

    # this seems the fastest way to get the difference (tried a few ways)
    my (%new_online, %new_offline);
    @new_online{@current}   = ();
    @new_offline{@previous} = ();
    delete @new_online{@previous};
    delete @new_offline{@current};

    $log->debugf('users new online: %s',  [keys %new_online])  if %new_online;
    $log->debugf('users new offline: %s', [keys %new_offline]) if %new_offline;

    foreach my $loginid (uniq map { $_ =~ /^(\w+?)::/ } keys %new_online, keys %new_offline) {
        BOM::Platform::Event::Emitter::emit(p2p_advertiser_online_status => {client_loginid => $loginid});
    }
}

=head2 notify_unreviewable_orders

Find orders whose review period just ended

=cut

sub notify_unreviewable_orders {
    my ($self) = @_;

    my $redis = $self->{p2p_redis};

    my $review_expiry = time - ($self->{app_config}->payments->p2p->review_period * 60 * 60) - 5;    # wait for 5 seconds
    $redis->multi;
    $redis->zrangebyscore(P2P_ORDER_REVIEWABLE_START_AT, '-Inf', $review_expiry);
    $redis->zremrangebyscore(P2P_ORDER_REVIEWABLE_START_AT, '-Inf', $review_expiry);
    my @expired_review_orders = $redis->exec->[0]->@*;

    for my $item (@expired_review_orders) {
        # Item is P2P_ORDER_ID|CLIENT_LOGINID
        my ($order_id, $loginid) = split(/\|/, $item);
        BOM::Platform::Event::Emitter::emit(
            p2p_order_updated => {
                order_id       => $order_id,
                client_loginid => $loginid,
                self_only      => 1,
            });
        $log->debugf('Review period for %s on order %s has ended', $loginid, $order_id);
    }
}

=head2 process_verification_events

Processes multiple events related to order verification which result in order updates.

=cut

sub process_verification_events {
    my ($self) = @_;

    my $redis = $self->{p2p_redis};

    $redis->multi;
    $redis->zrangebyscore(P2P_VERIFICATION_EVENT_KEY, '-Inf', time);
    $redis->zremrangebyscore(P2P_VERIFICATION_EVENT_KEY, '-Inf', time);
    my @items = $redis->exec->[0]->@*;

    for my $item (@items) {
        # Item is EVENT|P2P_ORDER_ID|SELLER_LOGINID
        my ($event, $order_id, $loginid) = split(/\|/, $item);

        next unless ($event // '') =~ /^(REQUEST_BLOCK|TOKEN_VALID|LOCKOUT)$/;

        # update for REQUEST_BLOCK ending should only be sent to the seller
        BOM::Platform::Event::Emitter::emit(
            p2p_order_updated => {
                order_id       => $order_id,
                client_loginid => $loginid,
                self_only      => $event eq 'REQUEST_BLOCK' ? 1 : 0,
            });

        $log->debugf('Processed and removed verification item %s on order %s', $event, $order_id);
    }
}

=head2 update_local_currencies

Sends event to update available local currencies.

=cut

sub update_local_currencies {
    BOM::Platform::Event::Emitter::emit(p2p_update_local_currencies => {});
}

=head2 on_transaction

Process transaction messages (account balance updates).

=cut

sub on_transaction {
    my ($self, $message) = @_;

    my ($account_id) = $message->channel =~ /TXNUPDATE::transaction_(.+)$/;
    my $subscription = $self->{advert_subscriptions}{$account_id} or return;
    stats_inc('p2p.advertiser_adverts.transaction_update');
    $log->debugf('Transaction matches advertiser_adverts subscription on channel(s) %s', $subscription->{channels});
    BOM::Platform::Event::Emitter::emit(p2p_adverts_updated => $subscription);
}

1;
