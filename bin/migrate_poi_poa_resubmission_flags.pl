#!/etc/rmg/bin/perl

use strict;
use warnings;

use BOM::Config::Redis;
use BOM::User;

# This script is intended to migrate the poi/poa resubmissions flag
# into theirs brand new client status codes.

use constant ONE_WEEK => 86400 * 7;    # In seconds

my $redis    = BOM::Config::Redis::redis_replicated_write();
my $poi_keys = $redis->keys('ONFIDO::ALLOW_RESUBMISSION::ID::*');
my $poa_keys = $redis->keys('POA::ALLOW_RESUBMISSION::ID::*');

foreach my $poi_key (@$poi_keys) {
    my ($binary_user_id) = $poi_key =~ /ONFIDO::ALLOW_RESUBMISSION::ID::(\d+)/;
    my $user = BOM::User->new(id => $binary_user_id);
    next unless $user;

    my @clients = grep { not $_->is_virtual } $user->clients(include_disabled => 0);
    foreach my $client (@clients) {
        # Set allow_poi_resubmission status
        $client->status->setnx('allow_poi_resubmission', 'system', $redis->get('ONFIDO::ALLOW_RESUBMISSION::ID::' . $binary_user_id));
        # Instead of dropping the redis key, we will set a 1 week expiration
        $redis->expire('ONFIDO::ALLOW_RESUBMISSION::ID::' . $binary_user_id, ONE_WEEK);
    }
}

foreach my $poa_key (@$poa_keys) {
    my ($binary_user_id) = $poa_key =~ /POA::ALLOW_RESUBMISSION::ID::(\d+)/;
    my $user = BOM::User->new(id => $binary_user_id);
    next unless $user;

    my @clients = grep { not $_->is_virtual } $user->clients(include_disabled => 0);
    foreach my $client (@clients) {
        # Set allow_poa_resubmission status
        $client->status->setnx('allow_poa_resubmission', 'system', $redis->get('POA::ALLOW_RESUBMISSION::ID::' . $binary_user_id));
        # Instead of dropping the redis key, we will set a 1 week expiration
        $redis->expire('POA::ALLOW_RESUBMISSION::ID::' . $binary_user_id, ONE_WEEK);
    }
}
