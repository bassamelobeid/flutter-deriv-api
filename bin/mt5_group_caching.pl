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
use Log::Any::Adapter qw(Stdout), log_level => 'info';
use DataDog::DogStatsd::Helper qw(stats_inc);

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

sub group_for_user {
    my ($id) = @_;
    return BOM::MT5::User::Async::get_user($id);

}

(
    try_repeat {
        $redis->brpop('MT5_USER_GROUP_PENDING', 60000)->then(
            sub {
                my ($queue, $job) = @{$_[0]};
                my ($id, $queued) = split /:/, $job;
                $log->debugf('Processing pending ID [%s]', $id);
                my $cache_key = 'MT5_USER_GROUP::' . $id;
                $redis->hgetall($cache_key)->then(
                    sub {
                        my ($data) = @_;
                        my $group = $data->[0];

                        if ($group) {
                            $log->debugf('Existing group found for ID [%s] - %s', $id, $group);
                            stats_inc('mt5.group_populator.item_cached', 1);
                            return Future->done;
                        }

                        # We avoid the MT5 call if it's suspended, but also pause for
                        # a bit - no need to burn through the queue
                        # too quickly if it's only down temporarily
                        return $loop->delay_future(after => 59) if is_mt5_suspended();

                        group_for_user($id)->else(
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

                                # Keep things around for a day,
                                # long enough to be useful but
                                # try not to keep bad data too long...
                                # but 5 minutes is good enough for
                                # a negative cache.
                                my $ttl = $group ? 86400 : 300;
                                $group //= 'unknown';
                                stats_inc('mt5.group_populator.item_processed', 1);
                                my $mt5_details = {
                                    'group'  => $group,
                                    'rights' => $rights,
                                };

                                $redis->hmset("MT5_USER_GROUP::$id", %$mt5_details)->then(
                                    sub {
                                        $redis->expire("MT5_USER_GROUP::$id", $ttl);
                                    }
                                    )->on_done(
                                    sub {
                                        $log->debugf('Cached ID [%s] group [%s]', $id, $group);
                                    });
                            });
                    });
            }
            )->on_fail(
            sub {
                $log->errorf('Failure - %s', [@_]);
            })
    }
    while => sub {
        1;
    })->get;

