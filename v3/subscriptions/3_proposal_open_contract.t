#!/usr/bin/env perl
use strict;
use warnings;

no indirect;

use Test::More;
use IO::Async::Loop;
use Log::Any::Adapter qw(Stdout), log_level => $ENV{LOG_LEVEL} // 'info';

use BOM::Test::WebsocketAPI;

my $loop = IO::Async::Loop->new;
$loop->add(
    my $tester = BOM::Test::WebsocketAPI->new(
        endpoint => $ENV{ENDPOINT},
    ),
);

my @subscriptions = ({
        buy => {
            buy        => 1,
            price      => 10,
            parameters => {
                amount        => 10,
                basis         => 'stake',
                contract_type => 'DIGITDIFF',
                currency      => 'USD',
                duration      => 5,
                duration_unit => 't',
                symbol        => 'R_100',
                barrier       => 5,
            },
        },
    },
);

my %subscription_args = (
    subscription_list => \@subscriptions,
    token             => $ENV{TOKEN},
);

$tester->proposal_open_contract(%subscription_args)->get
    if (exists $ENV{ENDPOINT} and exists $ENV{TOKEN});

done_testing;
