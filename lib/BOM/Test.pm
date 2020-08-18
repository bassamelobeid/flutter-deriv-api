package BOM::Test;

use strict;
use warnings;
use Dir::Self;
use Cwd qw/abs_path/;
use POSIX qw/setsid/;
use Path::Tiny;
use Syntax::Keyword::Try;
use RedisDB;
use YAML::XS;
use await;

=head1 NAME

BOM::Test - Do things before test

=head1 DESCRIPTION

This module is used to prepare test environment. It should be used before any other bom modules in the test file.

=head1 Environment Variables

=over 4

=item $ENV{DB_POSTFIX}

This variable will be set if test is running on qa devbox. If it is set the system will use test database instead of development database.

=cut

=item $ENV{REDIS_CACHE_SERVER}

This variable will be set if test is running on qa devbox. If it is set the Cache::RedisDB will use test redis instance instead of development.

=item $ENV{BOM_TEST_REDIS_RAND}

This variable will be set if test is running on qa devbox. If it is set the BOM::Config::randsrv will use test redis instance instead of development.

=cut

=item $ENV{BOM_TEST_REDIS_REPLICATED}

This variable will be set if test is running on qa devbox. If it is set the BOM::Config::Redis and other bom services
will use test redis instance instead of development.

=item $ENV{BOM_TEST_REDIS_FEED}

This variable wil be set if test is running on qa devbox. If it is set the BOM::Config::Redis::redis_feed_*() will use it.

=item $ENV{BOM_TEST_REDIS_EVENTS}

This variable wil be set if test is running on qa devbox. If it is set the BOM::Config::Redis::redis_events_*() will use it.

=item $ENV{BOM_TEST_REDIS_QUEUE}

This variable wil be set if test is running on qa devbox. If it is set the BOM::Config::Redis::redis_queue_*() will use it.

=item $ENV{BOM_TEST_REDIS_TRANSACTION}

This variable wil be set if test is running on qa devbox. If it is set the BOM::Config::Redis::redis_transaction_*() will use it.

=item $ENV{BOM_TEST_REDIS_TRANSACTION_LIMITS}

This variable wil be set if test is running on qa devbox. If it is set the BOM::Config::RedisTransactionLimits::redis_limites_*() will use it.

=item $ENV{BOM_TEST_REDIS_AUTH}

This variable wil be set if test is running on qa devbox. If it is set the BOM::Config::Redis::redis_auth_*() will use it.

=item $ENV{BOM_TEST_REDIS_MT5_USER}

This variable wil be set if test is running on qa devbox. If it is set the BOM::Config::Redis::redis_mt5_user_*() will use it.

=item $ENV{BOM_TEST_REDIS_P2P}

This variable wil be set if test is running on qa devbox. If it is set the BOM::Config::Redis::redis_p2p_*() will use it.

=item $ENV{BOM_TEST_WS_REDIS}

This variable wil be set if test is running on qa devbox. If it is set the BOM::Config::Redis::redis_ws_*() will use it.

=back

=cut

my $config_dir;

