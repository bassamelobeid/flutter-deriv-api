use strict;
use warnings;
use Test::More;
use BOM::Test::Helper qw/build_mojo_test/;

my $t = build_mojo_test(
    'Binary::WebSocketAPI',
    {
        language => 'EN',
        app_id   => ''
    });
$t->get_ok('/websockets/v3?l=EN');
is $t->tx->error->{code}, 401, 'got 401 for invalid app id';

$t = build_mojo_test(
    'Binary::WebSocketAPI',
    {
        language => 'EN',
        app_id   => 0
    });
$t->get_ok('/websockets/v3?l=EN');
is $t->tx->error->{code}, 401, 'got 401 for 0 app id';

done_testing();
