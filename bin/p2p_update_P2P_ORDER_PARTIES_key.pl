use strict;
use warnings;
use Syntax::Keyword::Try;

use BOM::Config::Redis;
use BOM::User::Client;
use Log::Any qw($log);
use Log::Any::Adapter ('DERIV', log_level => 'debug');

=head2 p2p_update_P2P_ORDER_PARTIES_key.pl
Manual script to update P2P::ORDER::PARTIES::* set keys in redis by fetching partners from db and populate to the keys

To populate partners need to run script as: perl bin/p2p_update_P2P_ORDER_PARTIES_key.pl | redis-cli --pipe

More information: https://redis.io/docs/manual/patterns/bulk-loading/
=cut

use constant P2P_ORDER_PARTIES => 'P2P::ORDER::PARTIES';
my @brokers = map { $_->{broker_codes}->@* } grep { $_->{p2p_available} } values LandingCompany::Registry::get_loaded_landing_companies()->%*;

try {
    for my $broker (@brokers) {
        my $db = BOM::Database::ClientDB->new({
                broker_code => $broker,
                operation   => 'replica'
            })->db->dbic;

        my $partners = $db->run(
            fixup => sub {
                $_->selectall_arrayref(
                    "WITH advertiser_partners AS (
                        SELECT adv.id AS id,  ARRAY_AGG( DISTINCT ad.advertiser_id) AS ids
                        FROM p2p.p2p_order AS o
                        JOIN p2p.p2p_advert AS ad ON ad.id = o.advert_id 
                        JOIN p2p.p2p_advertiser AS adv ON adv.client_loginid = o.client_loginid
                        GROUP BY 1
                    )
                    , client_partners AS(
                        SELECT ad.advertiser_id AS id, ARRAY_AGG( DISTINCT adv.id) AS ids
                        FROM p2p.p2p_order AS o
                        JOIN p2p.p2p_advert AS ad ON ad.id = o.advert_id 
                        JOIN p2p.p2p_advertiser AS adv ON adv.client_loginid = o.client_loginid
                        GROUP BY 1
                    )
                    , order_partners AS(
                        SELECT * FROM advertiser_partners
                        UNION ALL
                        SELECT * FROM client_partners
                    ) 
                    SELECT id AS advertiser, ARRAY_AGG( DISTINCT each_id  ORDER BY each_id) AS partners 
                    FROM order_partners, UNNEST(ids) AS each_id 
                    GROUP BY 1;",
                    {Slice => {}});
            });

        foreach my $id (@$partners) {
            print gen_redis_proto('SADD', join('::', P2P_ORDER_PARTIES, $id->{advertiser}), $id->{partners}->@*);
        }
    }

} catch ($e) {
    $log->warnf("Error when updating redis p2p partners", $e);
}

sub gen_redis_proto {
    my @args  = @_;
    my $proto = "";
    $proto = "*" . scalar @args . "\r\n";
    foreach my $arg (@args) {
        $proto .= '$' . length($arg) . "\r\n";
        $proto .= $arg . "\r\n";
    }
    return $proto;
}
