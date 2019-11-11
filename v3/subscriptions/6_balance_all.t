#!/usr/bin/env perl
use strict;
use warnings;

no indirect;

use Test::More;
use IO::Async::Loop;
use Log::Any::Adapter qw(Stdout), log_level => $ENV{LOG_LEVEL} // 'info';
use Future::Utils qw( fmap0 );

use BOM::Test::WebsocketAPI;
use BOM::Test::WebsocketAPI::Data qw( requests );
use BOM::Test::WebsocketAPI::Parameters qw( test_params );

my $loop = IO::Async::Loop->new;

$loop->add(
    my $tester = BOM::Test::WebsocketAPI->new(
        timeout            => 300,
        max_response_delay => 10,
        suite_params       => {
            concurrent => 50,
            requests   => requests(calls => [qw( balance_all )]),
        }
    ),
);

# Make sure we get at least 2 published responses
$tester->subscribe(min_subscriptions => (test_params()->{client}->@* + 2))->get;
$tester->run_sanity_checks;

done_testing;
