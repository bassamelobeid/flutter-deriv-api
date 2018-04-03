#!/etc/rmg/bin/perl

use strict;
use warnings;
use Test::More;
use Test::Exception;
use BOM::RPC::v3::Feeds;

my $result;
lives_ok(sub { $result = BOM::RPC::v3::Feeds::exchange_rates(); }, 'generating exchange rates');

done_testing();