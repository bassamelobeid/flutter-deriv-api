use strict;
use warnings;
use Test::More;
use BOM::Test::Helper qw/build_mojo_test/;
use YAML::XS;
use Test::MockModule;
use Binary::WebSocketAPI::v3::Instance::Redis qw| ws_redis_master |;
use JSON::MaybeXS;

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

my $redis             = ws_redis_master();
my $block_apps_domain = '{
    "red": [1],
    "blue":[24269, 23650, 19499]
    }';
$redis->set('domain_based_apps::blocked', $block_apps_domain);
my $redis_value        = $redis->get('domain_based_apps::blocked');
my %blocked_appid_info = %{JSON::MaybeXS->new->decode($redis_value)};
for my $env (keys %blocked_appid_info) {
    my $module = Test::MockModule->new('YAML::XS');
    subtest "test blocked app id in $env env" => sub {
        $node_config->{node}->{operation_domain} = $env;
        $module->mock('LoadFile', sub { return $node_config; });

        my $app_id_list_ref = $blocked_appid_info{$env};
        my @app_id_list     = @$app_id_list_ref;

        for my $app_id (@app_id_list) {
            $t = build_mojo_test(
                'Binary::WebSocketAPI',
                {
                    language => 'EN',
                    app_id   => $app_id
                });
            $t = build_mojo_test('Binary::WebSocketAPI');
            $t->get_ok("/websockets/v3?app_id=$app_id&l=EN");
            is $t->tx->error->{code}, 403, "got 403 for app id = $app_id  on $env environment";
        }
    };
}

done_testing();
