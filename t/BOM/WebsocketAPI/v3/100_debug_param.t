use strict;
use warnings;

use Data::Dumper;
use JSON;
use Test::Most;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test/;

my $t = build_mojo_test({
    debug    => 1,
    language => 'RU'
});
my ($req_storage, $res, $start, $end);

$t->send_ok({json => {authorize => 'test'}})->message_ok;
$res = decode_json($t->message->[1]);
ok $res->{debug}->{time};
ok $res->{debug}->{method};

$t->send_ok({json => {ping => 1}})->message_ok;
$res = decode_json($t->message->[1]);
ok $res->{debug}->{time};
ok $res->{debug}->{method};

done_testing();
