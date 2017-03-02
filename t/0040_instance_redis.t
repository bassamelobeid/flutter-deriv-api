use Test::More;
use strict;
use warnings;

BEGIN { use_ok( 'Binary::WebSocketAPI::v3::Instance::Redis', qw| pricer_write check_connections |); }

ok( Binary::WebSocketAPI::v3::Instance::Redis->check_connections, 'Check redis connections' );
my $server_ref1 = pricer_write;
is( $server_ref1->set("TESTKEY" , "meow-meow"), "OK", "Check pricer redis write" );
is( $server_ref1->get("TESTKEY"), "meow-meow" ,       "Check pricer redis read"  );
is( $server_ref1->del("TESTKEY"), 1,                  "Delete test key"          );
my $server_ref2 = pricer_write;
ok( $server_ref2 == $server_ref1, "Checking of exist only one instance" );

done_testing;
