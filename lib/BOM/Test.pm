package BOM::Test;

use strict;
use warnings;

use File::Spec;
use Cwd qw/abs_path/;

use BOM::System::Config;

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

This variable will be set if test is running on qa devbox. If it is set the BOM::System::Config::randsrv will use test redis instance instead of development.

=cut

=item $ENV{BOM_TEST_REDIS_REPLICATED}

This variable will be set if test is running on qa devbox. If it is set the BOM::System::RedisReplicated and other bom services
will use test redis instance instead of development.

=cut

BEGIN {
    my (undef, $file_path, undef) = File::Spec->splitpath(__FILE__);
    my $test_data_dir = abs_path("$file_path../../data");
    my $config_dir    = $test_data_dir . '/config';

    if (BOM::System::Config::env =~ /^qa/) {
        ## no critic (Variables::RequireLocalizedPunctuationVars)

        # Redis rand and replicated servers config
        $ENV{BOM_TEST_REDIS_REPLICATED} = $config_dir . '/redis-replicated.yml';
        $ENV{BOM_TEST_REDIS_RAND}       = $config_dir . '/redis.yml';

        # Cache redis server
        $ENV{REDIS_CACHE_SERVER} = $ENV{BOM_CACHE_SERVER} = '127.0.1.3:6385';

        $ENV{DB_POSTFIX} = '_test';
        $ENV{RPC_URL}    = 'http://127.0.0.1:5006/';
    }
}

1;

