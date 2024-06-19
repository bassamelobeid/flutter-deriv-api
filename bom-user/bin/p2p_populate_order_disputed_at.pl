use strict;
use warnings;

use BOM::Config::Redis;
use BOM::Config::Runtime;
use BOM::Database::ClientDB;
use LandingCompany::Registry;

use Log::Any qw($log);
use Log::Any::Adapter ('DERIV', log_level => 'debug');

=head2 p2p_populate_order_disputed_at

Manual script to populate order dispute timestamp in redis for disputed P2P orders for which ticket has not been raised

NEED TO RUN THIS INSTANTLY AFTER event-redis RESTART COMPLETED!

=cut

use constant {
    P2P_ORDER_DISPUTED_AT => 'P2P::ORDER::DISPUTED_AT',
};

my $p2p_redis                   = BOM::Config::Redis->redis_p2p_write();
my $hours_before_dispute_ticket = BOM::Config::Runtime->instance->app_config->payments->p2p->disputed_timeout;
my @brokers = map { $_->{broker_codes}->@* } grep { $_->{p2p_available} } values LandingCompany::Registry::get_loaded_landing_companies()->%*;
my @orders;

for my $broker (@brokers) {
    my $db = BOM::Database::ClientDB->new({broker_code => $broker})->db->dbic;

    my $data = $db->run(
        fixup => sub {
            $_->selectall_arrayref(
                "WITH disputed_orders AS (
                    SELECT id, status
                    FROM p2p.p2p_order
                      WHERE status = 'disputed'
                )

                SELECT DISTINCT ON (aud.id) aud.id, EXTRACT(EPOCH FROM aud.stamp)::BIGINT AS disputed_at
                FROM audit.p2p_order AS aud
                JOIN disputed_orders AS d ON (d.id = aud.id AND d.status = aud.status)
                  WHERE NOW() <= aud.stamp + INTERVAL ? HOUR
                ORDER BY aud.id, aud.stamp",
                {Slice => {}}, $hours_before_dispute_ticket
            );

        });

    $log->debugf('%s: %i disputed orders for which CS ticket has not been raised', $broker, scalar(@$data));

    push(@orders, (map { $_->{disputed_at}, join('|', $_->{id}, $broker) } @$data));

}

my $count = 0;
while (my @chunk = splice(@orders, 0, 100)) {
    $count += $p2p_redis->zadd(P2P_ORDER_DISPUTED_AT, @chunk);
}

$log->debugf('%i entries added to Redis key: %s', $count, P2P_ORDER_DISPUTED_AT);
