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
        suite_params       => {
            concurrent => 50,
            requests   => requests(
                calls  => [qw( buy transaction balance )],
                filter => sub {
                    my $params = shift->{params};
                    return 0 if exists $params->{balance}{account} and $params->{balance}{account} eq 'all';
                    # Checking R_100 only, for faster tests.
                    not $params->contract or ($params->contract->underlying->symbol eq 'R_100');
                }
            ),
        }
    ),
);

subtest 'General subscriptions: buy, transaction & balance' => sub {

    Future->needs_all(
        $tester->subscribe_multiple_times(count => 10),
        $tester->subscribe_twice, $tester->subscribe,
        $tester->subscribe_after_request,
        $tester->multiple_connections_forget,
        $tester->multiple_connections_forget_all,
    )->get;

    $tester->run_sanity_checks;
};

done_testing;
