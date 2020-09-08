package BOM::Test;

use strict;
use warnings;
use Dir::Self;
use Class::Method::Modifiers qw(install_modifier);
use RedisDB;
use Mojo::Redis2;
use Path::Tiny;
use Syntax::Keyword::Try;
use YAML::XS;

=head1 NAME

BOM::Test - Do things before test

=head1 DESCRIPTION

This module is used to prepare test environment. It should be used before any other bom modules in the test file.
It should not use any BOM::* modules to avoid affecting other modules.

=head1 Environment Variables

=over 4

=item $ENV{DB_POSTFIX}

This variable will be set if test is running on qa devbox. If it is set the system will use test database instead of development database.

=cut

=back

=cut

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

    ## no critic (Variables::RequireLocalizedPunctuationVars)
    # set a env variable to represent we are in testing mode
    $ENV{BOM_TEST}                = 1;
    $ENV{WEBSOCKET_API_REPO_PATH} = '/home/git/regentmarkets/binary-websocket-api';
    $ENV{RPC_URL}                 = 'http://127.0.0.1:15005/';
    $ENV{PRICING_RPC_URL}         = 'http://127.0.0.1:15006/';

    if (on_qa()) {
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

# Redis test database index, used by Redis 'SELECT' command to change the database in the test env.
my $REDIS_DB_INDEX = 10;
# To avoid running too many Redis instances on QA machines at the same time, the test script will share Redis instances with the services
# with different database index.
# The following piece of code will change the Redis database's index while creating instances.
install_modifier 'RedisDB' => 'around' => 'new' => sub {
    my ($code, $class, @args) = @_;
    my $redis = $class->$code(@args);
    $redis->{database} = $REDIS_DB_INDEX;
    $redis->select($REDIS_DB_INDEX);
    return $redis;
};
install_modifier 'Mojo::Redis2' => 'around' => 'new' => sub {
    my ($code, $class, @args) = @_;
    my $redis = $class->$code(@args);
    $redis->url->path($REDIS_DB_INDEX);
    return $redis;
};

# We don't want to load Future::AsyncAwait in some repo (see https://trello.com/c/gZ6Gj4Mq/8724-3-async-awaitblacklist-05 ) ,
# So we can't load Net::Async::Redis here (which will load Future::AsyncAwait).
# The code is added into INIT block. It will run after other modules loaded.
# So we can test whether Net::Async::Redis is loaded. If is loaded by other module, then we apply the hook
{
    # There will be a warn of `Too late to run INIT block` when we start BOM::Test::Script::* in .proverc
    # That's not a problem. Lets disable it.
    no warnings qw(void);    ## no critic

    INIT {
        if ($INC{"Net/Async/Redis.pm"}) {
            install_modifier 'Net::Async::Redis' => 'around' => 'connect' => sub {
                my ($code, $redis, @args) = @_;
                return $redis->$code(@args)->then(
                    sub {
                        my $res = shift;
                        $redis->select($REDIS_DB_INDEX)->then_done($res);
                    });
            };
        }
    }
}

purge_redis() unless $ENV{NO_PURGE_REDIS};

=head1 Functions

=head2 purge_redis

Purge Redis database before running a test script. Give it a clear environment.

Parameters: none
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
    # to avoid loading BOM::Config in this file
    my $config_dir      = '/etc/rmg';
    my @redis_yml_files = qw(
        redis-replicated.yml
        redis-pricer.yml
        redis-pricer-subscription.yml
        redis-pricer-shared.yml
        redis-exchangerates.yml
        redis-feed.yml
        redis-mt5user.yml
        redis-events.yml
        redis-rpc.yml
        redis-transaction.yml
        redis-transaction-limits.yml
        redis-auth.yml
        redis-p2p.yml
        ws-redis.yml
    );

    for my $redis_yml (@redis_yml_files) {
        $redis_yml = path("$config_dir/$redis_yml");
        my $config_content = YAML::XS::LoadFile("$redis_yml");
        for my $config_key (keys %$config_content) {
            next unless $config_key =~ /write/;
            my $config = $config_content->{$config_key};
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
                die "Purge redis $redis_yml failed: Database index is not $REDIS_DB_INDEX. RedisDB hook not applied ?"
                    if $redis->{database} != $REDIS_DB_INDEX;
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
