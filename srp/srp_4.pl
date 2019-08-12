use strict;
use warnings;

use BOM::Config::RedisReplicated;

my $redis_replicated = BOM::Config::RedisReplicated::redis_write();
my $redis_events = BOM::Config::RedisReplicated::redis_events();
my $redis_mt5 = BOM::Config::RedisReplicated::redis_mt5_user_write();

# Move social responsibility to events redis
my %full_data_hash = @{$redis_replicated->hgetall('social_responsibility')};
$redis_events->hmset('social_responsibility', %full_data_hash);

# Move MT5 transfers to MT5 redis
my $transfer_function = sub {
    my ($action) = @_;
    
    # 1. Get the keys, based on the action
    my @list_of_keys = @{$redis_replicated->scan_all(MATCH => "[0-9]*_$action")};
    
    # 2. Get all the values
    my @values = @{$redis_replicated->mget(@list_of_keys)};
    
    # 3. Convert to a hash
    my %hash;
    @hash{@list_of_keys} = @values;
    
    # 4. Transfer to new redis
    $redis_mt5->mset(%hash);
    
    return undef;
};

$transfer_function->('deposit');
$transfer_function->('withdraw');