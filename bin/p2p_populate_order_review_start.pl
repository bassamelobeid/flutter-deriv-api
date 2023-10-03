use strict;
use warnings;

use BOM::Config::Redis;
use BOM::Config::Runtime;
use BOM::Database::ClientDB;
use LandingCompany::Registry;

use Log::Any qw($log);
use Log::Any::Adapter ('DERIV', log_level => 'debug');

=head2 p2p_populate_order_review_start

Manual script to populate order completion time for completed orders that will be be used 
in P2PDaemon to emit p2p_order_updated event when order review validity period expires

NEED TO RUN THIS ON THE SAME DAY AS WHEN REDIS DATA IS LOST!

Why we need to use expire_time in the first CTE?
- LET $order_review_period => X and $refund_timeout_period => Y
- For the order to be still eligible for review, it must be 'completed' at most X hours ago (let's call this time Z)
- If order is 'completed' at Z, the earliest time it could have expired is Z - (Y days) ago
- This is because 'timed-out' orders still have chance to confirmed by seller ('completed') for the next Y days
- We use (Y+1) just to be extra sure that we don't miss out any orders

=cut

use constant {
    P2P_ORDER_REVIEWABLE_START_AT => 'P2P::ORDER::REVIEWABLE_START_AT',
};

my $p2p_redis             = BOM::Config::Redis->redis_p2p_write();
my $order_review_period   = BOM::Config::Runtime->instance->app_config->payments->p2p->review_period;
my $refund_timeout_period = BOM::Config::Runtime->instance->app_config->payments->p2p->refund_timeout + 1;
my @brokers = map { $_->{broker_codes}->@* } grep { $_->{p2p_available} } values LandingCompany::Registry::get_loaded_landing_companies()->%*;
my @orders;

for my $broker (@brokers) {
    my $db = BOM::Database::ClientDB->new({broker_code => $broker})->db->dbic;

    my $data = $db->run(
        fixup => sub {
            $_->selectall_arrayref(
                "WITH completed_orders AS (
                    SELECT id, advert_id, client_loginid AS order_creator
                    FROM p2p.p2p_order
                      WHERE STATUS = 'completed'
                        AND expire_time >= (NOW() - INTERVAL ? DAY - INTERVAL ? HOUR)
                ),
                
                recent_completed_orders AS (
                    SELECT co.*, EXTRACT(EPOCH FROM tx_complete.transaction_time)::BIGINT AS stamp
                    FROM completed_orders AS co
                    JOIN p2p.p2p_transaction AS tx_complete ON (tx_complete.order_id = co.id AND tx_complete.type = 'order_complete_payment')
                      WHERE tx_complete.transaction_time + INTERVAL ? HOUR > NOW()
                ),

                pending_review_orders AS (
                    SELECT rco.*
                    FROM recent_completed_orders AS rco
                    LEFT JOIN p2p.p2p_order_review AS review on rco.id = review.order_id
                      WHERE review.rating IS NULL
                )

                SELECT pro.id as order_id, pro.order_creator, pro.stamp, adv.client_loginid as ad_creator
                FROM pending_review_orders as pro
                JOIN p2p.p2p_advert AS ad ON (pro.advert_id = ad.id)
                JOIN p2p.p2p_advertiser AS adv ON (ad.advertiser_id = adv.id)",
                {Slice => {}}, $refund_timeout_period, $order_review_period, $order_review_period
            );

        });

    $log->debugf('%s: %i completed orders are pending for review', $broker, scalar(@$data));

    push(@orders, @$data);
}

my $count = 0;
while (my @chunk = splice(@orders, 0, 100)) {
    my @entries = map { ($_->{stamp}, join('|', $_->@{qw/order_id order_creator/}), $_->{stamp}, join('|', $_->@{qw/order_id ad_creator/})) } @chunk;
    $count += $p2p_redis->zadd(P2P_ORDER_REVIEWABLE_START_AT, @entries);
}

$log->debugf('%i entries added to Redis key: %s', $count, P2P_ORDER_REVIEWABLE_START_AT);
