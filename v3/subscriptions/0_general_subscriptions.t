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

my $loop = IO::Async::Loop->new;
$loop->add(
    my $tester = BOM::Test::WebsocketAPI->new(
        timeout            => 300,
        max_response_delay => 10,
        skip_sanity_checks => {
            website_status => [qw(published check_duplicates)],  # Response can be overlapping between publishes
        },
        suite_params => {
            requests => requests(
                filter => sub {
                    my $params = shift->{params};
                    $params = $params->contract if $params->contract;
                    return 1 unless $params->underlying;
                    # Checking R_100 only, for faster tests.
                    $params->underlying->symbol eq 'R_100'
                },
            ),
            concurrent => 50,
        }
    ),
);

subtest 'General subscriptions: All calls in parallel' => sub {
    Future->needs_all(
        $tester->subscribe,
        $tester->subscribe_multiple_times(count => 10),
        $tester->subscribe_after_request,
        $tester->multiple_subscriptions_forget_one,
        $tester->multiple_connections_forget_one,
    )->get;
};

$tester->run_sanity_checks;

done_testing;
