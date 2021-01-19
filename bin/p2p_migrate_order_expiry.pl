use strict;
use warnings;
use BOM::Config::Redis;
use BOM::Database::ClientDB;
use Date::Utility;
use feature 'say';

=head2 p2p_migrate_order_expiry.pl

Manual script to reset and create all P2P order expiry redis keys.

=cut

use constant P2P_ORDER_EXPIRES_AT  => 'P2P::ORDER::EXPIRES_AT';
use constant P2P_ORDER_TIMEDOUT_AT => 'P2P::ORDER::TIMEDOUT_AT';

my $redis = BOM::Config::Redis->redis_p2p_write();
$redis->del(P2P_ORDER_EXPIRES_AT, P2P_ORDER_TIMEDOUT_AT);

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
            $_->selectall_arrayref("SELECT * FROM p2p.p2p_order WHERE status IN ('pending', 'buyer-confirmed', 'timed-out')",
                {Slice => {}});
    });
    
    my $c = 0;
    for my $order (@$orders) {
        my $item = $order->{id}.'|'.$order->{client_loginid};

        if ($order->{status} =~ /^(pending|buyer-confirmed)$/) {
            $redis->zadd(P2P_ORDER_EXPIRES_AT, Date::Utility->new($order->{expire_time})->epoch, $item);
            $c++;
        }

        if ($order->{status} eq 'timed-out') {
            $redis->zadd(P2P_ORDER_TIMEDOUT_AT, Date::Utility->new($order->{expire_time})->epoch, $item);
            $c++;
        }        
    }
    say "- $c orders procssed";
}
