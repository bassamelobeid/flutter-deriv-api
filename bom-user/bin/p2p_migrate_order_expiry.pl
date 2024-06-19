use strict;
use warnings;
use BOM::Config::Redis;
use BOM::Database::ClientDB;
use LandingCompany::Registry;

use Date::Utility;
use Log::Any qw($log);
use Log::Any::Adapter ('DERIV', log_level => 'debug');

=head2 p2p_migrate_order_expiry.pl

Manual script to reset and create all P2P order expiry redis keys.

NEED TO RUN THIS INSTANTLY AFTER event-redis RESTART COMPLETED!

=cut

use constant {
    P2P_ORDER_EXPIRES_AT  => 'P2P::ORDER::EXPIRES_AT',
    P2P_ORDER_TIMEDOUT_AT => 'P2P::ORDER::TIMEDOUT_AT',
};

my %status_to_key = (
    'pending'         => P2P_ORDER_EXPIRES_AT,
    'buyer-confirmed' => P2P_ORDER_EXPIRES_AT,
    'timed-out'       => P2P_ORDER_TIMEDOUT_AT,
);

my $redis = BOM::Config::Redis->redis_p2p_write();
$redis->del(P2P_ORDER_EXPIRES_AT, P2P_ORDER_TIMEDOUT_AT);

my @brokers = map { $_->{broker_codes}->@* } grep { $_->{p2p_available} } values LandingCompany::Registry::get_loaded_landing_companies()->%*;

my $total_orders = 0;
for my $broker (@brokers) {
    $log->debugf('processing %s', $broker);
    my $db = BOM::Database::ClientDB->new({broker_code => uc $broker})->db->dbic;

    my $orders = $db->run(
        fixup => sub {
            $_->selectall_arrayref("SELECT * FROM p2p.p2p_order WHERE status IN ('pending', 'buyer-confirmed', 'timed-out')", {Slice => {}});
        });

    my $count = 0;
    $total_orders += scalar(@$orders);

    for my $order (@$orders) {
        my $item = $order->{id} . '|' . $order->{client_loginid};
        $count += $redis->zadd($status_to_key{$order->{status}}, Date::Utility->new($order->{expire_time})->epoch, $item);
    }

    $log->debugf('%i entries added to Redis after proessing %i orders', $count, $total_orders);
}
