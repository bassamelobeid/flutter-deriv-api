use strict;
use warnings;

use BOM::Config::Redis;
use BOM::Database::ClientDB;
use LandingCompany::Registry;

use Log::Any qw($log);
use Log::Any::Adapter ('DERIV', log_level => 'debug');

=head2 p2p_populate_temp_ban

Manual script to populate advertiser temporary ban end date (epoch) in redis that will be used
in P2PDaemon to emit p2p_advertiser_updated event when advertiser's temporary ban is over

=cut

use constant {
    P2P_ADVERTISER_BLOCK_ENDS_AT => 'P2P::ADVERTISER::BLOCK_ENDS_AT',
};

my $p2p_redis = BOM::Config::Redis->redis_p2p_write();
my @brokers   = map { $_->{broker_codes}->@* } grep { $_->{p2p_available} } values LandingCompany::Registry::get_loaded_landing_companies()->%*;
my @advertisers;

for my $broker (@brokers) {
    my $db = BOM::Database::ClientDB->new({broker_code => $broker})->db->dbic;

    my $data = $db->run(
        fixup => sub {
            $_->selectall_arrayref(
                "SELECT EXTRACT(EPOCH FROM blocked_until)::BIGINT AS blocked_until_epoch, client_loginid
                 FROM p2p.p2p_advertiser
                 WHERE blocked_until IS NOT NULL 
                   AND blocked_until > NOW()",
            );

        });

    $log->debugf('%s: %i advertisers are temporarily banned', $broker, scalar(@$data));

    push(@advertisers, @$data);

}

my $count = 0;
while (my @chunk = splice(@advertisers, 0, 100)) {
    my @entries = map { @{$_} } @chunk;
    $count += $p2p_redis->zadd(P2P_ADVERTISER_BLOCK_ENDS_AT, @entries);
}

$log->debugf('%i entries added to Redis key: %s', $count, P2P_ADVERTISER_BLOCK_ENDS_AT);
