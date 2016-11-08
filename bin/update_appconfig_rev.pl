#!/usr/bin/env perl
use strict;
use warnings;

use BOM::Platform::Runtime;

# Load app_config and write a new version. This is used to ensure that we don't cache
# old data such as offerings for too long - we've seen several cases where the list of
# symbols offered on the main site has varied between servers.
#
# By refreshing app_config every 60s, we have a better chance of Redis replicas and internal
# caches being updated.
my $app_config = BOM::Platform::Runtime->instance->app_config;
exit 0 if $app_config->save_dynamic;
warn "App config failed to update\n";
exit 1;

