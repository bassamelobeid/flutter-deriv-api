#!/usr/bin/env perl 
use strict;
use warnings;

use IO::Async::Loop;
use Future::AsyncAwait;
use BOM::Platform::Event::Emitter;

use DataDog::DogStatsd::Helper qw(stats_inc);

# Seconds between each attempt at checking the database entries.
use constant POLLING_INTERVAL => 60;

my $loop = IO::Async::Loop->new;
my $shutdown = $loop->new_future;
$shutdown->on_ready(sub {
    $log->infof('Shut down');
});
$loop->watch_signal(INT => sub {
    $shutdown->done;
});

(async sub {
    $log->infof('Starting OTC polling');
    until($shutdown->is_ready) {
        # Scan for expired items - we'd expect something from the database here
        my @expired;

        stats_inc('otc.order.expired');
        BOM::Platform::Event::Emitter::emit(
            otc_order_expired => $_
        ) for @expired;

        await Future->wait_any(
            $loop->delay_future(after => POLLING_INTERVAL),
            $shutdown
        );
    }
})->()->get;

