use strict;
use warnings;
use Test::More;
use Data::Dumper;
use JSON;
use Date::Utility;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test build_test_R_50_data/;

build_test_R_50_data();

my $t = build_mojo_test();
my $first_timer_cnt = scalar(keys %{ $t->ua->ioloop->reactor->{timers} });

foreach my $i (1 .. 60) {
    $t = $t->send_ok({json => {ticks => 'R_50'}})->message_ok;
    my $tick = decode_json($t->message->[1]);

    my $now_timer_cnt = scalar(keys %{ $t->ua->ioloop->reactor->{timers} });
    if ($i <= 50) {
        is $now_timer_cnt, $first_timer_cnt + $i;
    } else {
        is $now_timer_cnt, $first_timer_cnt + 50; # max
    }
}

$t->finish_ok;

done_testing();
