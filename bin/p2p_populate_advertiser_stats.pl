use strict;
use warnings;
use BOM::Config::Redis;
use BOM::Database::ClientDB;
use Date::Utility;
use feature 'say';

=head2 p2p_populate_advertiser_stats.pl

Manual script to regenrate all P2P advertiser stats in redis for all broker codes.
Existing stats will be regenerated. Assumes no orders have been deleted from the db.

=cut

my $redis      = BOM::Config::Redis->redis_p2p_write();
my $key_prefix = 'P2P::ADVERTISER_STATS';
my $expiry     = 120 * 24 * 60 * 60;                      # keys expire in 120 days

my $cursor = 0;
do {
    my $res = $redis->scan($cursor, 'match', $key_prefix . '*');
    $cursor = $res->[0];
    $redis->del($_) for $res->[1]->@*;
} while $cursor > 0;

my $collector_db = BOM::Database::ClientDB->new({
        broker_code => 'FOG',
        operation   => 'collector',
    })->db->dbic;

my $brokers = $collector_db->run(
    fixup => sub {
        return $_->selectcol_arrayref('SELECT * FROM betonmarkets.production_servers()');
    });

for my $broker (@$brokers) {
    say "processing $broker";
    my $db = BOM::Database::ClientDB->new({broker_code => uc $broker})->db->dbic;

    my $data = $db->run(
        fixup => sub {
            $_->selectall_arrayref(
                "SELECT ROUND(EXTRACT(EPOCH FROM o.created_time)) created_at, 
                o.id, o.amount, o.status, o.client_loginid cli_loginid, adv.client_loginid adv_loginid, 
                ad.type advert_type, p2p.order_type(ad.type) order_type, 
                EXTRACT(EPOCH FROM buyconfirm.stamp)::BIGINT buy_confirm_at,
                EXTRACT(EPOCH FROM complete.stamp)::BIGINT complete_at,
                EXTRACT(EPOCH FROM refund.stamp)::BIGINT refund_at, 
                EXTRACT(EPOCH FROM complete.stamp - buyconfirm.stamp)::BIGINT release_time,
                EXTRACT(EPOCH FROM refund.stamp - o.created_time)::BIGINT cancel_time,
                p2p.is_status_final(o.status) is_complete
                FROM p2p.p2p_order o 
                    JOIN p2p.p2p_advert ad ON ad.id = o.advert_id 
                    JOIN p2p.p2p_advertiser adv on adv.id = ad.advertiser_id 
                    LEFT JOIN audit.p2p_order AS buyconfirm ON buyconfirm.status = 'buyer-confirmed' AND buyconfirm.id = o.id
                    LEFT JOIN audit.p2p_order AS refund ON refund.status IN ('cancelled','refunded','dispute-refunded') and refund.id = o.id
                    LEFT JOIN audit.p2p_order AS complete ON complete.status IN ('completed','dispute-completed') AND complete.id = o.id",
                {Slice => {}});

        });

    # there should not be duplicate audit rows for a status, but just in case
    my %orders = map { $_->{id} => $_ } @$data;

    for my $order (values %orders) {
        my ($id, $amount) = $order->@{qw/id amount/};
        my ($buyer, $seller) =
            $order->{order_type} eq 'buy' ? ($order->{cli_loginid}, $order->{adv_loginid}) : ($order->{adv_loginid}, $order->{cli_loginid});
        my $buyer_prefix  = $key_prefix . '::' . $buyer;
        my $seller_prefix = $key_prefix . '::' . $seller;

        if ($order->{status} eq 'buyer-confirmed' && $order->{buy_confirm_at}) {
            $redis->hset($key_prefix . '::BUY_CONFIRM_TIMES', $id, $order->{buy_confirm_at});
        }

        if ($order->{status} =~ /^(completed|dispute-completed)$/) {
            $redis->hincrby($key_prefix . '::TOTAL_COMPLETED', $buyer,  1);
            $redis->hincrby($key_prefix . '::TOTAL_COMPLETED', $seller, 1);

            add_stat($buyer_prefix . '::BUY_COMPLETED',   $order->{complete_at}, $id, $amount);
            add_stat($seller_prefix . '::SELL_COMPLETED', $order->{complete_at}, $id, $amount);

            if ($order->{status} eq 'completed') {
                add_stat($buyer_prefix . '::BUY_COMPLETION',   $order->{complete_at}, $id, 1);
                add_stat($seller_prefix . '::SELL_COMPLETION', $order->{complete_at}, $id, 1);

                if (defined $order->{release_time}) {
                    add_stat($seller_prefix . '::RELEASE_TIMES', $order->{complete_at}, $id, $order->{release_time});
                }
            } else {
                # for dispute-completed, there is no fraud flag yet, so seller completion rate is always downgraded
                add_stat($buyer_prefix . '::BUY_COMPLETION',   $order->{complete_at}, $id, 1);
                add_stat($seller_prefix . '::SELL_COMPLETION', $order->{complete_at}, $id, 0);
            }

        }

        if ($order->{status} =~ /^(cancelled|refunded|dispute-refunded)$/) {
            add_stat($buyer_prefix . '::BUY_COMPLETION', $order->{refund_at}, $id, 0);
        }

        if ($order->{status} eq 'cancelled' && defined $order->{cancel_time}) {
            add_stat($buyer_prefix . '::CANCEL_TIMES',    $order->{refund_at}, $id, $order->{cancel_time});
            add_stat($buyer_prefix . '::ORDER_CANCELLED', $order->{refund_at}, $id, $amount);
        }
    }
}

sub add_stat {
    my ($key, $time, @items) = @_;
    $redis->zadd($key, $time, join('|', @items));
    $redis->expire($key, $expiry);
}
