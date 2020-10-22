#!/usr/bin/env perl
use strict;
use warnings;
no indirect;

no indirect;
use IO::Async::Loop;
use Future::AsyncAwait;
use BOM::Platform::Event::Emitter;
use LandingCompany::Registry;
use BOM::Database::ClientDB;
use Time::HiRes;
use Getopt::Long;
use Log::Any qw($log);
use List::Util qw(uniq);
use Syntax::Keyword::Try;

use BOM::Config::Runtime;
use BOM::Platform::Context qw(request);
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

# Seconds between each attempt at checking the database entries.
use constant POLLING_INTERVAL => 60;
use constant P2P_ORDER_DISPUTED_AT => 'P2P::ORDER::DISPUTED_AT';
use constant ONE_HOUR_IN_SECONDS => 3600;

# request brand name should be changed to 'deriv', otherwise the event will not be sent to Segment.
request(BOM::Platform::Context::Request->new(
    brand_name => 'deriv'
));

my @broker_codes = uniq map { $_->{broker_codes}->@* } grep { $_->{p2p_available} } values LandingCompany::Registry::get_loaded_landing_companies()->%*;
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
        my $dispute_threshold = Date::Utility->new()->epoch - ONE_HOUR_IN_SECONDS * ($app_config->payments->p2p->disputed_timeout // 24);
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

        # Database Polling
        for my $broker (@broker_codes) {
            try {
                $dbs{$broker} //= BOM::Database::ClientDB->new({broker_code => $broker})->db->dbh;
            }
            catch {
                $log->warnf('Fail to connect to client db %s: %s', $broker, $@);
            }
            next unless $dbs{$broker};
            # Stop quering db when feature is disabled
            last if $app_config->system->suspend->p2p || !$app_config->payments->p2p->enabled;
            $log->debug('P2P: Checking for expired orders');
            try {
                my $orders = $dbs{$broker}->selectall_arrayref('SELECT id, client_loginid FROM p2p.order_list_expired()', {Slice => {}});
                
                for my $order (@$orders) {
                    $log->debugf('P2P: Emitting event to mark order as expired for order %s', $order->{id});

                    BOM::Platform::Event::Emitter::emit(
                        p2p_order_expired => {
                            client_loginid => $order->{client_loginid},
                            order_id       => $order->{id},
                            expiry_started => [Time::HiRes::gettimeofday],
                        });
                }
            }
            catch ($error) {
                $log->warnf('Failed to get expired P2P orders from client db %s: %s', $broker, $error);
                delete $dbs{$broker};
            }
            next unless $dbs{$broker};
            $log->debug('P2P: Checking for ready to refund orders');
            try {
                # The days needed to reach the refund are dynamically configured (default 30 days)
                my $days_to_refund = $app_config->payments->p2p->refund_timeout;
                my $sth = $dbs{$broker}->prepare('SELECT id, client_loginid FROM p2p.order_list_refundable(?)');
                $sth->execute($days_to_refund);

                while (my $order_data = $sth->fetchrow_hashref) {
                    $log->debugf('P2P: Emitting event to move funds back, order %s', $order_data->{id});
                    BOM::Platform::Event::Emitter::emit(
                        p2p_timeout_refund => {
                            client_loginid => $order_data->{client_loginid},
                            order_id       => $order_data->{id},
                        });
                }
            }
            catch ($error) {
                $log->warnf('Failed to get expired P2P orders from client db %s: %s', $broker, $error);
                delete $dbs{$broker};
            }
        }

        await Future->wait_any(
            $loop->delay_future(after => POLLING_INTERVAL),
            $shutdown->without_cancel);
    }
})->()->get;
