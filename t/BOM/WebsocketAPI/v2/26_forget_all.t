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

foreach my $i (1 .. 10) {
    $t = $t->send_ok({json => {ticks => 'R_50'}})->message_ok;

    my $now_timer_cnt = scalar(keys %{$t->ua->ioloop->reactor->{timers}});
    is $now_timer_cnt, $first_timer_cnt + $i;
}

foreach my $i (1 .. 3) {
    $t = $t->send_ok({
            json => {
                "proposal"      => 1,
                "amount_val"    => "10",
                "basis"         => "payout",
                "contract_type" => "CALL",
                "currency"      => "USD",
                "symbol"        => "R_50",
                "duration"      => "2",
                "duration_unit" => "m"
            }})->message_ok;
    # my $proposal = decode_json($t->message->[1]);

    my $now_timer_cnt = scalar(keys %{$t->ua->ioloop->reactor->{timers}});
    is $now_timer_cnt, $first_timer_cnt + 10 + $i;    # 10 is ticks
}

## skip tick until we meet forget_all
$t = $t->send_ok({json => {forget_all => 1, type => 'ticks'}});
while (1) {
    $t = $t->message_ok;
    my $res = decode_json($t->message->[1]);
    next if $res->{msg_type} eq 'tick' || $res->{msg_type} eq 'proposal';

    ok $res->{forget_all};
    is scalar( @{$res->{forget_all}} ), 10;
    test_schema('forget_all', $res);

    my $now_timer_cnt = scalar(keys %{$t->ua->ioloop->reactor->{timers}});
    is $now_timer_cnt, $first_timer_cnt + 3; # 3 is proposal

    last;
}

$t = $t->send_ok({json => {forget_all => 1, type => 'proposal'}});
while (1) {
    $t = $t->message_ok;
    my $res = decode_json($t->message->[1]);
    next if $res->{msg_type} eq 'proposal';

    ok $res->{forget_all};
    is scalar( @{$res->{forget_all}} ), 3;
    test_schema('forget_all', $res);

    my $now_timer_cnt = scalar(keys %{$t->ua->ioloop->reactor->{timers}});
    is $now_timer_cnt, $first_timer_cnt;

    last;
}

$t->finish_ok;

done_testing();
