use strict;
use warnings;
use Test::More;
use JSON;
use Data::Dumper;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test/;

my $t = build_mojo_test();

$t = $t->send_ok({json => {ping => '†'}})->message_ok;
my $res = decode_json($t->message->[1]);
is $res->{error}->{code}, 'SanityCheckFailed';
test_schema('ping', $res);

$t->finish_ok;

done_testing();
