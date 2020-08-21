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

my $redis = BOM::Config::Redis->redis_p2p_write();
my $key_prefix = 'P2P::ADVERTISER_STATS';
my $expiry   = 120 * 24 * 60 * 60;  # keys expire in 120 days

my $cursor = 0;
do {
    my $res = $redis->scan($cursor, 'match', $key_prefix.'*');
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
    
    my $orders = $db->run(
        fixup => sub { 
            $_->selectall_arrayref("SELECT ROUND(EXTRACT(EPOCH FROM o.created_time)) created_time, 
                o.id, o.amount, o.status, o.client_loginid cli_loginid, adv.client_loginid adv_loginid, 
                ad.type advert_type, p2p.order_type(ad.type) order_type, 
                EXTRACT(EPOCH FROM buyconfirm.stamp)::BIGINT buy_confirm_time, 
                EXTRACT(EPOCH FROM cancel.stamp - o.created_time)::BIGINT cancel_time, 
                EXTRACT(EPOCH FROM complete.stamp - buyconfirm.stamp)::BIGINT release_time,
                p2p.is_status_final(o.status) is_complete
                FROM p2p.p2p_order o 
                    JOIN p2p.p2p_advert ad ON ad.id = o.advert_id 
                    JOIN p2p.p2p_advertiser adv on adv.id = ad.advertiser_id 
                    LEFT JOIN (SELECT id, stamp FROM audit.p2p_order where status = 'buyer-confirmed' ORDER BY stamp LIMIT 1) AS buyconfirm ON buyconfirm.id = o.id
                    LEFT JOIN (SELECT id, stamp FROM audit.p2p_order where status = 'cancelled' ORDER BY stamp LIMIT 1) AS cancel ON cancel.id = o.id
                    LEFT JOIN (SELECT id, stamp FROM audit.p2p_order where status = 'completed' ORDER BY stamp LIMIT 1) AS complete ON complete.id = o.id",
                {Slice => {}});
        
    });
    
    for my $order (@$orders) {
        my $item = $order->{id}.'|'.$order->{amount};
        my $adv_prefix = $key_prefix.'::'.$order->{adv_loginid};
        my $cli_prefix = $key_prefix.'::'.$order->{cli_loginid};

        $redis->hset($key_prefix . '::ORDER_CREATION_TIMES', $order->{id}, $order->{created_time}) unless $order->{is_complete};

        if ($order->{status} eq 'buyer-confirmed' && $order->{buy_confirm_time}) {
            $redis->hset($key_prefix . '::BUY_CONFIRM_TIMES', $order->{id}, $order->{buy_confirm_time});
        }
        
        if ($order->{status} eq 'completed') {
            
            $redis->hincrby($key_prefix . '::ORDER_COMPLETED_TOTAL', $order->{adv_loginid}, 1);
            $redis->hincrby($key_prefix . '::ORDER_COMPLETED_TOTAL', $order->{cli_loginid}, 1);
            
            my $adv_key = $adv_prefix.'::ORDER_COMPLETED::'.uc $order->{advert_type};
            $redis->zadd($adv_key, $order->{created_time}, $item);
            $redis->expire($adv_key, $expiry);
            
            my $cli_key = $cli_prefix.'::ORDER_COMPLETED::'.uc $order->{order_type};
            $redis->zadd($cli_key, $order->{created_time}, $item);
            $redis->expire($cli_key, $expiry);
                        
            if (defined $order->{release_time}) {
                my $prefix = $order->{order_type} eq 'sell' ? $cli_prefix : $adv_prefix;
                my $release_key  = $prefix . '::RELEASE_TIMES';
                my $release_item = $order->{id}.'|'.$order->{release_time};
                $redis->zadd($release_key, $order->{created_time}, $release_item);
                $redis->expire($release_key, $expiry);
            }
        }
        
        if ($order->{status} =~ /^(cancelled|refunded)$/) {
            my $adv_key = $adv_prefix.'::ORDER_REFUNDED::'.uc $order->{advert_type};
            $redis->zadd($adv_key, $order->{created_time}, $item);
            $redis->expire($adv_key, $expiry);
            
            my $cli_key = $cli_prefix.'::ORDER_REFUNDED::'.uc $order->{order_type};
            $redis->zadd($cli_key, $order->{created_time}, $item);
            $redis->expire($cli_key, $expiry);            
        }
        
        if ($order->{status} eq 'cancelled' && defined $order->{cancel_time}) {
            my $prefix = $order->{order_type} eq 'buy' ? $cli_prefix : $adv_prefix;
            my $release_key  = $prefix . '::CANCEL_TIMES';
            my $release_item = $order->{id}.'|'.$order->{cancel_time};
            $redis->zadd($release_key, $order->{created_time}, $release_item);
            $redis->expire($release_key, $expiry);
        }
        
    }
}
