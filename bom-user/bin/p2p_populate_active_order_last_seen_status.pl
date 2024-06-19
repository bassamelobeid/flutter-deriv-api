use strict;
use warnings;
use BOM::Config::Redis;
use BOM::Database::ClientDB;
use LandingCompany::Registry;
use Log::Any qw($log);
use BOM::Config::Runtime;
use Log::Any::Adapter ('DERIV', log_level => 'debug');

=head2 p2p_populate_active_order_last_seen_status.pl
Manual script to populate last seen status in redis for each active p2p order
=cut

use constant {
    P2P_ORDER_LAST_SEEN_STATUS => "P2P::ORDER::LAST_SEEN_STATUS",
};

my $p2p_redis = BOM::Config::Redis->redis_p2p_write();
my @brokers   = map { $_->{broker_codes}->@* } grep { $_->{p2p_available} } values LandingCompany::Registry::get_loaded_landing_companies()->%*;
my @orders;

for my $broker (@brokers) {
    my $db = BOM::Database::ClientDB->new({broker_code => $broker})->db->dbic;

    my $data = $db->run(
        fixup => sub {
            $_->selectall_arrayref(
                "SELECT ord.id, ord.client_loginid, adv.client_loginid AS advertiser_loginid, ord.status,
                        ord.advertiser_confirmed, ord.client_confirmed, ord.disputer_loginid,
                        CASE 
                           WHEN ad.type = 'sell' THEN 'buy'
                           ELSE 'sell'
                        END order_type,
                        CASE
                           WHEN ad.type = 'sell' THEN ord.client_loginid
                           ELSE adv.client_loginid
                        END buyer_loginid,
                        CASE
                           WHEN ad.type = 'sell' THEN adv.client_loginid
                           ELSE ord.client_loginid
                        END seller_loginid
                FROM p2p.p2p_order as ord
                JOIN p2p.p2p_advert AS ad ON ad.id = ord.advert_id
                JOIN p2p.p2p_advertiser AS adv ON adv.id = ad.advertiser_id
                WHERE NOT p2p.is_status_final(ord.status)",
                {Slice => {}});

        });
    $log->debugf('got %i orders from %s', scalar(@$data), $broker);

    push @orders => @$data;

}

sub set_last_seen_status {
    my $param = shift;
    $p2p_redis->hset(P2P_ORDER_LAST_SEEN_STATUS, $param->{order_key}, $param->{last_seen_status});
    $log->debugf('field: %s,  value: %s added', $param->{order_key}, $param->{last_seen_status});
}

for my $order (@orders) {
    if ($order->{status} eq "pending") {
        set_last_seen_status({
            order_key        => $order->{id} . "|" . $order->{client_loginid},
            last_seen_status => "pending"
        });

    } elsif ($order->{status} eq "buyer-confirmed") {
        set_last_seen_status({
            order_key        => $order->{id} . "|" . $order->{buyer_loginid},
            last_seen_status => "buyer-confirmed"
        });

        set_last_seen_status({
            order_key        => $order->{id} . "|" . $order->{seller_loginid},
            last_seen_status => "pending"
        });
    } elsif ($order->{status} eq "disputed") {

        my $counterparty = $order->{disputer_loginid} eq $order->{buyer_loginid} ? $order->{seller_loginid} : $order->{buyer_loginid};
        set_last_seen_status({
            order_key        => $order->{id} . "|" . $order->{disputer_loginid},
            last_seen_status => "disputed"
        });

        set_last_seen_status({
            order_key        => $order->{id} . "|" . $counterparty,
            last_seen_status => "timed-out"
        });

    } elsif ($order->{status} eq "timed-out") {
        set_last_seen_status({
                order_key        => $order->{id} . "|" . $_,
                last_seen_status => "buyer-confirmed"
            }) foreach ($order->@{qw/buyer_loginid seller_loginid/});

    }
}
