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
    ),
);

subtest "Buy subscribtions: Only R_* and frxUSD*" => sub {
    $tester->configure(
        suite_params => {
            concurrent => 50,
            requests   => requests(
                calls  => [qw(buy)],
                filter => sub {
                    shift->{params}->contract->underlying->symbol =~ /R_.*|frxUSD.*/;
                }
            ),
        },
    );
    $tester->buy_then_sell_contract->get;
};

done_testing;
