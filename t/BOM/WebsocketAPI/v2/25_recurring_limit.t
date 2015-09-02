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

foreach (1 .. 51) {
    $t = $t->send_ok({json => {ticks => 'R_50'}})->message_ok;
    my $tick = decode_json($t->message->[1]);
    diag Dumper(\$tick);
}

diag Dumper(\$t->ua->ioloop->reactor->{timers});

$t->finish_ok;

done_testing();
