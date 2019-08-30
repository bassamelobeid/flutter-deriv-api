#!/etc/rmg/bin/perl
use strict;
use warnings;

use BOM::CompanyLimits::Limits;

# Sync limits.company_limits from userdb to redis. Executes every minute by
# cron sync_limits_to_redis and logs in /var/log/httpd/sync_limits_to_redis.log

BOM::CompanyLimits::Limits::sync_limits_to_redis();

my $now_time = gmtime();
print "Limits synced at $now_time";
