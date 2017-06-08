package BOM::Test::Helper;

use strict;
use warnings;

BEGIN {
    # Avoid MOJO_LOG_LEVEL = fatal set by Test::Mojo
    $ENV{HARNESS_IS_VERBOSE} = 1;    ## no critic (RequireLocalizedPunctuationVars)
}

use Test::More;
use Test::Mojo;

use JSON::Schema;
use JSON;
use File::Slurp;
use Data::Dumper;
use Date::Utility;

use BOM::Test;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Platform::Password;
use BOM::Platform::User;
use Net::EmptyPort qw/empty_port/;

use Mojo::Redis2::Server;
use File::Temp qw/ tempdir /;
use Path::Tiny;

use Test::MockModule;
use Test::MockObject;
use MojoX::JSON::RPC::Client;
use IO::Async::Loop;
use RedisDB;
use YAML::XS qw/LoadFile DumpFile/;

use Exporter qw/import/;
our @EXPORT_OK =
    qw/test_schema build_mojo_test build_wsapi_test build_test_R_50_data create_test_user call_mocked_client reconnect launch_redis wsapi_wait_for/;

my $version = 'v3';
die 'unknown version' unless $version;

=head2 <wsapi_wait_for>

my $data =  wsapi_wait_for( $t, 'proposal', sub{ send_request.... }, sub{ check_result.... (optional) }, {timeout => 4, wait_max => 100}});

Perform action and wait for the response ( you need to set message type for it ).
It's a blocking operation.
Working with Test::Mojo based tests

=cut

sub wsapi_wait_for {
    my ($t, $wait_for, $action_sub, $check_callback, $params, $messages_without_accidens) = @_;
    $check_callback //= sub { };
    $params //= {};
    $messages_without_accidens //= 0;
    my $ioloop = IO::Async::Loop->new;

    my $f = $ioloop->new_future;

    $t->tx->once(
        message => sub {
            my ($tx, $msg) = @_;
            return $tx unless $wait_for;
            note "Got " . $msg;
            my $data = decode_json($msg);

            return $tx unless ($wait_for && $data->{msg_type} eq $wait_for);
            $check_callback->($data);
            $wait_for = '';
            $f->done($data) if !$f->is_ready;
        });

    my $id = $ioloop->watch_time(
        after => ($params->{timeout} || 1),
        code => sub {
            if ($messages_without_accidens == ($params->{wait_max} || 10)) {
                return $f->fail("timeout");
            }
            $f->cancel('try again');
            wsapi_wait_for($t, $wait_for, sub { $t->message_ok }, $check_callback, $params, ++$messages_without_accidens);
        },
    );
    $f->on_ready(sub { shift->loop->unwatch_time($id) });

    $action_sub->();

    my $data = $ioloop->await($f)->get;
    return $data;
}

sub build_mojo_test {
    my $app_class = shift;

    die 'Wrong app' if !$app_class || ref $app_class;
    eval "require $app_class";    ## no critic (ProhibitStringyEval, RequireCheckingReturnValueOfEval)

    my $port   = empty_port;
    my $app    = $app_class->new;
    my $daemon = Mojo::Server::Daemon->new(
        app    => $app,
        listen => ["http://127.0.0.1:$port"],
    );
    $daemon->start;
    return Test::Mojo->new($app);
}

sub launch_redis {
    my $redis_port   = empty_port;
    my $redis_server = Mojo::Redis2::Server->new;
    $redis_server->start(port => $redis_port);
    my $tmp_dir = tempdir(CLEANUP => 1);
    my $ws_redis_path = path($tmp_dir, "ws-redis.yml");
    my $ws_redis_config = {
        write => {
            host => '127.0.0.1',
            port => $redis_port,
        },
        read => {
            host => '127.0.0.1',
            port => $redis_port,
        },
    };
    DumpFile($ws_redis_path, $ws_redis_config);
    $ENV{BOM_TEST_WS_REDIS} = "$ws_redis_path";    ## no critic (RequireLocalizedPunctuationVars)

    return ($tmp_dir, $redis_server);
}

