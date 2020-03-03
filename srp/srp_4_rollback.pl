use strict;
use warnings;

use BOM::Config::Redis;

my $redis_replicated = BOM::Config::Redis::redis_replicated_write();
my $redis_events = BOM::Config::Redis::redis_events();
my $redis_mt5 = BOM::Config::Redis::redis_mt5_user_write();

# Move social responsibility back to replicated redis
my %full_data_hash = @{$redis_events->hgetall('social_responsibility')};
$redis_replicated->hmset('social_responsibility', %full_data_hash);
$redis_events->del('social_responsibility');

# Move MT5 transfers back to replicated redis
my $transfer_function = sub {
    my ($action) = @_;
    
    # 1. Get the keys, based on the action
    my @list_of_keys = @{$redis_mt5->scan_all(MATCH => "[0-9]*_$action")};
    
    # 2. Get all the values
    my @values = @{$redis_mt5->mget(@list_of_keys)};
    
    # 3. Convert to a hash
    my %hash;
    @hash{@list_of_keys} = @values;
    
    # 4. Transfer to previous redis
    $redis_replicated->mset(%hash);
    
    # 5. Delete the keys in the previous server
    $redis_mt5->del(@list_of_keys);
    
    return undef;
};

$transfer_function->('deposit');
$transfer_function->('withdraw');