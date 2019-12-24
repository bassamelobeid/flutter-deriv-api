package BOM::Test::Helper;

use strict;
use warnings;

BEGIN {
    # Avoid MOJO_LOG_LEVEL = fatal set by Test::Mojo
    $ENV{HARNESS_IS_VERBOSE} = 1;    ## no critic (RequireLocalizedPunctuationVars)
}

use Test::More;
use Test::Mojo;
use Test::Builder;

use Encode;
use Path::Tiny;
use JSON::MaybeXS;
use JSON::MaybeUTF8 qw(encode_json_utf8 decode_json_utf8);
use JSON::Validator;
use Data::Dumper;
use Date::Utility;

use BOM::Test;
use BOM::Test::Data::Utility::FeedTestDatabase;
use BOM::Test::Data::Utility::UnitTestMarketData;
use BOM::Test::Data::Utility::UnitTestDatabase;
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Helper::Redis qw/is_within_threshold/;
use BOM::User::Password;
use BOM::User;
use Net::EmptyPort qw/empty_port/;

use Mojo::Redis2::Server;
use File::Temp qw/ tempdir /;
use Path::Tiny;
use Syntax::Keyword::Try;

use Test::MockModule;
use MojoX::JSON::RPC::Client;
use IO::Async::Loop::Mojo;
use Net::Async::Redis;

use RedisDB;
use YAML::XS qw/LoadFile DumpFile/;

use Exporter qw/import/;
our @EXPORT_OK =
    qw/test_schema build_mojo_test build_wsapi_test build_test_R_50_data create_test_user call_mocked_client reconnect launch_redis call_instrospection/;

my $version = 'v3';
die 'unknown version' unless $version;

my $redis_test_done;

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
    $redis_test_done = 0;
    my $redis_port = empty_port;

    my $redis_server = Mojo::Redis2::Server->new;
    $redis_server->start(
        port    => $redis_port,
        logfile => '/tmp/redis.log'
    );
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

    if (Binary::WebSocketAPI::v3::Instance::Redis->can('ws_redis_master')) {
        no strict 'refs';                          ## no critic (ProhibitProlongedStrictureOverride)
        my $orig    = Test::Builder->can('done_testing');
        my $builder = Test::More->builder;
        no warnings 'redefine';                    ## no critic (ProhibitNoWarnings)
        *{'Test::Builder::done_testing'} = sub {
            my $in_subtest_sub = $builder->can('in_subtest');
            if (    not $redis_test_done
                and not($in_subtest_sub ? $builder->$in_subtest_sub : $builder->parent))
            {
                try {
                    my $redis = Binary::WebSocketAPI::v3::Instance::Redis::ws_redis_master();
                    is_within_threshold 'ws_redis_master', $redis->backend->info('keyspace');
                    $redis_test_done = 1;
                }
                catch {
                    diag "Could not run ws_redis_master keys test: $@\n";
                }
            }
            $orig->(@_);
        };
    }

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
        redis_server => $redis_server
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

    my $v4_schema_path = path($ENV{WEBSOCKET_API_REPO_PATH} . "/config/$version/$type/receive.json");
    my $v4_validator   = JSON::Validator->new;
    my $schema         = JSON::MaybeXS->new->decode($v4_schema_path->slurp_utf8);
    $v4_validator->schema($schema);
    my @v4_result = $v4_validator->validate($data);

    ok(!scalar(@v4_result), "$type response validated OK by V4 schema - " . $schema->{title}) or do {
        diag 'Message is rejected by v4 validator:';
        diag " - $_" foreach @v4_result;
        diag "Received Data \n" . Dumper($data);
    };

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
    my $hash_pwd  = BOM::User::Password::hashpw($password);
    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $client_cr->set_default_account('USD');
    $client_cr->email($email);
    $client_cr->save;
    my $cr_1 = $client_cr->loginid;
    my $user = BOM::User->create(
        email    => $email,
        password => $hash_pwd
    );
    $user->add_client($client_cr);

    return $cr_1;
}

sub call_mocked_client {
    my ($t, $json) = @_;
    my $call_params;

    my $module = Test::MockModule->new('MojoX::JSON::RPC::Client');
    $module->mock('call', sub { my $self = shift; $call_params = $_[1]->{params}; return $module->original('call')->($self, @_) });

    $t = $t->send_ok({json => $json})->message_ok;
    my $res = JSON::MaybeXS->new->decode(Encode::decode_utf8($t->message->[1]));

    $module->unmock_all;
    return ($res, $call_params);
}

sub call_instrospection {
    my ($cmd, $args) = @_;

    return 'Websocket API repo is uavailable' unless (Binary::WebSocketAPI::v3::Instance::Redis->can('ws_redis_master'));
    my $redis_master = Binary::WebSocketAPI::v3::Instance::Redis->ws_redis_master() or die 'no redis connection';
    my $loop = IO::Async::Loop::Mojo->new;

    $loop->add(my $redis         = Net::Async::Redis->new(uri => 'redis://127.0.0.1:' . $redis_master->url->port));
    $loop->add(my $redis_publish = Net::Async::Redis->new(uri => 'redis://127.0.0.1:' . $redis_master->url->port));

    $redis->connect->get;
    $redis_publish->connect->get;

    my $response;

    $redis->subscribe('introspection_response')->then(
        sub {
            my $sub = shift;
            $redis_publish->publish(
                introspection => JSON::MaybeUTF8::encode_json_utf8({
                        command => $cmd,
                        args    => $args,
                        id      => 1,
                        channel => 'introspection_response',
                    })
                )->then(
                sub {
                    ok 1, "Introspection message published: command = $cmd, args = " . join(', ', @$args);
                })->retain;

            $sub->events->map('payload')->take(1)->map(
                sub {
                    $response = decode_json_utf8(shift);
                })->completed;
        }
        )->then(
        sub {
            $redis->unsubscribe('introspection_response');
        })->get;

    return $response;
}

1;