BEGIN {
    my $env = do {
        local @ARGV = ('/etc/rmg/environment');
        readline;
    };
    chomp $env;

    sub env {
        return $env // "";
    }

    sub on_qa {
        return env() =~ /^qa/;
    }

    sub on_production {
        return env() =~ /production/;
    }

    # This function should not be around, development environment is legacy
    # This needs further discussion to make sure all agree to remove this environment
    # TODO: ~Jack
    sub on_development {
        return env() =~ /^development/;
    }

    die "wrong env. Can't run test" unless (on_qa() or on_development());

    my $dir_path      = __DIR__;
    my $test_data_dir = abs_path("$dir_path/../../data");
    $config_dir = $test_data_dir . '/config';

    ## no critic (Variables::RequireLocalizedPunctuationVars)
    # set a env variable to represent we are in testing mode
    $ENV{BOM_TEST}                = 1;
    $ENV{WEBSOCKET_API_REPO_PATH} = '/home/git/regentmarkets/binary-websocket-api';
    $ENV{RPC_URL}                 = 'http://127.0.0.1:15005/';
    $ENV{PRICING_RPC_URL}         = 'http://127.0.0.1:15006/';

    if (on_qa()) {
        # Redis rand and replicated servers config
        $ENV{BOM_TEST_REDIS_REPLICATED}         = $config_dir . '/redis-replicated.yml';
        $ENV{BOM_TEST_REDIS_RAND}               = $config_dir . '/redis.yml';
        $ENV{BOM_TEST_REDIS_FEED}               = $config_dir . '/redis-feed.yml';
        $ENV{BOM_TEST_REDIS_EVENTS}             = $config_dir . '/redis-replicated.yml';
        $ENV{BOM_TEST_REDIS_RPC}                = $config_dir . '/redis-rpc.yml';
        $ENV{BOM_TEST_REDIS_TRANSACTION}        = $config_dir . '/redis-replicated.yml';
        $ENV{BOM_TEST_REDIS_TRANSACTION_LIMITS} = $config_dir . '/redis-transaction-limits.yml';
        $ENV{BOM_TEST_REDIS_AUTH}               = $config_dir . '/redis.yml';
        $ENV{BOM_TEST_REDIS_MT5_USER}           = $config_dir . '/redis-replicated.yml';
        $ENV{BOM_TEST_REDIS_P2P}                = $config_dir . '/redis-replicated.yml';
        $ENV{BOM_TEST_WS_REDIS}                 = $config_dir . '/redis-replicated.yml';

        # Cache redis server
        $ENV{REDIS_CACHE_SERVER} = $ENV{BOM_CACHE_SERVER} = '127.0.1.3:6385';

        $ENV{DB_POSTFIX}    = '_test';
        $ENV{PGSERVICEFILE} = '/home/nobody/.pg_service_test.conf';

        # This port is only valid in QA. In CI, we use the same ports as QA manual testing
        $ENV{DB_TEST_PORT} = 5451;
    }
    $ENV{TEST_DATABASE}     = 1;                 ## no critic (RequireLocalizedPunctuationVars)
    $ENV{SEGMENT_BASE_URL}  = 'http://dummy/';
    $ENV{SEGMENT_WRITE_KEY} = 'test';

    # remove PERL5OPT which could cause confusion when forking to perls
    # different from our own (e.g. from binary-com/perl to /usr/bin/perl)
    delete $ENV{PERL5OPT};
}

purge_redis();

=head1 Functions

=head2 purge_redis

Purge redis database before running a test script. Give it a clear environment.

Parameters : none
Return: 1

=cut

# We put purge_redis here, not BOM::Test::Data::Utility::UnitTestRedis, because:
# UnitTestRedis.pm loaded other modules, and those modules used Date::Utility,
# and we use Test::MockTime widely, which require to be `use`d before other modules which use `time`
# and also Test::MockTime::HiRes.
# But we want to purge redis before any other modules. That's conflict.
# So putting here is a safe choice
sub purge_redis {
    my %flushed_redis;
    # Here we get configuration from yml file directly, not get redis instance from BOM::Config::Redis
    # to avoid redis to be purged many times.
    for my $redis_yml (path($config_dir)->children) {
        next unless $redis_yml->basename =~ /redis/;
        my $config_content = YAML::XS::LoadFile("$redis_yml");
        for my $config_key (keys %$config_content) {
            next unless $config_key =~ /write/;
            my $config = $config_content->{$config_key};
            # TODO will add db index in the future
            next if $flushed_redis{"$config->{host}:$config->{port}"};

            # Since redis services in docker depend on every repo's `services.yml`,
            # maybe some redis servers are not started.
            # Here our main goal is not test redis server but reinitialize them,
            # so we use try here
            try {
                my $redis = RedisDB->new(
                    host => $config->{host},
                    port => $config->{port},
                    ($config->{password} ? ('password' => $config->{password}) : ()));
                print STDERR "$$ flushing redis $config->{host}:$config->{port}\n";
                $redis->flushdb();
                $flushed_redis{"$config->{host}:$config->{port}"} = 1;
            } catch {
            }
        }
    }
    return 1;
}

1;

=head1 TEST

    # test this repo
    make test
    # test all repo under regentmarkets and binary-com
    make test_all

=cut
