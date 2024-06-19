use strict;
use warnings;
use BOM::Config::Redis;
use BOM::Database::ClientDB;
use LandingCompany::Registry;
use Getopt::Long;
use Date::Utility;
use List::Util qw(any);
use Log::Any::Adapter;
use Log::Any qw($log);
use BOM::Config::Runtime;

=head2 p2p_populate_advertiser_stats.pl

Manual script to regenerate specified P2P advertiser stats in redis for all P2P broker codes.
Existing stats will be replaced. Assumes no orders have been deleted from the db.

=cut

GetOptions('l|log=s' => \my $log_level);
Log::Any::Adapter->import(qw(DERIV), log_level => $log_level // 'info');

my %stats = map { $_ => 1 } @ARGV;

my %types = (
    complete_totals  => ['TOTAL_COMPLETED', 'BUY_COMPLETED', 'SELL_COMPLETED'],
    total_turnover   => ['TOTAL_TURNOVER'],
    completion_rates => ['BUY_COMPLETION', 'SELL_COMPLETION'],
    buy_times        => ['BUY_TIMES'],
    release_times    => ['BUY_CONFIRM_TIMES', 'RELEASE_TIMES'],
    cancellations    => ['CANCEL_TIMES',      'ORDER_CANCELLED'],
    partner_count    => ['ORDER_PARTNERS'],
);

if (not %stats or any { not exists $types{$_} } keys %stats) {
    my $desc = join "\n", map { '        - ' . $_ } sort keys %types;

    print qq/
Usage: 
    perl $0 stat stat ...
    
    Where a stat can be:
$desc
\n/;
    exit;
}

my $redis        = BOM::Config::Redis->redis_p2p_write();
my $key_prefix   = 'P2P::ADVERTISER_STATS';
my $expiry       = 120 * 24 * 60 * 60;                                                                           # keys expire in 120 days
my $grace_period = BOM::Config::Runtime->instance->app_config->payments->p2p->cancellation_grace_period * 60;    # config setting is in minutes

my @brokers = map { $_->{broker_codes}->@* } grep { $_->{p2p_available} } values LandingCompany::Registry::get_loaded_landing_companies()->%*;
my %orders;

for my $broker (@brokers) {
    my $db = BOM::Database::ClientDB->new({broker_code => $broker})->db->dbic;

    my $data = $db->run(
        fixup => sub {
            $_->selectall_arrayref(
                "SELECT DISTINCT ON (o.id) o.id, ROUND(EXTRACT(EPOCH FROM o.created_time)) created_at, 
                o.amount, o.status, 
                o.client_loginid AS client_loginid, adv.client_loginid AS advertiser_loginid,
                adv.id AS advertiser_id, cli_adv.id AS client_id,
                p2p.order_type(ad.type) AS order_type, 
                EXTRACT(EPOCH FROM buyconfirm.stamp)::BIGINT AS buy_confirm_at,
                EXTRACT(EPOCH FROM complete.stamp)::BIGINT AS complete_at,
                EXTRACT(EPOCH FROM refund.stamp)::BIGINT AS refund_at,
                EXTRACT(EPOCH FROM buyconfirm.stamp - o.created_time)::BIGINT AS buy_time,
                EXTRACT(EPOCH FROM complete.stamp - buyconfirm.stamp)::BIGINT AS release_time,
                EXTRACT(EPOCH FROM refund.stamp - o.created_time)::BIGINT AS cancel_time
                FROM p2p.p2p_order o 
                    JOIN p2p.p2p_advert ad ON ad.id = o.advert_id 
                    JOIN p2p.p2p_advertiser adv on adv.id = ad.advertiser_id
                    JOIN p2p.p2p_advertiser cli_adv on cli_adv.client_loginid = o.client_loginid
                    LEFT JOIN audit.p2p_order AS buyconfirm ON buyconfirm.status = 'buyer-confirmed' AND buyconfirm.id = o.id
                    LEFT JOIN audit.p2p_order AS refund ON refund.status IN ('cancelled','refunded','dispute-refunded') and refund.id = o.id
                    LEFT JOIN audit.p2p_order AS complete ON complete.status IN ('completed','dispute-completed') AND complete.id = o.id 
                    ORDER BY  o.id, complete_at, buy_confirm_at, refund_at",
                {Slice => {}});

        });

    $log->debugf('got %i orders from %s', scalar(@$data), $broker);

    # there should not be duplicate audit rows for a status, but just in case
    $orders{$broker . $_->{id}} = $_ for @$data;
}

# now we have data, delete existing keys
my $pattern = join '|', map { $types{$_}->@* } keys %stats;
my $cursor  = 0;
do {
    my $res = $redis->scan($cursor, 'match', $key_prefix . '*');
    $cursor = $res->[0];
    for my $key (grep { /::($pattern)$/ } $res->[1]->@*) {
        $log->debugf('deleting %s', $key);
        $redis->del($key);
    }
} while $cursor > 0;

for my $order (values %orders) {

    my ($id, $amount) = $order->@{qw/id amount/};
    my ($buyer, $seller) =
        $order->{order_type} eq 'buy'
        ? ($order->{client_loginid}, $order->{advertiser_loginid})
        : ($order->{advertiser_loginid}, $order->{client_loginid});
    my $buyer_prefix  = $key_prefix . '::' . $buyer;
    my $seller_prefix = $key_prefix . '::' . $seller;

    if ($stats{release_times} and $order->{status} eq 'buyer-confirmed' and $order->{buy_confirm_at}) {
        $log->debugf('setting BUY_CONFIRM_TIMES for order %i', $id);
        $redis->hset($key_prefix . '::BUY_CONFIRM_TIMES', $id, $order->{buy_confirm_at});
    }

    if ($stats{buy_times} and $order->{buy_confirm_at} and not any { $order->{status} eq $_ } ('dispute-refunded', 'dispute-completed')) {
        add_stat($buyer_prefix . '::BUY_TIMES', $order->{buy_confirm_at}, $id, $order->{buy_time});
    }

    if ($order->{status} =~ /^(completed|dispute-completed)$/) {
        # there is no fraud flag in the db, so we assume no fraud for these stats

        if ($stats{complete_totals}) {
            $log->debugf('incrementing TOTAL_COMPLETED for %s and %s by 1', $buyer, $seller);
            $redis->hincrby($key_prefix . '::TOTAL_COMPLETED', $buyer,  1);
            $redis->hincrby($key_prefix . '::TOTAL_COMPLETED', $seller, 1);

            add_stat($buyer_prefix . '::BUY_COMPLETED',   $order->{complete_at}, $id, $amount);
            add_stat($seller_prefix . '::SELL_COMPLETED', $order->{complete_at}, $id, $amount);
        }

        if ($stats{total_turnover}) {
            $log->debugf('incrementing TOTAL_TURNOVER for %s and %s by %s', $buyer, $seller, $amount);
            $redis->hincrbyfloat($key_prefix . '::TOTAL_TURNOVER', $buyer,  $amount);
            $redis->hincrbyfloat($key_prefix . '::TOTAL_TURNOVER', $seller, $amount);
        }

        if ($stats{completion_rates}) {
            add_stat($buyer_prefix . '::BUY_COMPLETION',   $order->{complete_at}, $id, 1);
            add_stat($seller_prefix . '::SELL_COMPLETION', $order->{complete_at}, $id, 1);
        }

        if ($stats{release_times} and defined $order->{release_time} and $order->{status} ne 'dispute-completed') {
            add_stat($seller_prefix . '::RELEASE_TIMES', $order->{complete_at}, $id, $order->{release_time});
        }

        if ($stats{partner_count}) {
            $log->debugf('setting ORDER_PARTNERS for %s and %s', $buyer, $seller);
            $redis->sadd(join('::', $key_prefix, $order->{client_loginid},     'ORDER_PARTNERS'), $order->{advertiser_id});
            $redis->sadd(join('::', $key_prefix, $order->{advertiser_loginid}, 'ORDER_PARTNERS'), $order->{client_id});
        }
    }

    if ($stats{completion_rates} and $order->{status} =~ /^(cancelled|refunded|dispute-refunded)$/) {
        add_stat($buyer_prefix . '::BUY_COMPLETION', $order->{refund_at}, $id, 0);
    }

    if ($stats{cancellations} and $order->{status} eq 'cancelled' and defined $order->{cancel_time}) {
        if ($order->{cancel_time} < $grace_period) {
            $log->debugf('order %i cancel time (%is) is within grace period (%is)', $id, $order->{cancel_time}, $grace_period);
            next;
        }
        add_stat($buyer_prefix . '::CANCEL_TIMES',    $order->{refund_at}, $id, $order->{cancel_time});
        add_stat($buyer_prefix . '::ORDER_CANCELLED', $order->{refund_at}, $id, $amount);
    }
}

sub add_stat {
    my ($key, $time, @items) = @_;
    my $val = join('|', @items);
    $log->debugf('adding to zset %s value %s', $key, $val);
    $redis->zadd($key, $time, $val);
    $redis->expire($key, $expiry);
}
