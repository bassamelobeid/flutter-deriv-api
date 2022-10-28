use strict;
use warnings;
use BOM::Config::Redis;
use BOM::User::Client;
use Log::Any   qw($log);
use List::Util qw/sum/;
use Log::Any::Adapter ('DERIV', log_level => 'debug');

=head2 p2p_update_user_online_key.pl
Manual script to update P2P::USERS_ONLINE key in redis by appending country code to each field name
=cut

use constant {
    P2P_USERS_ONLINE  => 'P2P::USERS_ONLINE',
    P2P_ONLINE_PERIOD => 26 * 7 * 24 * 60 * 60,    # 26 weeks
};

my $p2p_redis = BOM::Config::Redis->redis_p2p_write();

my %p2p_online_client_record = $p2p_redis->zrangebyscore(P2P_USERS_ONLINE, time - P2P_ONLINE_PERIOD, '+Inf', "withscores")->@*;

foreach my $loginid (keys %p2p_online_client_record) {
    my $residence          = BOM::User::Client->new({loginid => $loginid})->residence;
    my $updated_field_name = ($loginid . "::" . $residence);
    $p2p_redis->multi;
    $p2p_redis->zadd(P2P_USERS_ONLINE, $p2p_online_client_record{$loginid}, $updated_field_name);
    $p2p_redis->zrem(P2P_USERS_ONLINE, $loginid);
    my $output = $p2p_redis->exec;
    if (sum($output->@*) == 2) {
        $log->debugf('added field: %s with score: %i and deleted field: %s', $updated_field_name, $p2p_online_client_record{$loginid}, $loginid);
    } else {
        $log->debugf('failed adding field: %s and deleting field: %s', $updated_field_name, $loginid);
    }
}
