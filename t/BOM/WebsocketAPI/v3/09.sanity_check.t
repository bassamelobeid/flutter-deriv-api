use strict;
use warnings;
use Test::More;
#use Test::NoWarnings; #
use Test::FailWarnings;

use JSON;
use Data::Dumper;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test/;
use utf8;

my $t = build_mojo_test();

$t = $t->send_ok({json => {ping => '௰'}})->message_ok;
my $res = decode_json($t->message->[1]);
is $res->{error}->{code}, 'SanityCheckFailed';
test_schema('ping', $res);

# undefs are fine for some values
$t = $t->send_ok({json => {ping => {key => undef}}})->message_ok;


$t->finish_ok;

done_testing();
