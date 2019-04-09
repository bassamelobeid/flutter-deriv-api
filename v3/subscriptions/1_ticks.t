#!/usr/bin/env perl
use strict;
use warnings;

no indirect;

use Test::More;
use IO::Async::Loop;
use Future::Utils qw( fmap0 );

use Log::Any qw($log);
use Log::Any::Adapter qw(Stdout), log_level => $ENV{LOG_LEVEL} // 'info';

use BOM::Test::WebsocketAPI;
my $chunks = 5;

my $loop = IO::Async::Loop->new;
$loop->add(
    my $tester = BOM::Test::WebsocketAPI->new(
        timeout             => 500,
        max_response_delay  => 0.5, # 500ms
        ticks_history_count => 5,
    ),
);

$loop->add(
    my $tester_large_delay = BOM::Test::WebsocketAPI->new(
        timeout             => 300,
        ticks_history_count => 5,
        max_response_delay  => 1, # 1s
    ),
);

my @active_symbols = $tester->active_symbols( streamable => 1 )->get;

note "There are ".@active_symbols." active symbols";

$tester->publish(
    tick => \@active_symbols,
);


for my $method ( qw(ticks ticks_history) ) {

    subtest "Subscriptions for $method" => sub {

        my @requests = map { make_request($method, $_) } @active_symbols;

        Future->needs_all(
            $tester->ticks_invalid_symbol( method => $method ),
            
            # subscribe to everything on one connection
            $tester->subscribe(
                subscription_list => \@requests,
                concurrent        => scalar @requests,
            ),

            # subscribe to everything on different connections
            # todo - reduce the max_response_delay
            $tester_large_delay->subscribe_multiple_times(
                count             => 2,
                subscription_list => \@requests,
                concurrent        => scalar @requests,
            ),

            # different req_id is ok
            $tester->ticks_duplicate_subscribe_ok( method => $method ),
        )->get;

        my $chunk_size = @requests / $chunks;
        for my $i (0 .. $chunks - 1) {
            $tester_large_delay->multiple_subscriptions_forget_one(
                subscription_list => [@requests[$i * $chunk_size .. ($i * $chunk_size + $chunk_size - 1)]],
                concurrent        => $chunk_size,
            )->get
        }
        
        # This must not be run in parellel with other tests, because it pauses the publisher
        $tester->ticks_feed_gap( method => $method )->get;
    }
}

sub make_request {
    return { $_[0] => { $_[0] => $_[1], $_[0] eq 'ticks_history' ? ( end => 'latest' ) : () } };
}

$tester->run_sanity_checks;

done_testing;
