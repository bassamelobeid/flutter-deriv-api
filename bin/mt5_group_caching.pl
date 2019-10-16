#!/usr/bin/env perl 
use strict;
use warnings;

=head1 NAME

C<mt5_group_caching.pl>

=head1 DESCRIPTION

Processes MT5 group requests from the backoffice
and caches the information in Redis.

=cut

use IO::Async::Loop;

use Net::Async::Redis;
use Future::Utils qw(try_repeat);

use BOM::Config::Runtime;
use BOM::Config::RedisReplicated;
use BOM::MT5::User::Async;

use Log::Any qw($log);
use Log::Any::Adapter ('Stderr', log_level => 'info');
use DataDog::DogStatsd::Helper qw(stats_inc);

use constant COOLDOWN => 1;

my $loop = IO::Async::Loop->new;
$loop->add(
    my $redis = Net::Async::Redis->new(
        uri => BOM::Config::RedisReplicated::redis_config('mt5_user', 'write')->{uri},
    ));

sub is_mt5_suspended {
    my $app_config = BOM::Config::Runtime->instance->app_config;
    return 1 if $app_config->system->mt5->suspend->all;
    return 0;
}

my $connection_lost = 1;

(
    try_repeat {
        $redis->connect->else(
            sub {
                my $delay = 1;
                while ($delay <= 8) {
                    $log->debugf('Failed to connect to redis. Retrying after %d seconds', $delay);
                    my $f = $loop->delay_future(after => $delay)->then(
                        sub {
                            $redis->connect;
                        })->block_until_ready;
                    return Future->done() if $f->is_done;
                    $delay *= 2;
                }
                return Future->fail('Connection refused', 'redis', 'connection');
            }
            )->then(
            sub {
                $log->info('Redis connection established. Fetching requests.') if $connection_lost;
                $connection_lost = 0;
                $redis->brpop('MT5_USER_GROUP_PENDING', 60000);
            }
            )->then(
            sub {
                unless ($_[0]) {
                    $log->info('There was not any requst pending request');
                    return Future->done;
                }
                my ($queue, $job) = @{$_[0]};
                my ($id, $queued) = split /:/, $job;

                $log->debugf('Processing pending ID [%s]', $id);

                my $cache_key = 'MT5_USER_GROUP::' . $id;
                $redis->hgetall($cache_key)->then(
                    sub {
                        my ($data) = @_;
                        my $group = $data->[0];
                        if ($group) {
                            $log->debugf('Details found for ID [%s] - %s', $id, $group);
                            stats_inc('mt5.group_populator.item_cached', 1);
                            return Future->done;
                        }
                        # We avoid the MT5 call if it's suspended, but also pause for
                        # a bit - no need to burn through the queue
                        # too quickly if it's only down temporarily
                        return $loop->delay_future(after => 60) if is_mt5_suspended();
                        return BOM::MT5::User::Async::get_user($id)->else(
                            sub {
                                $log->errorf('Failure when retrieving group for [%s] - %s', $id, [@_]);
                                stats_inc('mt5.group_populator.item_failed', 1);
                                Future->done('failed to get group');
                            }
                            )->then(
                            sub {
                                my ($data) = @_;
                                my $group  = $data->{'group'};
                                my $rights = $data->{'rights'};

                                # Keep things around for an hour,
                                # long enough to be useful but
                                # try not to keep bad data too long...
                                # but 5 minutes is good enough for
                                # a negative cache.
                                my $ttl = $group ? 3600 : 300;
                                $group  //= 'Archived';
                                $rights //= 0x0004;

                                stats_inc('mt5.group_populator.item_processed', 1);
                                my $mt5_details = {
                                    'group'  => $group,
                                    'rights' => $rights,
                                };

                                $redis->hmset($cache_key, %$mt5_details)->then(
                                    sub {

                                        $redis->expire($cache_key, $ttl);
                                    }
                                    )->on_done(
                                    sub {
                                        $log->debugf('Cached ID [%s] group [%s]', $id, $group);
                                    });
                            });
                    });
            }
            )->else(
            sub {
                $log->errorf('Failure - %s', [@_]);
                $connection_lost = 1;
                return $loop->delay_future(after => COOLDOWN);
            })
    }
    while => sub {
        1;
    })->get;

