#!/usr/bin/perl
use strict; use warnings;
use 5.010;

use MyExp;
use Data::Dumper;

my $prove_id = MyExp->new(
    search_option   => 'ProveID_KYC',
);

my $prove_id_result = $prove_id->get_result();

if ( !$prove_id->has_done_request ) {
    # connection problems
    die 'connection problems';
}

die Dumper $prove_id_result;

