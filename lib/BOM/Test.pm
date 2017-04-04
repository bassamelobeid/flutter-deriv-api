package BOM::Test;

use strict;
use warnings;

use Dir::Self;
use Cwd qw/abs_path/;

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

=cu

t=item $ENV{BOM_TEST_REDIS_RAND}

This variable will be set if test is running on qa devbox. If it is set the BOM::Platform::Config::randsrv will use test redis instance instead of development.

=cut

=item $ENV{BOM_TEST_REDIS_REPLICATED}

This variable will be set if test is running on qa devbox. If it is set the BOM::Platform::RedisReplicated and other bom services
will use test redis instance instead of development.

=cut

{
    my $env = do {
        local @ARGV = ('/etc/rmg/environment');
        readline;
    };
    chomp $env;

    sub env {
        return $env // "";
    }
}

sub on_qa {
    return env() =~ /^qa/;
}

BEGIN {
    my $dir_path      = __DIR__;
    my $test_data_dir = abs_path("$dir_path/../../data");
    my $config_dir    = $test_data_dir . '/config';

    ## no critic (Variables::RequireLocalizedPunctuationVars)
    $ENV{WEBSOCKET_API_REPO_PATH} = '/home/git/regentmarkets/binary-websocket-api';

    if (on_qa()) {
        # Redis rand and replicated servers config
        $ENV{BOM_TEST_REDIS_REPLICATED} = $config_dir . '/redis-replicated.yml';
        $ENV{BOM_TEST_REDIS_RAND}       = $config_dir . '/redis.yml';

        # Cache redis server
        $ENV{REDIS_CACHE_SERVER} = $ENV{BOM_CACHE_SERVER} = '127.0.1.3:6385';

        $ENV{DB_POSTFIX} = '_test';
        $ENV{RPC_URL}    = 'http://127.0.0.1:5006/';
    }
    $ENV{TEST_DATABASE} = 1;
}

1;

