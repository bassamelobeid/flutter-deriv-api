#!/usr/bin/env perl
use strict;
use warnings;

no indirect;

use Test::More;
use IO::Async::Loop;
use Future::Utils qw( fmap0 );
use feature qw(state);

use Log::Any qw($log);
use Log::Any::Adapter qw(Stdout), log_level => $ENV{LOG_LEVEL} // 'info';

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
                calls => [qw(ticks ticks_history)],
            ),
        },
    ),
);

subtest "Tick Subscriptions: All Symbols" => sub {
    Future->needs_all($tester->subscribe, $tester->subscribe_multiple_times(count => 10),)->get;
};

subtest "Tick Subscriptions: Only R_*" => sub {
    $tester->configure(
        suite_params => {
            concurrent => 50,
            requests   => requests(
                calls  => [qw(ticks ticks_history)],
                filter => sub {
                    my $params = shift->{params};
                    $params = $params->ticks_history if $params->ticks_history;
                    $params->underlying->symbol =~ /R_.*/;
                },
            ),
        });
    Future->needs_all(
        $tester->subscribe, $tester->subscribe_multiple_times(count => 10),
        $tester->subscribe_twice,
        $tester->multiple_subscriptions_forget,
        $tester->multiple_subscriptions_forget_all,
        $tester->multiple_connections_forget,
        $tester->multiple_connections_forget_all,
    )->get;
};

done_testing;
