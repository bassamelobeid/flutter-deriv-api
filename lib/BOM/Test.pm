package BOM::Test;

use strict;
use warnings;

use Dir::Self;
use Cwd qw/abs_path/;
use POSIX qw/setsid/;

use await;

=head1 NAME

BOM::Test - Do things before test

=head1 DESCRIPTION

This module is used to prepare test environment. It should be used before any other bom modules in the test file.

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

This variable will be set if test is running on qa devbox. If it is set the BOM::Config::RedisReplicated and other bom services
will use test redis instance instead of development.

=cut

=item $ENV{BOM_TEST_REDIS_FEED}

This variable wil be set if test is running on qa devbox. If it is set the BOM::Config::RedisReplicated::redis_feed_*() will use it.

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

    my $dir_path      = __DIR__;
    my $test_data_dir = abs_path("$dir_path/../../data");
    my $config_dir    = $test_data_dir . '/config';

    ## no critic (Variables::RequireLocalizedPunctuationVars)
    $ENV{WEBSOCKET_API_REPO_PATH} = '/home/git/regentmarkets/binary-websocket-api';
    $ENV{RPC_URL}                 = 'http://127.0.0.1:15005/';
    $ENV{PRICING_RPC_URL}         = 'http://127.0.0.1:15006/';

    if (on_qa()) {
        # Redis rand and replicated servers config
        $ENV{BOM_TEST_REDIS_REPLICATED}         = $config_dir . '/redis-replicated.yml';
        $ENV{BOM_TEST_REDIS_RAND}               = $config_dir . '/redis.yml';
        $ENV{BOM_TEST_REDIS_FEED}               = $config_dir . '/redis-feed.yml';
        $ENV{BOM_TEST_REDIS_EVENTS}             = $config_dir . '/redis-replicated.yml';
        $ENV{BOM_TEST_REDIS_QUEUE}              = $config_dir . '/redis-replicated.yml';
        $ENV{BOM_TEST_REDIS_TRANSACTION}        = $config_dir . '/redis-replicated.yml';
        $ENV{BOM_TEST_REDIS_TRANSACTION_LIMITS} = $config_dir . '/redis-transaction-limits.yml';
        $ENV{BOM_TEST_REDIS_AUTH}               = $config_dir . '/redis.yml';

        # Cache redis server
        $ENV{REDIS_CACHE_SERVER} = $ENV{BOM_CACHE_SERVER} = '127.0.1.3:6385';

        $ENV{DB_POSTFIX}    = '_test';
        $ENV{PGSERVICEFILE} = '/home/nobody/.pg_service_test.conf';

        # This port is only valid in QA. In CI, we use the same ports as QA manual testing
        $ENV{DB_TEST_PORT} = 5451;
    }
    $ENV{TEST_DATABASE}    = 1;                     ## no critic (RequireLocalizedPunctuationVars)
    $ENV{JOB_QUEUE_PREFIX} = 'TEST_' . uc(env());
    $ENV{QUEUE_TIMEOUT}    = 2;

    # remove PERL5OPT which could cause confusion when forking to perls
    # different from our own (e.g. from binary-com/perl to /usr/bin/perl)
    delete $ENV{PERL5OPT};
}

1;

=head1 TEST

    # test this repo
    make test
    # test all repo under regentmarkets and binary-com
    make test_all

=cut

