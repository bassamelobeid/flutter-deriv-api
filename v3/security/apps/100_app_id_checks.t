use strict;
use warnings;
use Test::More;
use BOM::Test::Helper qw/build_mojo_test/;
use YAML::XS;
use Test::MockModule;

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

my $node_config = YAML::XS::LoadFile('/etc/rmg/node.yml');

$t = build_mojo_test('Binary::WebSocketAPI');

$t->get_ok('/websockets/v3?app_id=1&l=EN');
#404 is what you get if everything passes,  just means we have not sent an actual request.
is $t->tx->error->{code}, 404, 'got 404 for app id = 1 when no opertaion Domain set.  ';

$node_config->{node}->{operation_domain} = 'red';

my $module = Test::MockModule->new('YAML::XS');
$module->mock('LoadFile', sub { return $node_config; });

$t = build_mojo_test('Binary::WebSocketAPI');

$t->get_ok('/websockets/v3?app_id=1&l=EN');
is $t->tx->error->{code}, 403, 'got 403 for app id = 1  on red environment';
done_testing();
