#!/usr/bin/env perl

use strict;
use warnings;

no indirect;

use Future::AsyncAwait;
use IO::Async::Loop;
use Syntax::Keyword::Try;
use Log::Any        qw($log);
use JSON::MaybeUTF8 qw(:v1);
use Getopt::Long;
use Time::Moment;
use Log::Any::Adapter qw(Stderr), log_level => $ENV{BOM_LOG_LEVEL} // 'warning';
use BOM::MT5::Script::LivePricing;

my $mt5_config_file        = '/etc/rmg/mt5webapi.yml';
my $mt5_redis_config_file  = '/etc/rmg/redis-mt5user.yml';
my $feed_redis_config_file = '/etc/rmg/redis-feed.yml';
my $firebase_config        = '/etc/rmg/firebase.yml';
my $max_connection;

GetOptions(
    'mt5_redis_config=s'  => \$mt5_redis_config_file,
    'feed_redis_config=s' => \$feed_redis_config_file,
    'mt5_config=s'        => \$mt5_config_file,
    'firebase_config=s'   => \$firebase_config,
    'max_connection=s'    => \$max_connection,
);

while (1) {
    my $loop;
    try {
        $loop = IO::Async::Loop->new;

        my $live_pricing = BOM::MT5::Script::LivePricing->new(
            mt5_redis_config  => $mt5_redis_config_file,
            feed_redis_config => $feed_redis_config_file,
            mt5_config        => $mt5_config_file,
            firebase_config   => $firebase_config,
            max_connection    => $max_connection,
        );

        $loop->add($live_pricing);

        $live_pricing->run->get();

        $loop->remove($live_pricing);
    } catch ($e) {
        $log->errorf('Error occurred in mt5_live_pricing script %s', $e);

    } finally {
        $log->debug("Retrying in 5 seconds");
        $loop->delay_future(after => 5)->get;

    }
}
