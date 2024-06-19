#!/usr/bin/env perl

use strict;
use warnings;

no indirect;

use Future::AsyncAwait;
use IO::Async::Loop;
use Net::Async::HTTP;
use Syntax::Keyword::Try;

use URI;
use Log::Any        qw($log);
use JSON::MaybeUTF8 qw(:v1);
use Getopt::Long;
use Time::Moment;
use Log::Any::Adapter qw(Stderr), log_level => $ENV{BOM_LOG_LEVEL} // 'warning';

use BOM::User;
use BOM::User::Client;
use BOM::User::Password;
use BOM::Config;
use BOM::MT5::Script::AssetListing;

my $mt5_config_file   = '/etc/rmg/mt5webapi.yml';
my $redis_config_file = '/etc/rmg/redis-mt5user.yml';
my $request_timeout;
my $connection_limit;
my $server_type;
my $update_interval_secs;

GetOptions(
    'redis_config=s'         => \$redis_config_file,
    'mt5_config=s'           => \$mt5_config_file,
    'request_timeout=i'      => \$request_timeout,
    'connection_limit=i'     => \$connection_limit,
    'server_type=s'          => \$server_type,
    'update_interval_secs=i' => \$update_interval_secs
);

my $loop = IO::Async::Loop->new;

my $asset_listing = BOM::MT5::Script::AssetListing->new(
    redis_config         => $redis_config_file,
    mt5_config           => $mt5_config_file,
    request_timeout      => $request_timeout,
    connection_limit     => $connection_limit,
    server_type          => $server_type,
    update_interval_secs => $update_interval_secs
);

$loop->add($asset_listing);

$asset_listing->run->get();
