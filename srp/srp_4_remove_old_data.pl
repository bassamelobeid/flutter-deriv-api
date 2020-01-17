use strict;
use warnings;

use BOM::Config::Redis;

my $redis_replicated = BOM::Config::Redis::redis_replicated_write();
$redis_replicated->del('social_responsibility');

# Move MT5 transfers back to replicated redis
my $delete_function = sub {
    my ($action) = @_;
    
    # 1. Get the keys, based on the action
    my @list_of_keys = @{$redis_replicated->scan_all(MATCH => "[0-9]*_$action")};
    
    # 2. Delete them
    $redis_replicated->del(@list_of_keys);
    
    return undef;
};

$delete_function->('deposit');
$delete_function->('withdraw');