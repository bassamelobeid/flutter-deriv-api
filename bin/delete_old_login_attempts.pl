#!/usr/bin/env perl 
use strict;
use warnings;

no indirect;

use YAML::XS qw (LoadFile);
use Net::Async::Redis;
use IO::Async::Loop;

use Future::AsyncAwait;

my $config_path = $ARGV[0] // '/etc/rmg/redis-auth.yml';

my $config = LoadFile($config_path)->{write};

my $loop = IO::Async::Loop->new;
$loop->add(
    my $redis = Net::Async::Redis->new(
        host => $config->{host},
        port => $config->{port},
        auth => $config->{auth}));

$redis->connect->get;

my $now       = time;
my $threshold = 60 * 60 * 24 * 30 * 3;    # three months
my $cursor    = 0;
(
    async sub {
        do {
            my $details = await $redis->scan(
                $cursor,
                match => 'CLIENT_LOGIN_HISTORY::*',
                count => 100
            );
            ($cursor, my $client_list) = $details->@*;

            foreach my $key ($client_list->@*) {
                my $entries_list = await $redis->hgetall($key);
                my %entries      = $entries_list->@*;
                foreach my $login_entry (keys %entries) {
                    if ($now - $entries{$login_entry} >= $threshold) {
                        if (1 == keys %entries) {
                            await $redis->del($key);
                        } else {
                            await $redis->hdel($key, $login_entry);
                        }
                    }
                }

            }
        } while ($cursor);
    })->()->get;
