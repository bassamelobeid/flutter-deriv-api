package BOM::Test;

use strict;
use warnings;

use Dir::Self;
use Class::Method::Modifiers qw(install_modifier);
use RedisDB;
use Mojo::Redis2;
use Path::Tiny;
use File::Find::Rule;
use Syntax::Keyword::Try;
use YAML::XS;
use constant REDIS_KEY_COUNTER => 'redis_key_counter';
my $perl5opt;

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

=head2 on_ci

check the current environment is ci environment

=cut

    sub on_ci {
        return env() eq 'ci';
    }

    die "wrong env. Can't run test" unless (on_qa() or on_ci());

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
    $ENV{TEST_DATABASE}               = 1;                 ## no critic (RequireLocalizedPunctuationVars)
    $ENV{SEGMENT_BASE_URL}            = 'http://dummy/';
    $ENV{SEGMENT_WRITE_KEY}           = 'test';
    $ENV{DEVEXPERTS_API_SERVICE_PORT} = 8083;
    $ENV{DEVEXPERTS_SERVER_PORT}      = 8084;

    # remove PERL5OPT which could cause confusion when forking to perls
    # different from our own (e.g. from binary-com/perl to /usr/bin/perl)
    $perl5opt = delete $ENV{PERL5OPT};
}

END {
    # make cover test HARNESS_PERL_SWITCHES conflict with --exec,
    # so we need PERL5OPT to load BOM::Test only for make cover test
    $ENV{PERL5OPT} = $perl5opt if $ENV{HARNESS_PERL_SWITCHES} && $perl5opt;    ## no critic (Variables::RequireLocalizedPunctuationVars)

}
# Redis test database index, used by Redis 'SELECT' command to change the database in the test env.
my $REDIS_DB_INDEX = on_qa() ? 10 : 0;
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

prepare and purge Redis database before running a test script. Give it a clear environment.

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
    my @redis_yml_files = File::Find::Rule->file->name(qr/\.*redis.*\.yml/)->in('/etc/rmg');

    for my $redis_yml (@redis_yml_files) {
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
                my $redis_key_counter = get_and_add_redis_key_counter($redis);
                $redis->flushdb();
                $redis->set(REDIS_KEY_COUNTER, $redis_key_counter);
                $flushed_redis{"$config->{host}:$config->{port}"} = 1;
            } catch ($e) {
                print STDERR $e, "\n" unless $e =~ /Couldn't connect to the redis server/;
            }
        }
    }
    return 1;
}

=head2 get_and_add_redis_key_counter

Get statistics information of keys for test.

Parameters: Redis object

Return: number of redis keys from the first test script to the previous test script

=cut

sub get_and_add_redis_key_counter {
    my ($redis) = @_;
    my $key = REDIS_KEY_COUNTER;
    # get number of keys from https://redis.io/commands/INFO keyspace
    # output format is like: 'keys=XXX,expires=XXX'
    my $info              = $redis->info('keyspace')->{"db$REDIS_DB_INDEX"};
    my $redis_key_counter = $redis->get($key) || 0;
    if ($info) {
        my %stats = split /[,=]/, $info;
        $redis_key_counter += $stats{keys};
    }
    return $redis_key_counter;
}

=head2 setup_pgservice_pass_for_userdb01

setup pgservice.conf and pgpass.conf for userdb01

=cut

sub setup_pgservice_pass_for_userdb01 {
    my $cfg            = YAML::XS::LoadFile('/etc/rmg/userdb.yml');
    my $pgservice_conf = "/tmp/pgservice.conf.$$";
    my $pgpass_conf    = "/tmp/pgpass.conf.$$";

    # In our unit test container (debian-ci), there is no unit test cluster;
    # so we need to route depending on environment. Ideally both db setups
    # should be consistent in the not too distant future
    my $port = $ENV{DB_TEST_PORT} // 5436;

    # debian-ci /etc/rmg/userdb.yml has readonly_password and write_password tags.
    # pick the right tag when run tests in debian-ci
    my $password = on_ci() ? $cfg->{write_password} : $cfg->{password};

    path($pgservice_conf)->append(<<"CONF");
[user01]
host=$cfg->{ip}
port=$port
user=write
dbname=users
CONF

    path($pgpass_conf)->append(<<"CONF");
$cfg->{ip}:$port:users:write:$password
CONF
    chmod 0400, $pgpass_conf;

    @ENV{qw/PGSERVICEFILE PGPASSFILE/} = ($pgservice_conf, $pgpass_conf);    ## no critic (RequireLocalizedPunctuationVars)
}

1;

=head1 TEST

    # test this repo
    make test
    # test all repo under regentmarkets and binary-com
    make test_all

=cut
