#!/usr/bin/perl -I ../../../../lib

use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::FailWarnings;

use BOM::Platform::Runtime;

my @skip_servers = qw(cashier info);
foreach my $host (BOM::Platform::Runtime->instance->hosts->all) {
    next if (grep { $host->name eq $_ } @skip_servers);
    if ($host->belongs_to('bom')) {
        ok $host->has_role('production_unix_server'), $host->name . " has production_unix_server role, required for login";
    }
}

done_testing;
