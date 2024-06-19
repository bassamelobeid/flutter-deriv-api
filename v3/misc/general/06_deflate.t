use strict;
use warnings;
use Test::More;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/build_wsapi_test/;
use await;

## test without deflate
my $t   = build_wsapi_test();
my $res = $t->await::ping({ping => 1});
is $res->{msg_type}, 'ping';
is $res->{ping},     'pong';
$t->header_unlike('Sec-WebSocket-Extensions', qr'permessage-deflate');
$t->finish_ok;

## test with deflate
$t   = build_wsapi_test({deflate => 1});
$res = $t->await::ping({ping => 1});
is $res->{msg_type}, 'ping';
is $res->{ping},     'pong';
$t->header_like('Sec-WebSocket-Extensions', qr'permessage-deflate');
$t->finish_ok;

done_testing();