sub build_wsapi_test {
    my $args    = shift || {};
    my $headers = shift || {};
    my $callback = shift;

    # We use 1 by default for these tests, unless a value is provided.
    # undef means "leave it out", used for a few tests that need to check
    # that we handle missing app_id correctly.
    # as now app id is mandatory so assign it if not present
    $args->{app_id} = 1 unless exists $args->{app_id};

    my ($tmp_dir, $redis_server) = launch_redis;
    my $t = build_mojo_test('Binary::WebSocketAPI', $args);
    $t->app->log(Mojo::Log->new(level => 'debug'));

    my @query_params;
    my $url = "/websockets/$version";
    push @query_params, 'l=' . $args->{language}    if $args->{language};
    push @query_params, 'debug=' . $args->{debug}   if $args->{debug};
    push @query_params, 'app_id=' . $args->{app_id} if $args->{app_id};
    $url .= "?" . join('&', @query_params) if @query_params;

    if ($args->{deflate}) {
        $headers = {'Sec-WebSocket-Extensions' => 'permessage-deflate'};
    }

    $t->websocket_ok($url => $headers);
    $t->tx->on(json => $callback) if $callback;

    # keep them until $t be destroyed
    $t->{_bom} = {
        tmp_dir      => $tmp_dir,
        redis_server => $redis_server,
    };
    return $t;
}

sub reconnect {
    my ($t, $args) = @_;
    $t->reset_session;
    my $url = "/websockets/$version";

    $args->{app_id} = 1 unless exists $args->{app_id};

    my @query_params;
    push @query_params, 'l=' . $args->{language}    if $args->{language};
    push @query_params, 'debug=' . $args->{debug}   if $args->{debug};
    push @query_params, 'app_id=' . $args->{app_id} if $args->{app_id};
    $url .= "?" . join('&', @query_params) if @query_params;

    $t->websocket_ok($url => {});
    return;
}

sub test_schema {
    my ($type, $data) = @_;

    my $validator =
        JSON::Schema->new(JSON::from_json(File::Slurp::read_file($ENV{WEBSOCKET_API_REPO_PATH} . "/config/$version/$type/receive.json")));
    my $result = $validator->validate($data);
    ok $result, "$type response is valid";
    if (not $result) {
        diag Dumper(\$data);
        diag " - $_" foreach $result->errors;
    }
    return;
}

sub build_test_R_50_data {
    initialize_realtime_ticks_db();

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc('currency', {symbol => $_}) for qw(USD);
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'randomindex',
        {
            symbol => 'R_50',
            date   => Date::Utility->new
        });
    return;
}

sub create_test_user {
    my $email     = 'abc@binary.com';
    my $password  = 'jskjd8292922';
    my $hash_pwd  = BOM::Platform::Password::hashpw($password);
    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $client_cr->set_default_account('USD');
    $client_cr->email($email);
    $client_cr->save;
    my $cr_1 = $client_cr->loginid;
    my $user = BOM::Platform::User->create(
        email    => $email,
        password => $hash_pwd
    );
    $user->save;
    $user->add_loginid({loginid => $cr_1});
    $user->save;

    return $cr_1;
}

sub call_mocked_client {
    my ($t, $json) = @_;
    my $call_params;
    my $fake_rpc_client = Test::MockObject->new();
    my $real_rpc_client = MojoX::JSON::RPC::Client->new();
    $fake_rpc_client->mock('call', sub { shift; $call_params = $_[1]->{params}; return $real_rpc_client->call(@_) });

    my $module = Test::MockModule->new('MojoX::JSON::RPC::Client');
    $module->mock('new', sub { return $fake_rpc_client });

    $t = $t->send_ok({json => $json})->message_ok;
    my $res = decode_json($t->message->[1]);

    $module->unmock_all;
    return ($res, $call_params);
}

1;
