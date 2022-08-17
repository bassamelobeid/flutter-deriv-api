#!/usr/bin/env perl

use BOM::Test::LoadTest::Proposal;

my $app_id      = 16303;
my $end_point   = 'ws://127.0.0.1:5004';
my $load_tester = BOM::Test::LoadTest::Proposal->new(
    end_point => $end_point,
    app_id    => $app_id,
);
use Data::Dumper;
print Dumper([$load_tester->all_markets]);
