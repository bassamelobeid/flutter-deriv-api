use strict;
use warnings;
use JSON;
use Test::More;
use BOM::Test::Helper qw/build_mojo_test launch_redis/;

my ($tmp_dir, $redis_server) = launch_redis;
my $t = build_mojo_test(
    'Binary::WebSocketAPI',
    {
        language => 'EN',
        app_id   => ''
    });
$t->get_ok('/websockets/v3?l=EN');
is $t->tx->error->{code}, 401, 'got 401 for invalid app id';

($tmp_dir, $redis_server) = launch_redis;
$t = build_mojo_test(
    'Binary::WebSocketAPI',
    {
        language => 'EN',
        app_id   => 0
    });
$t->get_ok('/websockets/v3?l=EN');
is $t->tx->error->{code}, 401, 'got 401 for 0 app id';

done_testing();
