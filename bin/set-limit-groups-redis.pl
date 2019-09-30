#!/etc/rmg/bin/perl

# This is supposed to be used by SRP when underlyings.yml or contract_types.yml has changed.
# This script is also used to populate QA instaces with default groups upon rebuild or when
# sudo chef-client is manually executed.
#
# 1. make sure the Finance::Underlying (public CPAN repo) module is up-to-date
# 2. make sure the Finance::Contract (public CPAN repo) module is up-to-date
# 3. call
#      bin/set-limit-groups-redis.pl
#
# NOTE: we should NOT delete symbols/contracts unless we are absolutely sure there are
#       no open contracts using them.

use strict;
use warnings;

use BOM::Transaction::Limits::Groups;
use BOM::Config::RedisTransactionLimits;

my $redis = BOM::Config::RedisTransactionLimits::redis_limits_write();

print "\nSet default groups:contract into Redis... ",
    $redis->hmset('groups:contract', %{BOM::Transaction::Limits::Groups::get_default_contract_group_mappings()});
print "\nSet default groups:underlying into Redis... ",
    $redis->hmset('groups:underlying', %{BOM::Transaction::Limits::Groups::get_default_underlying_group_mappings()});
print "\n";
