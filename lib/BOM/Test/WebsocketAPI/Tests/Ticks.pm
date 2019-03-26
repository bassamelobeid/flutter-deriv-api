package BOM::Test::APITester::Tests::Ticks;

no indirect;

use strict;
use warnings;

use Devops::BinaryAPI::Tester::DSL;

# This test must not be run concurrently with other tests, because it pauses the publisher
suite ticks_feed_gap => sub {
    my ($suite, %args) = @_;

    my $symbol = $args{symbol} // 'R_100';
    my $method = $args{method} // 'ticks';

    my $sub = $suite
    ->connection
    ->subscribe( $method, { $method => $symbol, $method eq 'ticks_history' ? ( end => 'latest' ) : () } );

    note "stopping feed for 5 seconds";
    $suite->tester->publisher->stop_publish;
    $suite->tester->loop->delay_future(after => 5)
    ->then ( sub {
        note "restarting feed";
        $suite->tester->publisher->start_publish;
        $sub
        ->helper::log_method($method)
        ->completed;
    });
};


1;
