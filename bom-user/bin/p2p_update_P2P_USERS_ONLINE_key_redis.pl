use strict;
use warnings;
use Syntax::Keyword::Try;
use BOM::Config::Redis;
use BOM::Database::ClientDB;
use LandingCompany::Registry;
use Log::Any qw($log);
use Log::Any::Adapter ('DERIV', log_level => 'debug');

=head2 p2p_update_P2P_USERS_ONLINE_key_redis.pl
Manual script to update P2P::USERS_ONLINE sorted set keys in redis to remove non P2P user entries
=cut

use constant P2P_USERS_ONLINE => 'P2P::USERS_ONLINE';

my @brokers   = map { $_->{broker_codes}->@* } grep { $_->{p2p_available} } values LandingCompany::Registry::get_loaded_landing_companies()->%*;
my $p2p_redis = BOM::Config::Redis->redis_p2p_write();
my %advertisers;

try {
    for my $broker (@brokers) {
        my $db = BOM::Database::ClientDB->new({
                broker_code => $broker,
                operation   => 'replica'
            })->db->dbic;

        my $loginids = $db->run(
            fixup => sub {
                $_->selectall_hashref("SELECT client_loginid from p2p.p2p_advertiser", 'client_loginid');
            });

        %advertisers = (%advertisers, $loginids->%*) if keys $loginids->%*;
    }

    my %p2p_online_client_record = $p2p_redis->zrangebyscore(P2P_USERS_ONLINE, '-Inf', '+Inf', "withscores")->@*;
    my @non_p2p_users            = grep { !exists($advertisers{(split(/:/, $_))[0]}) } keys %p2p_online_client_record;
    $log->debugf(
        'Total %i fields for %s key, %i fields are non P2P users and have to be removed',
        scalar(keys %p2p_online_client_record),
        P2P_USERS_ONLINE, (scalar @non_p2p_users));

    my $deleted_count = 0;
    while (my @chunck = splice(@non_p2p_users, 0, 1000)) {
        # this is done to prevent blocking Redis for longer time
        $deleted_count += $p2p_redis->zrem(P2P_USERS_ONLINE, @chunck);
    }

    $log->debugf('%i fields have been deleted from %s', $deleted_count, P2P_USERS_ONLINE);

} catch ($e) {
    $log->warnf("Error when updating redis 'P2P::USERS_ONLINE' key", $e);
}
