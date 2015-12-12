use strict;
use warnings;
use Test::More;
use Data::Dumper;
use JSON;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test build_test_R_50_data/;

build_test_R_50_data();

my $t               = build_mojo_test();
my $first_timer_cnt = scalar(keys %{$t->ua->ioloop->reactor->{timers}});
# $first_timer_cnt--;

foreach my $i (1 .. 60) {
    $t = $t->send_ok({json => {ticks => 'R_50'}})->message_ok;
    # my $tick = decode_json($t->message->[1]);

    my $now_timer_cnt = scalar(keys %{$t->ua->ioloop->reactor->{timers}});
    if ($i <= 50) {
        is $now_timer_cnt, $first_timer_cnt + $i;
    } else {
        is $now_timer_cnt, $first_timer_cnt + 50;    # max
    }
}

foreach my $i (1 .. 3) {
    $t = $t->send_ok({
            json => {
                "proposal"      => 1,
                "amount"        => "10",
                "basis"         => "payout",
                "contract_type" => "CALL",
                "currency"      => "USD",
                "symbol"        => "R_50",
                "duration"      => "2",
                "duration_unit" => "m"
            }})->message_ok;
    # my $proposal = decode_json($t->message->[1]);

    my $now_timer_cnt = scalar(keys %{$t->ua->ioloop->reactor->{timers}});
    is $now_timer_cnt, $first_timer_cnt + 50;    # max
}

$t->finish_ok;

done_testing();
